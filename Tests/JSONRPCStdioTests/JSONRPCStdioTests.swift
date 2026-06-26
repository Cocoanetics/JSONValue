#if os(macOS) || os(Linux)
import Foundation
import JSONFoundation
import Testing
import JSONRPCStdio
import JSONRPCWire

// `cat -u` echoes stdin to stdout verbatim, so a framed message sent out comes
// straight back — proving the Foundation.Process transport round-trips end to end.
@Test(.timeLimit(.minutes(1)))
func processTransportLoopbackThroughCat() async throws {
    let transport = try ProcessTransport(
        launch: ProcessLaunch(executable: "cat", arguments: ["-u"]),
        framing: LineFraming())
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    try transport.send(.request(id: 3, method: "ping", params: .string("hi")))
    let received = try await inbound.next()
    #expect(received?.method == "ping")
    #expect(received?.id == .integer(3))
    transport.close()
}
#endif
