import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JSONFoundation
import JSONRPCPeer
@testable import JSONRPCSSE
import Testing

@Suite("SSEClientTransport")
struct SSEClientTransportTests {
    /// Sending after close() rejects with the transport contract's error.
    @Test(.timeLimit(.minutes(1)))
    func sendAfterCloseThrowsClosed() throws {
        let transport = SSEClientTransport(endpoint: try #require(URL(string: "http://localhost:1/rpc")))
        transport.close()
        #expect(throws: JSONRPCPeerError.self) {
            try transport.send(.request(id: 1, method: "ping"))
        }
    }

    // The URLProtocol-stubbed tests are Darwin-only: swift-corelibs-foundation's
    // URLSession does not reliably honor custom protocol classes.
    #if canImport(Darwin)

    /// A POST answered with a plain JSON body yields that message inbound.
    @Test(.timeLimit(.minutes(1)))
    func directJSONResponseIsDelivered() async throws {
        let transport = SSEClientTransport(
            endpoint: try #require(URL(string: "https://stub.example/json")),
            session: Self.makeStubbedSession()
        )
        defer { transport.close() }

        try transport.send(.request(id: 1, method: "ping"))

        var iterator = transport.makeInboundStream().makeAsyncIterator()
        let message = try await iterator.next()
        #expect(message == .response(id: 1, result: .string("pong")))
    }

    /// A POST answered with a JSON-RPC batch delivers every element, not just
    /// the first (regression: transports used to truncate batches).
    @Test(.timeLimit(.minutes(1)))
    func batchResponseDeliversAllMessages() async throws {
        let transport = SSEClientTransport(
            endpoint: try #require(URL(string: "https://stub.example/json-batch")),
            session: Self.makeStubbedSession()
        )
        defer { transport.close() }

        try transport.send(.request(id: 1, method: "ping"))

        var iterator = transport.makeInboundStream().makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        #expect(first == .response(id: 1, result: .string("a")))
        #expect(second == .response(id: 2, result: .string("b")))
    }

    /// A POST answered with `text/event-stream` decodes each SSE event into an
    /// inbound message, exercising the newline-batched decode loop.
    @Test(.timeLimit(.minutes(1)))
    func sseResponseDeliversEachEvent() async throws {
        let transport = SSEClientTransport(
            endpoint: try #require(URL(string: "https://stub.example/sse")),
            session: Self.makeStubbedSession()
        )
        defer { transport.close() }

        try transport.send(.request(id: 1, method: "ping"))

        var iterator = transport.makeInboundStream().makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        #expect(first == .response(id: 1, result: .string("streamed")))
        #expect(second == .notification(method: "progress", params: nil))
    }

    private static func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    #endif
}

#if canImport(Darwin)

/// Serves canned responses keyed by the request path, so the transport's two
/// response modes (direct JSON vs. SSE stream) run without any network.
final class StubURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }

        let contentType: String
        let body: String
        switch url.path {
        case "/json":
            contentType = "application/json"
            body = #"{"jsonrpc":"2.0","id":1,"result":"pong"}"#
        case "/json-batch":
            contentType = "application/json"
            body = #"[{"jsonrpc":"2.0","id":1,"result":"a"},{"jsonrpc":"2.0","id":2,"result":"b"}]"#
        case "/sse":
            contentType = "text/event-stream"
            body = "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"streamed\"}\n\n"
                + "data: {\"jsonrpc\":\"2.0\",\"method\":\"progress\"}\n\n"
        default:
            contentType = "text/plain"
            body = ""
        }

        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

#endif
