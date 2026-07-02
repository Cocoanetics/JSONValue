import Foundation
@testable import JSONRPCSSEServer
import Testing

/// A test ``SSEStreamSink`` whose liveness can be flipped (socket drop) and whose
/// force-close is observable.
private final class FakeSink: SSEStreamSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _live = true
    private var _closed = false
    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return _live }
    var wasClosed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    func close() { lock.lock(); _live = false; _closed = true; lock.unlock() }
    func drop() { lock.lock(); _live = false; lock.unlock() } // socket died without a clean close
}

/// Drain up to `count` chunks (as strings) from a stream, then stop.
private func collect(_ stream: AsyncStream<Data>, count: Int) async -> [String] {
    var out: [String] = []
    guard count > 0 else { return out }
    for await chunk in stream {
        out.append(String(data: chunk, encoding: .utf8) ?? "")
        if out.count == count { break }
    }
    return out
}

@Test func primingThenSendsCarrySequentialEventIDs() async {
    let hub = SSEStreamHub(bufferCapacity: 8, retentionInterval: 60)
    let (stream, sid) = hub.open(replayable: true, primed: true, rejectsSendAfterCompletion: true)
    hub.send(SSEMessage(data: "one"), to: sid)
    hub.send(SSEMessage(data: "two"), to: sid)

    let chunks = await collect(stream, count: 3)
    #expect(chunks[0] == "id: \(sid.uuidString):1\ndata:\n\n") // priming
    #expect(chunks[1] == "id: \(sid.uuidString):2\ndata: one\n\n")
    #expect(chunks[2] == "id: \(sid.uuidString):3\ndata: two\n\n")
}

@Test func resumeReplaysTailAfterLastEventID() async throws {
    let hub = SSEStreamHub(bufferCapacity: 8, retentionInterval: 60)
    let (_, sid) = hub.open(replayable: true, primed: true, rejectsSendAfterCompletion: true)
    let token = hub.attach(sink: FakeSink(), streamID: sid)
    #expect(token != nil)
    hub.send(SSEMessage(data: "one"), to: sid) // sid:2
    hub.send(SSEMessage(data: "two"), to: sid) // sid:3
    hub.send(SSEMessage(data: "three"), to: sid) // sid:4

    hub.markDisconnected(streamID: sid, connectionToken: token)

    // Resume after "one" (sid:2) → replay "two", "three".
    let resumed = try hub.resume(streamID: sid, after: SSEEventID(streamID: sid, sequence: 2))
    let chunks = await collect(resumed, count: 2)
    #expect(chunks[0] == "id: \(sid.uuidString):3\ndata: two\n\n")
    #expect(chunks[1] == "id: \(sid.uuidString):4\ndata: three\n\n")
}

@Test func legacyStreamDoesNotBufferOrPrime() async {
    let hub = SSEStreamHub(bufferCapacity: 8, retentionInterval: 60)
    let (stream, sid) = hub.open(replayable: false, primed: false, rejectsSendAfterCompletion: false)
    hub.send(SSEMessage(data: "x"), to: sid)

    let chunks = await collect(stream, count: 1)
    #expect(chunks[0] == "data: x\n\n") // no id assigned

    // Nothing buffered, so resume can't find an anchor.
    #expect(throws: SSEStreamResumeError.self) {
        _ = try hub.resume(streamID: sid, after: SSEEventID(streamID: sid, sequence: 1))
    }
}

@Test func completedStreamRejectsSendWhenConfigured() {
    let hub = SSEStreamHub(bufferCapacity: 8, retentionInterval: 60)
    let (_, strict) = hub.open(replayable: true, primed: false, rejectsSendAfterCompletion: true)
    hub.finish(streamID: strict)
    #expect(hub.send(SSEMessage(data: "late"), to: strict) == false)

    // A lenient ("general") stream keeps accepting after finish.
    let (_, lenient) = hub.open(replayable: true, primed: false, rejectsSendAfterCompletion: false)
    hub.finish(streamID: lenient)
    #expect(hub.send(SSEMessage(data: "late"), to: lenient) == true)
}

@Test func resumeRejectsUnknownAndUnavailable() {
    let hub = SSEStreamHub(bufferCapacity: 8, retentionInterval: 60)
    #expect(throws: SSEStreamResumeError.unknownStream) {
        _ = try hub.resume(streamID: UUID(), after: SSEEventID(streamID: UUID(), sequence: 1))
    }

    let (_, sid) = hub.open(replayable: true, primed: true, rejectsSendAfterCompletion: true)
    // Only sid:1 (priming) is buffered; asking to resume after sid:5 is unavailable.
    #expect(throws: SSEStreamResumeError.resumePointUnavailable) {
        _ = try hub.resume(streamID: sid, after: SSEEventID(streamID: sid, sequence: 5))
    }
}

