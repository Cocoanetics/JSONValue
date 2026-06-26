// Only meaningful with the `Subprocess` trait enabled; otherwise the module and
// these tests compile to nothing.
#if Subprocess
import Foundation
import JSONFoundation
import Testing
import JSONRPCSubprocess
import JSONRPCWire

@Test(.timeLimit(.minutes(1)))
func stdioMessageTransportLoopbackThroughCat() async throws {
    let transport = StdioMessageTransport(
        endpoint: .childProcess(ProcessLaunch(executable: "cat", arguments: ["-u"])),
        framing: LineFraming())
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    try transport.send(.request(id: 9, method: "documentSymbol", params: nil))
    let received = try await inbound.next()
    #expect(received?.method == "documentSymbol")
    #expect(received?.id == .integer(9))
    transport.close()
}

// A caller-supplied `ProcessLaunch.environment` must reach the child as a full
// replacement (the contract the `Foundation.Process` transport already honors, and
// the one ACP/MCP clients rely on to inject auth vars into spawned agents). Spawn a
// shell whose *only* environment variable is `ACP_TEST_VAR` and have it echo that
// value back as a JSON-RPC method name; if the env were dropped (`.inherit`), the
// expansion would be empty.
@Test(.timeLimit(.minutes(1)))
func childProcessReceivesCustomEnvironment() async throws {
    let script = #"printf '{"jsonrpc":"2.0","method":"%s","params":null}\n' "$ACP_TEST_VAR""#
    let transport = StdioMessageTransport(
        endpoint: .childProcess(ProcessLaunch(
            executable: "/bin/sh", arguments: ["-c", script],
            environment: ["ACP_TEST_VAR": "hello-env"])),
        framing: LineFraming())
    var inbound = transport.makeInboundStream().makeAsyncIterator()
    let received = try await inbound.next()
    #expect(received?.method == "hello-env")
    transport.close()
}
#endif
