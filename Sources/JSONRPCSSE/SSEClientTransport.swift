import Foundation
#if canImport(FoundationNetworking)
// On non-Apple platforms URLSession / URLRequest live in FoundationNetworking.
import FoundationNetworking
#endif
import JSONFoundation
import JSONRPCPeer
import JSONRPCWire

// SwiftCross backfills `URLSession.bytes(for:)` — a Darwin-only API — on the
// FoundationNetworking platforms (Linux / Windows / Android) via a delegate-based
// streaming shim, so this transport compiles and streams everywhere.
import SwiftCross

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
///
/// **Error handling is best-effort:** a failed POST — and any response body that
/// does not decode as JSON-RPC — is dropped silently; nothing is yielded and no
/// error is thrown on the inbound stream. A pending request whose POST failed
/// therefore surfaces its failure only at a higher layer (e.g. the caller's
/// timeout, or ``close()`` failing everything pending). Routing an HTTP error back
/// to its originating request would contradict the id-blind design above.
public final class SSEClientTransport: JSONRPCMessageTransport, @unchecked Sendable {
    private let outbound: AsyncStream<JSONRPCMessage>.Continuation
    private let inbound: AsyncThrowingStream<JSONRPCMessage, any Error>
    private let pumpTask: Task<Void, Never>

    /// Creates a transport that POSTs every outbound message to one HTTP endpoint.
    ///
    /// - Parameters:
    ///   - endpoint: The JSON-RPC endpoint URL each message is POSTed to.
    ///   - session: The `URLSession` performing the POSTs — pass a custom one for
    ///     proxying, certificate pinning, or timeout policy.
    ///   - headers: Additional header fields set on every POST, e.g.
    ///     `Authorization` or MCP's `Mcp-Session-Id`. (`Content-Type` and `Accept`
    ///     are set by the transport.)
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
        for message in (try? JSONRPCMessage.decodeMessages(from: body)) ?? [] {
            inbound.yield(message)
        }
    }
}
