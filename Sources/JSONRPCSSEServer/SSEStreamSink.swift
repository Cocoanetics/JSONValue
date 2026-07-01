import Foundation

/// The transport connection bound to an open SSE stream, as the ``SSEStreamHub``
/// sees it. A transport adapter (NIO, Network.framework, an in-memory test rig…)
/// supplies a value of this type when it attaches a live connection to a stream;
/// the hub uses it only to test liveness and to force a close — it never writes
/// bytes through it (data flows out the stream's `AsyncStream` continuation).
public protocol SSEStreamSink: Sendable {
    /// Whether the underlying connection is still open.
    var isLive: Bool { get }

    /// Force the connection closed (transport teardown). The stream's replay
    /// buffer is unaffected — this severs the socket, it does not finish the
    /// logical stream.
    func close()
}

/// An immutable snapshot of a stream's status, for a host that layers its own
/// selection/expiry policy on top of the hub (e.g. choosing a session's primary
/// stream, or reconciling session expiry).
public struct SSEStreamInfo: Sendable, Hashable {
    /// `true` when the stream has a live connection and an open continuation.
    public let isActive: Bool
    /// `true` once the stream has emitted its terminal event and been finished.
    public let isCompleted: Bool
    /// When a connection was most recently attached, if ever.
    public let lastConnectedAt: Date?
    /// When the stream last saw outbound activity.
    public let lastActivityAt: Date
    /// The retention deadline after a disconnect/finish, if one is pending.
    public let expiresAt: Date?

    public init(
        isActive: Bool,
        isCompleted: Bool,
        lastConnectedAt: Date?,
        lastActivityAt: Date,
        expiresAt: Date?
    ) {
        self.isActive = isActive
        self.isCompleted = isCompleted
        self.lastConnectedAt = lastConnectedAt
        self.lastActivityAt = lastActivityAt
        self.expiresAt = expiresAt
    }
}
