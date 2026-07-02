import Foundation

/// Raised by ``SSEStreamHub/resume(streamID:after:)`` when a stream cannot be
/// resumed. (A *malformed* `Last-Event-ID` is caught earlier, when the caller
/// parses it into an ``SSEEventID``; ownership/session checks are the host's job.)
public enum SSEStreamResumeError: Error, Sendable {
    /// No stream with that id is currently retained.
    case unknownStream
    /// The requested event is no longer in the replay buffer.
    case resumePointUnavailable
}

/// A transport-agnostic registry of Server-Sent Event streams with replay,
/// resume-after-disconnect, and retention.
///
/// The hub owns everything generic about serving SSE: each stream's outbound
/// `AsyncStream<Data>` continuation, a bounded replay buffer keyed by
/// ``SSEEventID``, the bound transport ``SSEStreamSink`` (liveness + force-close),
/// and the retention clock that keeps a disconnected stream resumable for a
/// while. It is keyed **only** by stream id and knows nothing about sessions,
/// JSON-RPC, or any higher-level grouping — a host (e.g. an MCP session manager)
/// layers that on top, using the per-stream flags on ``open(streamID:replayable:primed:rejectsSendAfterCompletion:)``
/// and the read-only ``info(streamID:)`` snapshots.
///
/// Bytes leave through the stream's continuation; the sink is used solely to test
/// liveness and to tear a connection down. The hub does not run its own GC timer —
/// a host drives cleanup by polling ``expiredStreamIDs(now:)`` and calling
/// ``remove(streamID:)``, matching a "sweep at the top of each operation" pattern.
///
/// - Important: The hub is **not** thread-safe on its own — its methods are
///   synchronous so a host can call them atomically from within *its* isolation
///   (e.g. SwiftMCP holds the hub inside its `SessionManager` actor, so a
///   compound operation that reads ``info(streamID:)`` and then mutates never
///   interleaves with another). Standalone callers must serialize access
///   themselves (hold the hub in an actor, or behind a lock).
public final class SSEStreamHub {
    struct BufferedEvent {
        let id: String
        let payload: Data
    }

    struct StreamRecord {
        let id: UUID
        var continuation: AsyncStream<Data>.Continuation?
        var sink: (any SSEStreamSink)?
        var connectionToken: UUID?
        /// When `true`, replayable data events are assigned an ``SSEEventID`` and
        /// buffered for resume; when `false` the stream is fire-and-forget.
        let replayable: Bool
        /// When `true`, a completed stream rejects further sends; when `false` it
        /// keeps accepting (a long-lived push channel that is never "finished").
        let rejectsSendAfterCompletion: Bool
        var nextSequence: Int = 1
        var buffer: [BufferedEvent] = []
        var isCompleted = false
        var lastActivityAt = Date()
        var lastConnectedAt: Date?
        var expiresAt: Date?

        var isActive: Bool {
            continuation != nil && (sink?.isLive ?? false)
        }
    }

    private let bufferCapacity: Int
    private let retentionInterval: TimeInterval
    private var streams: [UUID: StreamRecord] = [:]

    /// Creates a hub with the given replay and retention policy.
    ///
    /// - Parameters:
    ///   - bufferCapacity: The maximum number of replayable data events kept
    ///     **per stream** (counted in events, not bytes). When a stream's buffer
    ///     overflows, the oldest events are evicted first; a resume whose
    ///     `Last-Event-ID` anchor has been evicted throws
    ///     ``SSEStreamResumeError/resumePointUnavailable``.
    ///   - retentionInterval: How long (in seconds) a disconnected or finished
    ///     stream stays resumable: ``markDisconnected(streamID:connectionToken:)``
    ///     and ``finish(streamID:)`` set the stream's expiry deadline this far in
    ///     the future, while ``attach(sink:streamID:)`` and
    ///     ``resume(streamID:after:)`` clear it again — the retention clock only
    ///     runs while the stream is disconnected.
    public init(bufferCapacity: Int = 256, retentionInterval: TimeInterval = 5 * 60) {
        self.bufferCapacity = bufferCapacity
        self.retentionInterval = retentionInterval
    }

    // MARK: - Record Access

