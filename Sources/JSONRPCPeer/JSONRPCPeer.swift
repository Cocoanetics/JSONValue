import Foundation
import JSONFoundation

/// A transport-agnostic JSON-RPC 2.0 peer: it correlates outbound requests with
/// their responses by `id`, dispatches inbound requests to a handler
/// (concurrently, so a slow handler can't stall the read loop), and delivers
/// notifications in arrival order.
///
/// ## Why this exists
///
/// This is the generic correlator+dispatcher that SwiftMCP, SwiftACP, and this LSP
/// POC each hand-rolled separately. Pulled out here over ``JSONRPCMessageTransport``
/// — which trades in whole ``JSONRPCMessage`` values, leaving framing and JSON
/// coding entirely to the transport — it is reusable verbatim across all three.
/// LSP and ACP differ *only* in framing (`Content-Length` vs newline), which lives
/// in the transport, so the peer itself never changes.
///
/// Candidate for extraction into a shared package on top of JSONFoundation (which
/// already owns the `JSONRPCMessage` wire model); this target is the prototype.
///
/// ## Pull vs push
///
/// The peer supports both ownership models, which is what lets all three sibling
/// projects adopt it:
/// - **Pull** — `init(transport:)` + ``start()``: the peer owns the read loop and
///   reads inbound messages off the transport. This is how LSP and ACP (which each
///   own a subprocess pipe) use it.
/// - **Push** — `init(sink:)` + ``ingest(_:)``: some other component already owns
///   the read loop and feeds inbound messages in. This is how SwiftMCP would use
///   it — its `MCPTransport` reads the wire and drives dispatch, so the peer is
///   needed only for outbound request/response correlation (the `MCPServerProxy`
///   client and the server's `sampling`/`elicitation` requests).
public actor JSONRPCPeer {
    /// Handles an inbound (peer-originated) request; returns the result or an error.
    public typealias RequestHandler =
        @Sendable (_ method: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCError>
    /// Handles an inbound notification (no reply).
    public typealias NotificationHandler =
        @Sendable (_ method: String, _ params: JSONValue?) async -> Void

    /// Direction of a message on the wire, for the optional wire log.
    public enum WireDirection: Sendable { case outbound, inbound }

    private let sink: JSONRPCMessageSink
    /// Non-nil only in pull mode — the transport whose read loop the peer owns.
    private let ownedTransport: JSONRPCMessageTransport?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var requestHandler: RequestHandler?
    private var notificationHandler: NotificationHandler?
    private var wireLog: (@Sendable (WireDirection, JSONRPCMessage) -> Void)?
    private var readTask: Task<Void, Never>?
    private var isClosed = false

    /// Pull mode: the peer owns the transport's read loop (call ``start()``).
    public init(transport: JSONRPCMessageTransport) {
        self.sink = transport
        self.ownedTransport = transport
    }

    /// Push mode: outbound goes to `sink`; the caller owns reading and feeds inbound
    /// messages via ``ingest(_:)``. ``start()`` is a no-op.
    public init(sink: JSONRPCMessageSink) {
        self.sink = sink
        self.ownedTransport = nil
    }

    /// Install handlers for inbound requests and notifications. Optional: with no
    /// request handler, inbound requests are acknowledged with a null success so a
    /// peer that required a reply isn't left waiting.
    public func setHandlers(request: RequestHandler?, notification: NotificationHandler?) {
        self.requestHandler = request
        self.notificationHandler = notification
    }

    /// Observe every message in both directions, in chronological order (for a
    /// raw-protocol log). The closure runs synchronously, so keep it fast. Pass
    /// `nil` to stop.
    public func setWireLog(_ log: (@Sendable (WireDirection, JSONRPCMessage) -> Void)?) {
        self.wireLog = log
    }

    /// Begin reading inbound messages (pull mode). Call once, after handlers are
    /// set. A no-op in push mode — there feed messages via ``ingest(_:)`` instead.
    public func start() {
        guard readTask == nil, let ownedTransport else { return }
        let stream = ownedTransport.makeInboundStream()
        readTask = Task { [weak self] in
            do {
                for try await message in stream {
                    await self?.ingest(message)
                }
            } catch {
                await self?.failAllPending(with: error)
            }
            await self?.handleStreamEnd()
        }
    }

    /// Suspends until the inbound stream ends (peer disconnected / EOF) or
    /// ``close()`` is called.
    public func waitUntilClosed() async {
        await readTask?.value
    }

    // MARK: Sending

    /// Send a request and await its result as raw JSON.
    public func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        let id = allocateID()
        let message = JSONRPCMessage.request(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            if isClosed {
                continuation.resume(throwing: JSONRPCPeerError.closed)
                return
            }
            pending[id] = continuation
            do {
                wireLog?(.outbound, message)
                try sink.send(message)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Send a notification (no reply expected).
    public func sendNotification(method: String, params: JSONValue?) throws {
        let message = JSONRPCMessage.notification(method: method, params: params)
        wireLog?(.outbound, message)
        try sink.send(message)
    }

    private func allocateID() -> Int {
        nextID += 1
        return nextID
    }

    // MARK: Receiving

    /// Feed one inbound message to the peer (push mode). In pull mode the read loop
    /// calls this for you. Classifies the message: correlates a response back to its
    /// pending request, dispatches a request to the handler, or delivers a
    /// notification.
    public func ingest(_ message: JSONRPCMessage) async {
        wireLog?(.inbound, message)
        switch message {
        case .request(let request):
            dispatchRequest(id: request.id, method: request.method, params: request.params)
        case .notification(let notification):
            await notificationHandler?(notification.method, notification.params)
        case .response, .errorResponse:
            if let id = message.id, let outcome = message.replyOutcome {
                resolveResponse(id: id, outcome: outcome)
            }
        }
    }

    private func resolveResponse(id: JSONRPCID, outcome: Result<JSONValue?, JSONRPCError>) {
        guard case .integer(let key) = id, let continuation = pending.removeValue(forKey: key) else {
            return
        }
        switch outcome {
        case .success(let result):
            continuation.resume(returning: result ?? .null)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func dispatchRequest(id: JSONRPCID, method: String, params: JSONValue?) {
        let handler = requestHandler
        Task { [weak self] in
            let outcome: Result<JSONValue, JSONRPCError>
            if let handler {
                outcome = await handler(method, params)
            } else {
                outcome = .success(.null)
            }
            await self?.sendReply(id: id, outcome: outcome)
        }
    }

    private func sendReply(id: JSONRPCID, outcome: Result<JSONValue, JSONRPCError>) {
        let message: JSONRPCMessage
        switch outcome {
        case .success(let result):
            message = .response(id: id, result: result)
        case .failure(let error):
            message = .errorResponse(id: id, error: error)
        }
        wireLog?(.outbound, message)
        try? sink.send(message)
    }

    private func handleStreamEnd() {
        failAllPending(with: JSONRPCPeerError.closed)
    }

    private func failAllPending(with error: Error) {
        let waiters = pending
        pending = [:]
        for (_, continuation) in waiters {
            continuation.resume(throwing: error)
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        readTask?.cancel()
        // Only close a transport we own; in push mode the caller owns the wire.
        ownedTransport?.close()
        failAllPending(with: JSONRPCPeerError.closed)
    }
}
