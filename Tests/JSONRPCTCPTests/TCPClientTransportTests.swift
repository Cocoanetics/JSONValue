// The transport itself compiles on every POSIX platform (Darwin / Glibc / Musl /
// Bionic); the integration test — which spins a local listener and threads — runs
// on macOS and Linux, matching the stdio transport's test gating.
#if os(macOS) || os(Linux)
import Foundation
import JSONFoundation
import JSONRPCPeer
@testable import JSONRPCTCP
import JSONRPCWire
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("TCPClientTransport")
struct TCPClientTransportTests {
    /// A framed message written to a TCP echo server comes straight back, proving
    /// the socket transport connects, frames, writes and reads end to end — the
    /// same loopback proof the stdio transport runs through `cat -u`.
    @Test(.timeLimit(.minutes(1)))
    func echoServerRoundTrip() async throws {
        let server = try TCPEchoServer()
        defer { server.stop() }

        let transport = try TCPClientTransport(
            host: "127.0.0.1", port: server.port, framing: LineFraming()
        )
        var inbound = transport.makeInboundStream().makeAsyncIterator()

        try transport.send(.request(id: 7, method: "ping", params: .string("hi")))
        let received = try await inbound.next()
        #expect(received?.method == "ping")
        #expect(received?.id == .integer(7))

        transport.close()
    }

    /// Driven by a full `JSONRPCPeer`: the echo server bounces the *request* back,
    /// which the client peer (having no matching pending id for it) simply ignores
    /// — so this asserts the transport plugs into the peer without crashing and the
    /// reader thread keeps running. Correlated request/response is covered by the
    /// loopback and stdio suites; here the point is the socket plumbing.
    @Test(.timeLimit(.minutes(1)))
    func pluggableIntoPeer() async throws {
        let server = try TCPEchoServer()
        defer { server.stop() }

        let transport = try TCPClientTransport(
            host: "127.0.0.1", port: server.port, framing: LineFraming()
        )
        let peer = JSONRPCPeer(transport: transport)
        await peer.start()
        // A notification is fire-and-forget; the echo bounces it back as an inbound
        // notification, which the peer dispatches (to a nil handler) without error.
        try await peer.sendNotification(method: "tick", params: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        await peer.close()
    }
}

/// A minimal single-connection TCP echo server on `127.0.0.1`, ephemeral port.
/// Accepts one client and echoes every byte back until EOF.
private final class TCPEchoServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private var thread: Thread?

    init() throws {
        let listener = socket(AF_INET, sockStreamValue, 0)
        guard listener >= 0 else { throw POSIXTestError("socket() failed (errno \(errno))") }

        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(0).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(listener, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(listener)
            throw POSIXTestError("bind() failed (errno \(errno))")
        }
        guard listen(listener, 1) == 0 else {
            close(listener)
            throw POSIXTestError("listen() failed (errno \(errno))")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                getsockname(listener, pointer, &length)
            }
        }

        self.listenFD = listener
        self.port = UInt16(bigEndian: assigned.sin_port)
        start()
    }

    private func start() {
        let listener = listenFD
        let thread = Thread {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                var offset = 0
                while offset < count {
                    let written = buffer.withUnsafeBytes { raw -> Int in
                        write(client, raw.baseAddress!.advanced(by: offset), count - offset)
                    }
                    if written <= 0 { break }
                    offset += written
                }
            }
            close(client)
        }
        thread.name = "tcp.echo.server"
        thread.start()
        self.thread = thread
    }

    func stop() {
        shutdown(listenFD, Int32(SHUT_RDWR))
        close(listenFD)
    }
}

private struct POSIXTestError: Error { let message: String; init(_ message: String) { self.message = message } }

#if canImport(Glibc)
private let sockStreamValue = Int32(SOCK_STREAM.rawValue)
#else
private let sockStreamValue = SOCK_STREAM
#endif
#endif
