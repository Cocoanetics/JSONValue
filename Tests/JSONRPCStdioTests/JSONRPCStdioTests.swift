#if os(macOS) || os(Linux)
import Foundation
import JSONFoundation
import JSONRPCStdio
import JSONRPCWire
import Testing

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

// A caller-supplied `ProcessLaunch.environment` must reach the child as a full
// replacement (the contract ACP/MCP clients rely on to inject auth vars into the
// agents they spawn) — mirroring the trait-gated Subprocess suite's test so the
// `Foundation.Process` transport's half is verified in a default build too. Spawn
// a shell whose *only* environment variable is `ACP_TEST_VAR` and have it echo
// that value back as a JSON-RPC method name; if the env were dropped (inherited),
// the expansion would be empty.
@Test(.timeLimit(.minutes(1)))
func processTransportChildReceivesCustomEnvironment() async throws {
    let script = #"printf '{"jsonrpc":"2.0","method":"%s","params":null}\n' "$ACP_TEST_VAR""#
    let transport = try ProcessTransport(
        launch: ProcessLaunch(
            executable: "/bin/sh", arguments: ["-c", script],
            environment: ["ACP_TEST_VAR": "hello-env"]),
        framing: LineFraming())
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    let received = try await inbound.next()
    #expect(received?.method == "hello-env")
    transport.close()
}
#endif
