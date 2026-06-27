import Foundation
import Testing
import JSONFoundation
@testable import JSONRPCPeer

@Suite("LoopbackTransport")
struct LoopbackTransportTests {
    /// A client peer's request reaches the server peer's handler and its result
    /// flows back — the full correlate-and-dispatch loop over an in-memory pair.
    @Test(.timeLimit(.minutes(1)))
    func pairRoundTripsRequestResponse() async throws {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()

        let server = JSONRPCPeer(transport: serverTransport)
        await server.setHandlers(
            request: { method, _ in .success(.string("pong:\(method)")) },
            notification: nil
        )
        await server.start()

        let client = JSONRPCPeer(transport: clientTransport)
        await client.start()

        let result = try await client.sendRequest(method: "ping", params: .string("hi"))
        #expect(result == .string("pong:ping"))

        await client.close()
        await server.close()
    }

    /// Notifications cross the pair in arrival order and reach the peer's handler.
    @Test(.timeLimit(.minutes(1)))
    func pairDeliversNotifications() async throws {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()

        let received = NotificationCollector()
        let server = JSONRPCPeer(transport: serverTransport)
        await server.setHandlers(
            request: nil,
            notification: { method, _ in await received.record(method) }
        )
        await server.start()

        let client = JSONRPCPeer(transport: clientTransport)
        await client.start()

        try await client.sendNotification(method: "a", params: nil)
        try await client.sendNotification(method: "b", params: nil)

        // Give the inbound stream a moment to deliver both notifications.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await received.methods == ["a", "b"])

        await client.close()
        await server.close()
    }

    /// Closing one end finishes the other end's inbound stream.
    @Test(.timeLimit(.minutes(1)))
    func closingOneEndEndsThePeerStream() async throws {
        let (clientTransport, serverTransport) = LoopbackTransport.pair()
        var serverInbound = serverTransport.makeInboundStream().makeAsyncIterator()

        clientTransport.close()

        let next = try await serverInbound.next()
        #expect(next == nil) // stream finished, no element
    }

    private actor NotificationCollector {
        private(set) var methods: [String] = []
        func record(_ method: String) { methods.append(method) }
    }
}
