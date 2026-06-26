import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JSONFoundation
import JSONRPCPeer
import JSONRPCWire

/// An HTTP+SSE **client** ``JSONRPCMessageTransport`` (MCP's "Streamable HTTP"
/// shape), built on `URLSession`.
///
/// The insight that lets it reuse ``JSONRPCPeer`` unchanged: SSE is server→client
/// only, so the client never has to route a reply onto a particular stream. It just
/// `send`s by POSTing, and funnels **everything that comes back — from every POST's
/// response — into one inbound stream**. A POST is answered either by a single JSON
/// body or by a kept-alive `text/event-stream`; either way the messages are merged
/// into `makeInboundStream()`, and the peer's id-correlation sorts the responses
/// from the notifications/requests. The transport is blind to which connection a
/// message arrived on — exactly the property that made the stdio peer reusable.
///
/// (The *server* side — choosing single-vs-stream and routing each reply onto its
/// originating request's response — needs the richer dispatch+scope boundary and is
/// out of scope here.)
public final class SSEClientTransport: JSONRPCMessageTransport, @unchecked Sendable {
    private let outbound: AsyncStream<JSONRPCMessage>.Continuation
    private let inbound: AsyncThrowingStream<JSONRPCMessage, any Error>
    private let pumpTask: Task<Void, Never>

    public init(endpoint: URL, session: URLSession = .shared, headers: [String: String] = [:]) {
        let (outboundStream, outboundContinuation) = AsyncStream<JSONRPCMessage>.makeStream()
        let (inboundStream, inboundContinuation) = AsyncThrowingStream<JSONRPCMessage, any Error>.makeStream()
        self.outbound = outboundContinuation
        self.inbound = inboundStream

        self.pumpTask = Task {
            // Each outbound message gets its own concurrent POST whose response
            // (direct JSON or an SSE stream) is merged into the one inbound stream.
            await withTaskGroup(of: Void.self) { group in
                for await message in outboundStream {
                    group.addTask {
                        await Self.postAndStream(
                            message, endpoint: endpoint, session: session,
                            headers: headers, inbound: inboundContinuation)
                    }
                }
            }
            inboundContinuation.finish()
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
        pumpTask.cancel()
    }

    private static func postAndStream(
        _ message: JSONRPCMessage,
        endpoint: URL,
        session: URLSession,
        headers: [String: String],
        inbound: AsyncThrowingStream<JSONRPCMessage, any Error>.Continuation
    ) async {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.httpBody = try message.encoded()

            let (bytes, response) = try await session.bytes(for: request)
            let contentType = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

            if contentType.contains("text/event-stream") {
                // Streamed: decode SSE events as they arrive, line by line.
                var decoder = SSEEventDecoder()
                var lineBatch = Data()
                for try await byte in bytes {
                    lineBatch.append(byte)
                    if byte == 0x0A {
                        for body in decoder.push(lineBatch) { yield(body, to: inbound) }
                        lineBatch.removeAll(keepingCapacity: true)
                    }
                }
                if !lineBatch.isEmpty {
                    for body in decoder.push(lineBatch) { yield(body, to: inbound) }
                }
            } else {
                // Direct: one JSON response in the body.
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                for message in (try? JSONRPCMessage.decodeMessages(from: data)) ?? [] {
                    inbound.yield(message)
                }
            }
        } catch {
            // Best-effort for the prototype: a failed POST is dropped, and the
            // pending request surfaces the failure at a higher layer (timeout). A
            // production transport would route the error to the originating request.
        }
    }

    private static func yield(
        _ body: Data, to inbound: AsyncThrowingStream<JSONRPCMessage, any Error>.Continuation
    ) {
        if let message = try? JSONRPCMessage.decodeMessages(from: body).first {
            inbound.yield(message)
        }
    }
}
