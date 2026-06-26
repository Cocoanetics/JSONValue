#if Subprocess
import Foundation
import JSONFoundation
import JSONRPCPeer
import JSONRPCWire
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// Where a stdio transport's bytes come from and go to.
public enum StdioEndpoint: Sendable {
    /// Spawn a child and speak to its stdin/stdout (LSP, ACP client, MCP client).
    case childProcess(ProcessLaunch)
    /// Be the process — read our own stdin, write our own stdout (ACP agent, MCP
    /// server launched by a host).
    case currentProcess
}

/// A single stdio ``JSONRPCMessageTransport`` parameterized over the two axes that
/// actually vary between LSP, ACP, and MCP: the **endpoint** (spawn a child vs. be
/// the process) and the **framing** (`Content-Length` vs. newline). The JSON codec
/// and the sync-`send`-over-`AsyncStream` machinery are fixed.
///
/// This is the unification target: `StdioMessageTransport(.childProcess(launch),
/// ContentLengthFraming())` is LSP; `(.childProcess(launch), LineFraming())` is an
/// ACP/MCP client; `(.currentProcess, LineFraming())` is an ACP agent / MCP server.
///
/// The `.childProcess` path runs on `swift-subprocess` and is lock-free (`Sendable`,
/// no `@unchecked`); `.currentProcess` reads its own stdin on a thread (inherent —
/// you can't avoid a blocking read of your own fd 0).
public final class StdioMessageTransport<Framing: MessageFraming>: JSONRPCMessageTransport, Sendable {
    private let outbound: AsyncStream<JSONRPCMessage>.Continuation
    private let inbound: AsyncThrowingStream<JSONRPCMessage, any Error>
    private let runTask: Task<Void, Never>

    public init(endpoint: StdioEndpoint, framing: Framing) {
        let (outboundStream, outboundContinuation) = AsyncStream<JSONRPCMessage>.makeStream()
        let (inboundStream, inboundContinuation) = AsyncThrowingStream<JSONRPCMessage, any Error>.makeStream()
        self.outbound = outboundContinuation
        self.inbound = inboundStream

        switch endpoint {
        case .childProcess(let launch):
            self.runTask = Self.runChild(
                launch: launch, framing: framing,
                outbound: outboundStream, inbound: inboundContinuation)
        case .currentProcess:
            self.runTask = Self.runCurrentProcess(
                framing: framing, outbound: outboundStream, inbound: inboundContinuation)
        }
    }

    public func send(_ message: JSONRPCMessage) throws {
        guard case .enqueued = outbound.yield(message) else {
            throw JSONRPCPeerError.closed
        }
    }

    public func makeInboundStream() -> AsyncThrowingStream<JSONRPCMessage, any Error> {
        inbound
    }

    public func close() {
        outbound.finish()
    }

    // MARK: Child process (swift-subprocess, lock-free)

    private static func runChild(
        launch: ProcessLaunch,
        framing: Framing,
        outbound: AsyncStream<JSONRPCMessage>,
        inbound: AsyncThrowingStream<JSONRPCMessage, any Error>.Continuation
    ) -> Task<Void, Never> {
        let executable: Executable = launch.executable.contains("/")
            ? .path(FilePath(launch.executable))
            : .name(launch.executable)
        let arguments = Arguments(launch.arguments)
        let workingDirectory = launch.workingDirectory.map { FilePath($0) }
        let inheritStderr = launch.inheritStderr
        // Honor a caller-supplied environment as a full replacement — matching the
        // `Foundation.Process` transport's `process.environment = launch.environment`
        // (e.g. an ACP/MCP client injecting auth vars into the agent it spawns). `nil`
        // inherits the parent's. `Environment.Key`'s only runtime-constructible entry
        // point is its `ExpressibleByStringLiteral` init; a `reduce` (not
        // `uniqueKeysWithValues`) avoids a duplicate-key trap on case-folding platforms.
        let environment: Environment = launch.environment.map { vars in
            .custom(vars.reduce(into: [Environment.Key: String]()) {
                $0[Environment.Key(stringLiteral: $1.key)] = $1.value
            })
        } ?? .inherit

        return Task {
            do {
                // The server's stderr (its logs) either passes through to ours or is
                // discarded — distinct output types, so the `run` call is branched;
                // the I/O pump is shared.
                if inheritStderr {
                    _ = try await run(
                        executable, arguments: arguments, environment: environment,
                        workingDirectory: workingDirectory,
                        input: .inputWriter, output: .sequence, error: .currentStandardError
                    ) { execution in
                        try await pump(execution, framing: framing, outbound: outbound, inbound: inbound)
                    }
                } else {
                    _ = try await run(
                        executable, arguments: arguments, environment: environment,
                        workingDirectory: workingDirectory,
                        input: .inputWriter, output: .sequence, error: .discarded
                    ) { execution in
                        try await pump(execution, framing: framing, outbound: outbound, inbound: inbound)
                    }
                }
                inbound.finish()
            } catch is CancellationError {
                inbound.finish()
            } catch {
                // Launch/IO failure surfaces here (async): fail the peer's inbound
                // stream so pending requests reject with this error.
                inbound.finish(throwing: error)
            }
        }
    }

    /// Bridge the child's stdio to the two streams: stdout → framing → `inbound`;
    /// `outbound` → framing → stdin. Generic over the error output (passthrough vs
    /// discarded) since the body never touches stderr.
    private static func pump<Err: ErrorOutputProtocol>(
        _ execution: Execution<CustomWriteInput, SequenceOutput, Err>,
        framing: Framing,
        outbound: AsyncStream<JSONRPCMessage>,
        inbound: AsyncThrowingStream<JSONRPCMessage, any Error>.Continuation
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var decoder = framing // value copy → fresh buffer
                for try await buffer in execution.standardOutput {
                    let bytes = buffer.withUnsafeBytes { Array($0) }
                    for body in decoder.push(Data(bytes)) {
                        if let message = try? JSONRPCMessage.decodeMessages(from: body).first {
                            inbound.yield(message)
                        }
                    }
                }
            }
            group.addTask {
                for await message in outbound {
                    guard let body = try? message.encoded() else { continue }
                    try await writeAll(Array(framing.frame(body)), to: execution.standardInputWriter)
                }
                try? await execution.standardInputWriter.finish()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private static func writeAll(_ bytes: [UInt8], to writer: StandardInputWriter) async throws {
        var offset = 0
        while offset < bytes.count {
            let written = try await writer.write(Array(bytes[offset...]))
            if written <= 0 { break }
            offset += written
        }
    }

    // MARK: Current process (own stdin/stdout)

    private static func runCurrentProcess(
        framing: Framing,
        outbound: AsyncStream<JSONRPCMessage>,
        inbound: AsyncThrowingStream<JSONRPCMessage, any Error>.Continuation
    ) -> Task<Void, Never> {
        // Reader: our own stdin is a blocking fd, so it needs a thread.
        let reader = Thread {
            var decoder = framing
            let handle = FileHandle.standardInput
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break } // EOF: the host closed our stdin
                for body in decoder.push(chunk) {
                    if let message = try? JSONRPCMessage.decodeMessages(from: body).first {
                        inbound.yield(message)
                    }
                }
            }
            inbound.finish()
        }
        reader.name = "jsonrpc.stdio.reader"
        reader.stackSize = 4 << 20
        reader.start()

        // Writer: a single task drains outbound to our stdout (no lock needed).
        return Task {
            let out = FileHandle.standardOutput
            for await message in outbound {
                guard let body = try? message.encoded() else { continue }
                try? out.write(contentsOf: framing.frame(body))
            }
        }
    }
}

#endif
