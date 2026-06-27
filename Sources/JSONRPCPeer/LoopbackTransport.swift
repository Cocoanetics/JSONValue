import Foundation
import JSONFoundation

/// Two ``JSONRPCMessageTransport``s wired back-to-back in memory: what one end
/// writes, the other reads. Lets a client and a server peer run in the same
/// process — for embedding a server inside an app, or for hermetic protocol tests
/// with no subprocess or socket.
///
/// As an in-memory transport it does **no framing**: it hands whole
/// ``JSONRPCMessage`` values straight across, which is exactly the seam
/// ``JSONRPCMessageTransport`` defines (the wire — framing *and* JSON coding — is a
/// transport concern, and there is no wire here). This is the "loopback transport
/// (tests)" the protocol's own documentation refers to, promoted to a reusable type
/// so every consumer stops re-implementing it.
///
/// ```swift
/// let (clientTransport, serverTransport) = LoopbackTransport.pair()
/// let client = JSONRPCPeer(transport: clientTransport)
/// let server = JSONRPCPeer(transport: serverTransport)
/// await server.setHandlers(request: { method, _ in .success(.string("pong:\(method)")) },
///                          notification: nil)
/// await server.start()
/// await client.start()
/// let result = try await client.sendRequest(method: "ping", params: nil)
/// ```
///
/// Messages written before the peer end has called ``makeInboundStream()`` are
/// buffered and delivered when it does, so the two ends can be started in either
/// order. Closing either end finishes the other's inbound stream.
public final class LoopbackTransport: JSONRPCMessageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation?
    private var pending: [JSONRPCMessage] = []
    private var deliver: (@Sendable (JSONRPCMessage) -> Void)?
    private var closePeer: (@Sendable () -> Void)?
    private var isClosed = false

    /// Creates a single, unconnected endpoint. Most callers want ``pair()``; this
    /// is exposed for advanced wiring (e.g. fanning one end out manually).
    public init() {}

    /// A connected pair: hand one end to a client peer and the other to a server
    /// peer. What one `send`s arrives on the other's inbound stream. Closing either
    /// end ends the other's inbound stream.
    public static func pair() -> (client: LoopbackTransport, server: LoopbackTransport) {
        let client = LoopbackTransport()
        let server = LoopbackTransport()
        client.deliver = { [weak server] message in server?.receive(message) }
        server.deliver = { [weak client] message in client?.receive(message) }
        client.closePeer = { [weak server] in server?.close() }
        server.closePeer = { [weak client] in client?.close() }
        return (client, server)
    }

    private func receive(_ message: JSONRPCMessage) {
        lock.lock()
        if let continuation {
            lock.unlock()
            continuation.yield(message)
        } else {
            pending.append(message)
            lock.unlock()
        }
    }

    public func makeInboundStream() -> AsyncThrowingStream<JSONRPCMessage, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            let buffered = pending
            pending = []
            let closed = isClosed
            lock.unlock()
            for message in buffered { continuation.yield(message) }
            if closed { continuation.finish() }
        }
    }

    public func send(_ message: JSONRPCMessage) throws {
        lock.lock()
        let closed = isClosed
        let send = deliver
        lock.unlock()
        guard !closed else { throw JSONRPCPeerError.closed }
        send?(message)
    }

    public func close() {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        let continuation = self.continuation
        self.continuation = nil
        let peerClose = closePeer
        closePeer = nil
        deliver = nil
        lock.unlock()
        continuation?.finish()
        peerClose?()
    }
}
