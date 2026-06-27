// A POSIX-socket TCP client transport — works on Darwin and Glibc (macOS / iOS /
// Linux). Windows (winsock) is not covered; there it compiles to an unavailable
// stub.
#if !os(Windows)
import Foundation
import JSONFoundation
import JSONRPCPeer
import JSONRPCWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#endif

/// Errors specific to opening the TCP client transport.
public enum TCPClientTransportError: Error, LocalizedError {
    /// The host/port could not be resolved (`getaddrinfo` failed).
    case resolutionFailed(host: String, port: UInt16, detail: String)
    /// A socket could be created but no resolved address accepted a connection.
    case connectionFailed(host: String, port: UInt16, detail: String)

    public var errorDescription: String? {
        switch self {
        case .resolutionFailed(let host, let port, let detail):
            return "Failed to resolve \(host):\(port): \(detail)"
        case .connectionFailed(let host, let port, let detail):
            return "Failed to connect to \(host):\(port): \(detail)"
        }
    }
}

/// A ``JSONRPCMessageTransport`` over a TCP connection to `host:port`, parameterized
/// over the wire ``MessageFraming`` (newline for MCP/ACP, `Content-Length` for LSP).
///
/// This is the socket sibling of the stdio transports: same shape — a blocking
/// reader thread feeds the inbound stream, a locked blocking `write` serializes the
/// outbound half — only the file descriptor is a connected TCP socket instead of a
/// pipe. It connects to a listener; the *listening* side (accept loop, Bonjour
/// advertising) is intentionally out of scope, as that is where platform server
/// stacks (Network.framework, swift-nio) diverge.
///
/// Built on raw POSIX sockets so a single implementation serves macOS and Linux
/// with no dependency beyond the platform C library.
public final class TCPClientTransport<Framing: MessageFraming>: JSONRPCMessageTransport, @unchecked Sendable {
    private let framing: Framing
    private let descriptor: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false

    /// Opens a TCP connection to `host:port`. Blocks until the connection is
    /// established (or every resolved address has failed).
    public init(host: String, port: UInt16, framing: Framing) throws {
        self.framing = framing

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        // On Glibc/Musl `SOCK_STREAM` is an enum; on Darwin/Bionic it is an Int32.
        #if canImport(Glibc) || canImport(Musl)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let addresses = result else {
            let detail = String(cString: gai_strerror(status))
            throw TCPClientTransportError.resolutionFailed(host: host, port: port, detail: detail)
        }
        defer { freeaddrinfo(addresses) }

        var socketFD: Int32 = -1
        var lastErrno: Int32 = 0
        var candidate: UnsafeMutablePointer<addrinfo>? = addresses
        while let address = candidate {
            let sock = socket(
                address.pointee.ai_family,
                address.pointee.ai_socktype,
                address.pointee.ai_protocol
            )
            if sock >= 0 {
                if connect(sock, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 {
                    socketFD = sock
                    break
                }
                lastErrno = errno
                systemClose(sock)
            } else {
                lastErrno = errno
            }
            candidate = address.pointee.ai_next
        }

        guard socketFD >= 0 else {
            let detail = String(cString: strerror(lastErrno))
            throw TCPClientTransportError.connectionFailed(host: host, port: port, detail: detail)
        }
        self.descriptor = socketFD
    }

    public func send(_ message: JSONRPCMessage) throws {
        let framed = framing.frame(try message.encoded())
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        guard !closed else { throw JSONRPCPeerError.closed }

        try framed.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written <= 0 {
                    throw TCPClientTransportError.connectionFailed(
                        host: "", port: 0, detail: "socket write failed (errno \(errno))"
                    )
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    public func makeInboundStream() -> AsyncThrowingStream<JSONRPCMessage, any Error> {
        let framing = self.framing
        let descriptor = self.descriptor
        return AsyncThrowingStream { continuation in
            let thread = Thread {
                var decoder = framing
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                    if count <= 0 { break } // EOF or error: the peer closed the socket
                    for body in decoder.push(Data(buffer[0 ..< count])) {
                        if let message = try? JSONRPCMessage.decodeMessages(from: body).first {
                            continuation.yield(message)
                        }
                    }
                }
                continuation.finish()
            }
            thread.name = "jsonrpc.tcp.reader"
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

        shutdown(descriptor, Int32(SHUT_RDWR))
        systemClose(descriptor)
    }
}

/// Calls the C library `close(2)` unambiguously — at file scope the transport's
/// own `close()` method is not in scope, so this avoids the name clash.
private func systemClose(_ descriptor: Int32) {
    _ = close(descriptor)
}
#endif
