import Foundation
import JSONFoundation
@testable import JSONRPCPeer
import Testing

/// An injectable in-memory ``JSONRPCMessageTransport`` spy for white-box peer
/// tests: `onSend` observes outbound messages (and can auto-respond), `inject`
/// pushes inbound ones. Distinct from the shipping ``LoopbackTransport`` (a
/// connected client/server *pair*) — here a single end is driven by hand.
final class SpyTransport: JSONRPCMessageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation?
    private var _sent: [JSONRPCMessage] = []
    /// Invoked synchronously on each outbound message, so a test can auto-respond.
    var onSend: (@Sendable (JSONRPCMessage, SpyTransport) -> Void)?

    func send(_ message: JSONRPCMessage) throws {
        lock.lock(); _sent.append(message); let callback = onSend; lock.unlock()
        callback?(message, self)
    }

    func makeInboundStream() -> AsyncThrowingStream<JSONRPCMessage, Error> {
        AsyncThrowingStream { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
        }
    }

    /// Simulate an inbound message arriving from the peer.
    func inject(_ message: JSONRPCMessage) {
        lock.lock(); let continuation = continuation; lock.unlock()
        continuation?.yield(message)
    }

    func finishInbound() {
        lock.lock(); let continuation = continuation; lock.unlock()
        continuation?.finish()
    }

    var sent: [JSONRPCMessage] {
        lock.lock(); defer { lock.unlock() }; return _sent
    }

    func close() { finishInbound() }
}

@Test(.timeLimit(.minutes(1)))
func correlatesRequestWithItsResponse() async throws {
    let transport = SpyTransport()
    transport.onSend = { message, transport in
        if case .request(let request) = message {
            transport.inject(.response(id: request.id, result: .string("pong")))
        }
    }
    let peer = JSONRPCPeer(transport: transport)
    await peer.start()

    let result = try await peer.sendRequest(method: "ping", params: nil)
    #expect(result.stringValue == "pong")
    await peer.close()
}

@Test(.timeLimit(.minutes(1)))
func surfacesErrorResponsesAsThrows() async throws {
    let transport = SpyTransport()
    transport.onSend = { message, transport in
        if case .request(let request) = message {
            transport.inject(.errorResponse(id: request.id, error: .methodNotFound(request.method)))
        }
    }
    let peer = JSONRPCPeer(transport: transport)
    await peer.start()

    await #expect(throws: JSONRPCError.self) {
        _ = try await peer.sendRequest(method: "nope", params: nil)
    }
    await peer.close()
}

@Test(.timeLimit(.minutes(1)))
func deliversInboundNotificationsToHandler() async {
    let transport = SpyTransport()
    let delivered = OnceBox<String>()
    let peer = JSONRPCPeer(transport: transport)
    await peer.setHandlers(request: nil, notification: { method, _ in delivered.fire(method) })
    await peer.start()

    transport.inject(.notification(method: "window/logMessage", params: .string("hi")))
    #expect(await delivered.value == "window/logMessage")
    await peer.close()
}

/// Inject `request` and await the peer's outbound reply — deterministically, with no
/// sleep or poll. Inbound requests are answered from a separate task (so the read loop
/// isn't parked inside an arbitrary handler — see `dispatchRequest`), so the reply
/// arrives asynchronously. Register the transport's synchronous `onSend` hook *before*
/// injecting, so the reply can't be missed, and resume the instant it's sent. Each
/// caller carries a `.timeLimit`, so a regression that never replies fails rather than
/// hanging.
private func injectAndAwaitReply(
    _ transport: SpyTransport, _ request: JSONRPCMessage
) async -> JSONRPCMessage {
    let reply = OnceBox<JSONRPCMessage>()
    transport.onSend = { message, _ in if message.id == request.id { reply.fire(message) } }
    transport.inject(request)
    return await reply.value
}

