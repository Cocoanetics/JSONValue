import Foundation
@testable import JSONRPCPeer
import Testing

/// A minimal caller that holds the (non-thread-safe) correlator inside its own
/// isolation — exactly how a real consumer (SwiftMCP's `Session` actor) uses it.
private actor Caller {
    let correlator = RequestCorrelator<String, Int>()

    func send(_ id: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            correlator.register(id, continuation)
        }
    }

    @discardableResult
    func deliver(_ id: String, _ value: Int) -> Bool { correlator.resolve(id, with: value) }
    func tearDown() { correlator.failAll() }
    var pending: Int { correlator.count }
}

private func waitUntil(_ caller: Caller, pending target: Int) async {
    while await caller.pending < target { await Task.yield() }
}

@Test(.timeLimit(.minutes(1)))
func resolvesARegisteredWaiter() async throws {
    let caller = Caller()
    async let reply = caller.send("a")
    await waitUntil(caller, pending: 1)
    #expect(await caller.deliver("a", 42))
    #expect(try await reply == 42)
    #expect(await caller.pending == 0)
}

@Test func resolvingAnUnknownIdIsANoOp() {
    let correlator = RequestCorrelator<String, Int>()
    #expect(correlator.resolve("nope", with: 1) == false)
    #expect(correlator.fail("nope", with: CancellationError()) == false)
    #expect(correlator.isPending("nope") == false)
}

@Test(.timeLimit(.minutes(1)))
func aSecondResolveDoesNotResumeTwice() async throws {
    let caller = Caller()
    async let reply = caller.send("a")
    await waitUntil(caller, pending: 1)
    #expect(await caller.deliver("a", 1) == true) // first wins
    #expect(await caller.deliver("a", 2) == false) // second: no waiter, no double-resume
    #expect(try await reply == 1)
}

@Test(.timeLimit(.minutes(1)))
func failAllRejectsEveryWaiter() async {
    let caller = Caller()
    async let reply1: Int = caller.send("a")
    async let reply2: Int = caller.send("b")
    await waitUntil(caller, pending: 2)

    await caller.tearDown()

    var cancelled = 0
    do { _ = try await reply1 } catch is CancellationError { cancelled += 1 } catch {}
    do { _ = try await reply2 } catch is CancellationError { cancelled += 1 } catch {}
    #expect(cancelled == 2)
    #expect(await caller.pending == 0)
}
