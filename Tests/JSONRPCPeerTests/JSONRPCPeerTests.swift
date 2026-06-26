import Foundation
import JSONFoundation
import Testing
@testable import JSONRPCPeer

/// An in-memory ``JSONRPCMessageTransport`` — no framing, no subprocess, no bytes.
/// That the peer drives it unchanged is the point: framing lives in the transport,
/// so the peer is reusable across LSP (Content-Length), ACP (newline), and this.
final class LoopbackTransport: JSONRPCMessageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation?
    private var _sent: [JSONRPCMessage] = []
    /// Invoked synchronously on each outbound message, so a test can auto-respond.
    var onSend: (@Sendable (JSONRPCMessage, LoopbackTransport) -> Void)?

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

private actor Recorder {
    private(set) var methods: [String] = []
    func record(_ method: String) { methods.append(method) }
}

@Test func correlatesRequestWithItsResponse() async throws {
    let transport = LoopbackTransport()
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

@Test func surfacesErrorResponsesAsThrows() async throws {
    let transport = LoopbackTransport()
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

@Test func deliversInboundNotificationsToHandler() async throws {
    let transport = LoopbackTransport()
    let recorder = Recorder()
    let peer = JSONRPCPeer(transport: transport)
    await peer.setHandlers(request: nil, notification: { method, _ in await recorder.record(method) })
    await peer.start()

    transport.inject(.notification(method: "window/logMessage", params: .string("hi")))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await recorder.methods == ["window/logMessage"])
    await peer.close()
}

@Test func dispatchesInboundRequestsAndRepliesWithHandlerResult() async throws {
    let transport = LoopbackTransport()
    let peer = JSONRPCPeer(transport: transport)
    await peer.setHandlers(
        request: { method, _ in .success(.string("handled:\(method)")) },
        notification: nil)
    await peer.start()

    transport.inject(.request(id: 99, method: "doThing", params: nil))
    try await Task.sleep(for: .milliseconds(100))

    let reply = transport.sent.first { $0.id == .integer(99) }
    #expect(reply?.result?.stringValue == "handled:doThing")
    await peer.close()
}

@Test func acknowledgesInboundRequestsWithNullWhenNoHandler() async throws {
    let transport = LoopbackTransport()
    let peer = JSONRPCPeer(transport: transport)
    await peer.setHandlers(request: nil, notification: nil)
    await peer.start()

    transport.inject(.request(id: 7, method: "client/registerCapability", params: nil))
    try await Task.sleep(for: .milliseconds(100))

    let reply = transport.sent.first { $0.id == .integer(7) }
    #expect(reply?.isResponse == true)
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

@Test func pushModeCorrelatesOutboundRequestsViaIngest() async throws {
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

@Test func streamEndFailsPendingRequests() async throws {
    let transport = LoopbackTransport()
    let peer = JSONRPCPeer(transport: transport)
    await peer.start()

    await #expect(throws: JSONRPCPeerError.self) {
        async let result = peer.sendRequest(method: "hang", params: nil)
        try await Task.sleep(for: .milliseconds(50))
        transport.finishInbound()
        _ = try await result
    }
}