    /// Runs `body` on a value copy of the stream's record and writes the copy
    /// back, so a mutation can't be lost to a forgotten writeback. Returns `nil`
    /// (without calling `body`) when the stream is unknown.
    ///
    /// - Warning: `body` must not call back into the hub for the same stream —
    ///   the deferred writeback would clobber whatever the nested call stored.
    @discardableResult
    private func withRecord<T>(_ streamID: UUID, _ body: (inout StreamRecord) throws -> T) rethrows -> T? {
        guard var record = streams[streamID] else {
            return nil
        }
        defer { streams[streamID] = record }
        return try body(&record)
    }

    // MARK: - Lifecycle

    /// Open a fresh stream and return its outbound byte stream.
    ///
    /// - Parameters:
    ///   - streamID: The id to register under (defaults to a fresh `UUID`).
    ///   - replayable: Whether data events are buffered for resume.
    ///   - primed: Whether to emit an empty `data` event up front carrying the
    ///     first ``SSEEventID``, so a client learns the resume anchor immediately.
    ///   - rejectsSendAfterCompletion: Whether sends are refused once the stream
    ///     is finished.
    public func open(
        streamID: UUID = UUID(),
        replayable: Bool,
        primed: Bool,
        rejectsSendAfterCompletion: Bool
    ) -> (stream: AsyncStream<Data>, streamID: UUID) {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        var record = StreamRecord(
            id: streamID,
            continuation: continuation,
            sink: nil,
            connectionToken: nil,
            replayable: replayable,
            rejectsSendAfterCompletion: rejectsSendAfterCompletion
        )
        record.lastConnectedAt = Date()
        streams[streamID] = record

        if primed {
            sendPrimingEvent(to: streamID)
        }

        return (stream, streamID)
    }

    /// Resume a retained stream from a `Last-Event-ID`, replaying every buffered
    /// event after the named one onto a fresh outbound stream.
    public func resume(streamID: UUID, after lastEventID: SSEEventID) throws -> AsyncStream<Data> {
        let resumed = try withRecord(streamID) { record -> (stream: AsyncStream<Data>, isCompleted: Bool) in
            guard let replayIndex = record.buffer.firstIndex(where: { $0.id == lastEventID.description }) else {
                throw SSEStreamResumeError.resumePointUnavailable
            }

            record.continuation?.finish()

            let (stream, continuation) = AsyncStream<Data>.makeStream()
            record.continuation = continuation
            record.sink = nil
            record.connectionToken = nil
            record.expiresAt = nil
            record.lastConnectedAt = Date()
            record.lastActivityAt = Date()

            for buffered in record.buffer[(replayIndex + 1)...] {
                continuation.yield(buffered.payload)
            }

            if record.isCompleted {
                continuation.finish()
            }

            return (stream, record.isCompleted)
        }
        guard let resumed else {
            throw SSEStreamResumeError.unknownStream
        }
        // Outside withRecord: markDisconnected re-enters the hub for this stream.
        if resumed.isCompleted {
            markDisconnected(streamID: streamID, connectionToken: nil)
        }
        return resumed.stream
    }

    /// Bind a live transport connection to a stream, returning the dedup token a
    /// later disconnect must present (so a stale close can't tear down a newer
    /// reconnect). Returns `nil` if the stream is unknown.
    public func attach(sink: any SSEStreamSink, streamID: UUID) -> UUID? {
        withRecord(streamID) { record in
            let connectionToken = UUID()
            record.sink = sink
            record.connectionToken = connectionToken
            record.expiresAt = nil
            record.lastConnectedAt = Date()
            return connectionToken
        }
    }

    /// Mark a stream's current connection as gone while keeping its buffer for
    /// resume. Token-guarded: a `connectionToken` that no longer matches is a
    /// stale signal and is ignored. Returns whether it acted (so a host can skip
    /// reconciliation on a stale signal).
    @discardableResult
    public func markDisconnected(streamID: UUID, connectionToken: UUID?) -> Bool {
        let acted = withRecord(streamID) { record -> Bool in
            if let connectionToken, record.connectionToken != connectionToken {
                return false
            }
            record.continuation?.finish()
            record.continuation = nil
            record.sink = nil
            record.connectionToken = nil
            record.expiresAt = Date().addingTimeInterval(retentionInterval)
            record.lastActivityAt = Date()
            return true
        }
        return acted ?? false
    }

