// `Foundation.Process` exists on macOS / Linux / Windows, not on iOS-family OSes.
#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import JSONFoundation
import JSONRPCPeer
import JSONRPCWire

public struct ProcessExit: Sendable {
    public var code: Int32
    public var reason: Process.TerminationReason
}

/// Errors specific to launching the `Foundation.Process` transport.
public enum ProcessTransportError: Error, LocalizedError {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): return "Failed to launch process: \(reason)"
        }
    }
}

/// A ``JSONRPCMessageTransport`` backed by `Foundation.Process` — the
/// zero-dependency stdio transport, always available (no `Subprocess` trait).
///
/// It shares the framing layer with ``StdioMessageTransport`` (it's generic over
/// `MessageFraming` too); only the process/IO mechanics differ. A dedicated reader
/// thread and two `NSLock`s bridge Foundation's blocking reads and its
/// `terminationHandler` callback — the very machinery the `swift-subprocess`-based
/// ``StdioMessageTransport`` removes. Prefer the latter (trait `Subprocess`) for
/// cross-platform, lock-free I/O; this one needs no dependency.
public final class ProcessTransport<Framing: MessageFraming>: JSONRPCMessageTransport, @unchecked Sendable {
    private let framing: Framing
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false
    private var exitResult: ProcessExit?
    private var exitWaiters: [CheckedContinuation<ProcessExit, Never>] = []

    public var processIdentifier: Int32 { process.processIdentifier }

    public init(launch: ProcessLaunch, framing: Framing) throws {
        self.framing = framing
        process.executableURL = Self.resolveExecutable(launch.executable)
        process.arguments = launch.arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = launch.inheritStderr ? FileHandle.standardError : nil
        if let env = launch.environment {
            process.environment = env
        }
        if let cwd = launch.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let result = ProcessExit(code: proc.terminationStatus, reason: proc.terminationReason)
            self.stateLock.lock()
            self.exitResult = result
            let waiters = self.exitWaiters
            self.exitWaiters = []
            self.stateLock.unlock()
            for waiter in waiters { waiter.resume(returning: result) }
        }

        do {
            try process.run()
        } catch {
            throw ProcessTransportError.launchFailed("\(launch.executable): \(error.localizedDescription)")
        }
    }

    /// Suspends until the child exits, returning its termination status.
    public func waitForExit() async -> ProcessExit {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            if let result = exitResult {
                stateLock.unlock()
                continuation.resume(returning: result)
            } else {
                exitWaiters.append(continuation)
                stateLock.unlock()
            }
        }
    }

    public func send(_ message: JSONRPCMessage) throws {
        let framed = framing.frame(try message.encoded())
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        guard !closed else { throw JSONRPCPeerError.closed }
        try stdinPipe.fileHandleForWriting.write(contentsOf: framed)
    }

    public func makeInboundStream() -> AsyncThrowingStream<JSONRPCMessage, any Error> {
        let framing = self.framing
        return AsyncThrowingStream { continuation in
            let handle = stdoutPipe.fileHandleForReading
            let thread = Thread {
                var decoder = framing
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF: child closed stdout
                    for body in decoder.push(chunk) {
                        if let message = try? JSONRPCMessage.decodeMessages(from: body).first {
                            continuation.yield(message)
                        }
                    }
                }
                continuation.finish()
            }
            thread.name = "jsonrpc.process.reader"
            thread.stackSize = 4 << 20
            thread.start()

            continuation.onTermination = { [weak self] _ in
                self?.close()
            }
        }
    }

    public func close() {
        stateLock.lock()
        if isClosed {
            stateLock.unlock()
            return
        }
        isClosed = true
        stateLock.unlock()

        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    /// Forcefully kill the child (used after a graceful shutdown stalls).
    public func kill() {
        guard process.isRunning else { return }
        Foundation.kill(process.processIdentifier, SIGKILL)
    }

    private static func resolveExecutable(_ command: String) -> URL {
        if command.contains("/") {
            return URL(fileURLWithPath: command)
        }
        let defaultPath = "/usr/bin:/bin"
        let path = ProcessInfo.processInfo.environment["PATH"] ?? defaultPath
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: command)
    }
}

#endif