/// A one-shot async box: `fire` (called from a synchronous callback) delivers a value
/// and `value` awaits it — either order works, so there's no sleep or poll. Resolves
/// exactly once.
private final class OnceBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var continuation: CheckedContinuation<Value, Never>?
    func fire(_ value: Value) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            if stored == nil { stored = value }
            lock.unlock()
        }
    }
    var value: Value {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let stored {
                    lock.unlock()
                    continuation.resume(returning: stored)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func dispatchesInboundRequestsAndRepliesWithHandlerResult() async {
    let transport = SpyTransport()
    let peer = JSONRPCPeer(transport: transport)
    await peer.setHandlers(
        request: { method, _ in .success(.string("handled:\(method)")) },
        notification: nil)
    await peer.start()

    let reply = await injectAndAwaitReply(
        transport, .request(id: 99, method: "doThing", params: nil))
    #expect(reply.result?.stringValue == "handled:doThing")
    await peer.close()
}

@Test(.timeLimit(.minutes(1)))
func acknowledgesInboundRequestsWithNullWhenNoHandler() async {
    let transport = SpyTransport()
    let peer = JSONRPCPeer(transport: transport)
    await peer.setHandlers(request: nil, notification: nil)
    await peer.start()

    let reply = await injectAndAwaitReply(
        transport, .request(id: 7, method: "client/registerCapability", params: nil))
    #expect(reply.isResponse == true)
    await peer.close()
}

/// A bare send sink with no read loop — models SwiftMCP's split, where the
/// transport owns reading and the peer is used only for outbound correlation.
private final class CapturingSink: JSONRPCMessageSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [JSONRPCMessage] = []
    var onSend: (@Sendable (JSONRPCMessage) -> Void)?
    func send(_ message: JSONRPCMessage) throws {
        lock.lock(); _sent.append(message); let callback = onSend; lock.unlock()
        callback?(message)
    }
    var sent: [JSONRPCMessage] { lock.lock(); defer { lock.unlock() }; return _sent }
}

@Test(.timeLimit(.minutes(1)))
func pushModeCorrelatesOutboundRequestsViaIngest() async throws {
    // The peer never reads a wire here: outbound goes to a sink, and a reply is
    // fed back through `ingest` — exactly how SwiftMCP's MCPServerProxy/Session
    // (which own their own read loop) would delegate correlation to the peer.
    let sink = CapturingSink()
    let peer = JSONRPCPeer(sink: sink)
    sink.onSend = { message in
        if case .request(let request) = message {
            Task { await peer.ingest(.response(id: request.id, result: .string("via-ingest"))) }
        }
    }
    let result = try await peer.sendRequest(method: "sampling/createMessage", params: nil)
    #expect(result.stringValue == "via-ingest")
    #expect(sink.sent.first?.method == "sampling/createMessage")
    await peer.close()
}

@Test(.timeLimit(.minutes(1)))
func streamEndFailsPendingRequests() async throws {
    let transport = SpyTransport()
    let peer = JSONRPCPeer(transport: transport)
    await peer.start()

    // onSend fires synchronously inside sendRequest, after the continuation is
    // parked — so the request is guaranteed pending before the stream finishes.
    let parked = OnceBox<JSONRPCMessage>()
    transport.onSend = { message, _ in parked.fire(message) }

    let request = Task {
        try await peer.sendRequest(method: "hang", params: nil)
    }
    _ = await parked.value
    transport.finishInbound()

    await #expect(throws: JSONRPCPeerError.self) {
        _ = try await request.value
    }
}

@Test(.timeLimit(.minutes(1)))
func sendRequestHonorsTaskCancellation() async throws {
    let transport = SpyTransport()
    let peer = JSONRPCPeer(transport: transport)
    await peer.start()

    // onSend fires synchronously inside sendRequest, after the continuation is
    // parked — so cancelling after this signal can't race the registration.
    let parked = OnceBox<JSONRPCMessage>()
    transport.onSend = { message, _ in parked.fire(message) }

    let task = Task {
        try await peer.sendRequest(method: "never-answered", params: nil)
    }
    _ = await parked.value
    task.cancel()

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
    await peer.close()
}

@Test(.timeLimit(.minutes(1)))
func sendRequestAfterStreamEndRejects() async throws {
    // After the inbound stream ends, a *new* request must reject rather than park a
    // continuation no reader will ever resolve.
    let transport = SpyTransport()
    let peer = JSONRPCPeer(transport: transport)
    await peer.start()
    transport.finishInbound()
    await peer.waitUntilClosed()
    await #expect(throws: JSONRPCPeerError.self) {
        _ = try await peer.sendRequest(method: "afterClose", params: nil)
    }
}