    /// Finish a stream after its terminal event: it is marked completed and held
    /// for the retention window (so a late resume still replays its tail).
    public func finish(streamID: UUID) {
        withRecord(streamID) { record in
            record.isCompleted = true
            record.expiresAt = Date().addingTimeInterval(retentionInterval)
            record.lastActivityAt = Date()
            record.continuation?.finish()
            record.continuation = nil
            record.sink = nil
            record.connectionToken = nil
        }
    }

    /// Drop a stream entirely: finish its continuation, force-close any live
    /// connection, and forget it. Returns whether a stream was present.
    @discardableResult
    public func remove(streamID: UUID) -> Bool {
        guard let record = streams.removeValue(forKey: streamID) else {
            return false
        }
        record.continuation?.finish()
        if let sink = record.sink, sink.isLive {
            sink.close()
        }
        return true
    }

    /// Force-close every live connection without discarding state (buffers stay
    /// intact for resume). Used on transport shutdown.
    public func closeAllSinks() {
        for record in streams.values {
            if let sink = record.sink, sink.isLive {
                sink.close()
            }
        }
    }

    // MARK: - Sending

    /// Route an SSE message to a stream. Replayable data events on a replayable
    /// stream are assigned an ``SSEEventID`` (if unset) and buffered; everything
    /// else is written straight through. Returns whether the stream accepted it.
    @discardableResult
    public func send(_ message: SSEMessage, to streamID: UUID) -> Bool {
        let accepted = withRecord(streamID) { record -> Bool in
            guard !record.isCompleted || !record.rejectsSendAfterCompletion else {
                return false
            }

            var outbound = message
            if record.replayable, outbound.isReplayableDataEvent {
                let eventID: String
                if let existing = outbound.id {
                    eventID = existing
                } else {
                    eventID = SSEEventID(streamID: streamID, sequence: record.nextSequence).description
                    record.nextSequence += 1
                    outbound.id = eventID
                }
                let payload = Data(outbound.description.utf8)
                record.buffer.append(BufferedEvent(id: eventID, payload: payload))
                if record.buffer.count > bufferCapacity {
                    record.buffer.removeFirst(record.buffer.count - bufferCapacity)
                }
                record.continuation?.yield(payload)
            } else {
                record.continuation?.yield(Data(outbound.description.utf8))
            }

            record.lastActivityAt = Date()
            return true
        }
        return accepted ?? false
    }

    /// Route an SSE comment (keep-alive) to a stream. Comments are never buffered.
    @discardableResult
    public func comment(_ text: String, to streamID: UUID) -> Bool {
        send(SSEMessage(comment: text), to: streamID)
    }

    private func sendPrimingEvent(to streamID: UUID) {
        let eventID = withRecord(streamID) { record -> SSEEventID in
            let eventID = SSEEventID(streamID: streamID, sequence: record.nextSequence)
            record.nextSequence += 1
            return eventID
        }
        guard let eventID else {
            return
        }
        // Outside withRecord: send re-enters the hub for this stream.
        _ = send(SSEMessage(data: "", id: eventID.description), to: streamID)
    }

    // MARK: - Queries

    /// Whether the stream currently has a live connection and open continuation;
    /// `false` for unknown ids.
    public func isActive(streamID: UUID) -> Bool {
        streams[streamID]?.isActive ?? false
    }

    /// A read-only status snapshot, for a host layering selection/expiry policy.
    public func info(streamID: UUID) -> SSEStreamInfo? {
        guard let record = streams[streamID] else { return nil }
        return SSEStreamInfo(
            isActive: record.isActive,
            isCompleted: record.isCompleted,
            lastConnectedAt: record.lastConnectedAt,
            lastActivityAt: record.lastActivityAt,
            expiresAt: record.expiresAt
        )
    }

    /// Stream ids that currently have a live connection and open continuation.
    public func activeStreamIDs() -> [UUID] {
        streams.values.filter(\.isActive).map(\.id)
    }

    /// Stream ids that currently have a connection bound (live or not).
    public func attachedStreamIDs() -> [UUID] {
        streams.values.filter { $0.sink != nil }.map(\.id)
    }

    /// Stream ids whose retention deadline has passed as of `now` — a host calls
    /// this to drive its cleanup sweep, then ``remove(streamID:)``s each.
    public func expiredStreamIDs(now: Date = Date()) -> [UUID] {
        streams.compactMap { id, record in
            if let expiresAt = record.expiresAt, expiresAt <= now { return id }
            return nil
        }
    }
}