@Test func staleDisconnectTokenIsIgnored() {
    let hub = SSEStreamHub(bufferCapacity: 8, retentionInterval: 60)
    let (_, sid) = hub.open(replayable: true, primed: false, rejectsSendAfterCompletion: true)
    _ = hub.attach(sink: FakeSink(), streamID: sid)
    let fresh = hub.attach(sink: FakeSink(), streamID: sid) // reconnect mints a new token

    // A disconnect carrying a stale token must not tear down the fresh connection.
    hub.markDisconnected(streamID: sid, connectionToken: UUID())
    #expect(hub.isActive(streamID: sid) == true)
    #expect(fresh != nil)
}

@Test func removeForceClosesLiveSink() {
    let hub = SSEStreamHub(bufferCapacity: 8, retentionInterval: 60)
    let (_, sid) = hub.open(replayable: true, primed: false, rejectsSendAfterCompletion: true)
    let sink = FakeSink()
    _ = hub.attach(sink: sink, streamID: sid)

    #expect(hub.remove(streamID: sid) == true)
    #expect(sink.wasClosed == true)
    #expect(hub.info(streamID: sid) == nil)
}

@Test func closeAllSinksKeepsBuffersForResume() async throws {
    let hub = SSEStreamHub(bufferCapacity: 8, retentionInterval: 60)
    let (_, sid) = hub.open(replayable: true, primed: true, rejectsSendAfterCompletion: true)
    let sink = FakeSink()
    let token = hub.attach(sink: sink, streamID: sid)
    hub.send(SSEMessage(data: "one"), to: sid) // sid:2

    hub.closeAllSinks()
    #expect(sink.wasClosed == true)

    // closeAllSinks severs sockets but does NOT discard the stream; a host that
    // marks it disconnected can still resume its buffer.
    hub.markDisconnected(streamID: sid, connectionToken: token)
    let resumed = try hub.resume(streamID: sid, after: SSEEventID(streamID: sid, sequence: 1))
    let chunks = await collect(resumed, count: 1)
    #expect(chunks[0] == "id: \(sid.uuidString):2\ndata: one\n\n")
}

@Test(.timeLimit(.minutes(1))) func evictionDropsOldestEventsAndTheirResumeAnchors() async throws {
    let hub = SSEStreamHub(bufferCapacity: 2, retentionInterval: 60)
    let (_, sid) = hub.open(replayable: true, primed: false, rejectsSendAfterCompletion: true)
    let token = hub.attach(sink: FakeSink(), streamID: sid)
    hub.send(SSEMessage(data: "one"), to: sid) // sid:1
    hub.send(SSEMessage(data: "two"), to: sid) // sid:2
    hub.send(SSEMessage(data: "three"), to: sid) // sid:3 — evicts sid:1
    hub.send(SSEMessage(data: "four"), to: sid) // sid:4 — evicts sid:2

    hub.markDisconnected(streamID: sid, connectionToken: token)

    // The two oldest events were evicted; their ids no longer anchor a resume.
    for evicted in 1 ... 2 {
        #expect(throws: SSEStreamResumeError.resumePointUnavailable) {
            _ = try hub.resume(streamID: sid, after: SSEEventID(streamID: sid, sequence: evicted))
        }
    }

    // The oldest RETAINED event (sid:3) still anchors; only the tail follows.
    let resumed = try hub.resume(streamID: sid, after: SSEEventID(streamID: sid, sequence: 3))
    let chunks = await collect(resumed, count: 1)
    #expect(chunks == ["id: \(sid.uuidString):4\ndata: four\n\n"])
}

@Test func expiredStreamIDsReportPastRetention() {
    let hub = SSEStreamHub(bufferCapacity: 8, retentionInterval: 0)
    let (_, sid) = hub.open(replayable: true, primed: false, rejectsSendAfterCompletion: true)
    let token = hub.attach(sink: FakeSink(), streamID: sid)
    hub.markDisconnected(streamID: sid, connectionToken: token) // expiresAt = now + 0

    let expired = hub.expiredStreamIDs(now: Date().addingTimeInterval(1))
    #expect(expired.contains(sid))
}
