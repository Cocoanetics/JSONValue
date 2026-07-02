import Foundation

/// Matches an asynchronous caller to the reply of the request it sent, keyed by
/// any `Hashable` id — the channel-agnostic half of "act as a JSON-RPC caller."
///
/// Unlike ``JSONRPCPeer``, the correlator owns **no** transport and performs **no**
/// send: the caller writes the request itself (over whatever channel, on whatever
/// id scheme) and uses the correlator only to park the waiter and resolve it when
/// the reply arrives — or to fail it on teardown. That makes it usable where the
/// peer's single-channel, integer-id, fatal-stream-end model does not fit: e.g. a
/// server that issues sampling/elicitation requests from an actor and may route
/// each over a different stream, yet still needs one place to match replies to ids.
///
/// - Important: It is **not** thread-safe on its own — methods are synchronous so a
///   host can call them atomically from within *its* isolation (hold it inside an
///   actor and call it directly, the way SwiftMCP's `Session` actor does). Register
///   the waiter *before* sending, so a fast reply can never arrive before the id is
///   parked.
public final class RequestCorrelator<Key: Hashable & Sendable, Reply: Sendable> {
    private var pending: [Key: CheckedContinuation<Reply, Error>] = [:]

    public init() {}

    /// Park a waiter under `id`. Call from inside the `withCheckedThrowingContinuation`
    /// body, before performing the send.
    public func register(_ id: Key, _ continuation: CheckedContinuation<Reply, Error>) {
        pending[id] = continuation
    }

    /// Resolve the waiter for `id` with its reply. Returns whether one was waiting
    /// (a late or duplicate reply for an already-resolved id is a no-op).
    @discardableResult
    public func resolve(_ id: Key, with reply: Reply) -> Bool {
        guard let continuation = pending.removeValue(forKey: id) else { return false }
        continuation.resume(returning: reply)
        return true
    }

    /// Fail the waiter for `id`. Returns whether one was waiting — so a send-error
    /// path can fail the pending request without racing a reply that already
    /// resolved it.
    @discardableResult
    public func fail(_ id: Key, with error: Error) -> Bool {
        guard let continuation = pending.removeValue(forKey: id) else { return false }
        continuation.resume(throwing: error)
        return true
    }

    /// Whether a waiter is currently parked under `id`.
    public func isPending(_ id: Key) -> Bool {
        pending[id] != nil
    }

    /// The number of parked waiters.
    public var count: Int { pending.count }

    /// Fail every parked waiter (connection teardown) with `error`, clearing the
    /// table. The default `CancellationError` matches "the call was abandoned."
    public func failAll(with error: Error = CancellationError()) {
        let waiters = pending
        pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: error)
        }
    }
}
