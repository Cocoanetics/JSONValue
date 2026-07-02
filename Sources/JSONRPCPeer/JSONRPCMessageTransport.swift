import Foundation
import JSONFoundation

/// The outbound half of a transport: a place to write one ``JSONRPCMessage``. The
/// sink owns serialization and framing; a peer hands it whole messages.
///
/// Split out from ``JSONRPCMessageTransport`` so a peer can be used in **push**
/// mode — where some *other* component already owns the read loop and only needs
/// the peer for outbound request/response correlation. Such a consumer constructs
/// `JSONRPCPeer(sink:)` and feeds inbound replies via ``JSONRPCPeer/ingest(_:)``.
public protocol JSONRPCMessageSink: Sendable {
    /// Serialize and write one message. Ordering of successive sends must be
    /// preserved (a locked write satisfies this). Implementations throw
    /// ``JSONRPCPeerError/closed`` for a send after the transport was closed.
    func send(_ message: JSONRPCMessage) throws
}

/// A bidirectional transport that both writes and reads whole ``JSONRPCMessage``
/// values — the **pull** model, where the peer owns the read loop.
///
/// This is the seam that makes ``JSONRPCPeer`` framing-agnostic: the peer owns only
/// JSON-RPC *semantics*; the transport owns the entire wire — framing *and* JSON
/// (de)serialization. Concrete transports are tiny:
/// - **LSP** frames as `Content-Length: <n>\r\n\r\n<json>` (`ContentLengthFraming`).
/// - **ACP / MCP-over-stdio** frame as one newline-terminated JSON line (`LineFraming`).
/// - ``LoopbackTransport`` does no framing and hands messages straight across.
public protocol JSONRPCMessageTransport: JSONRPCMessageSink {
    /// The stream of inbound messages, already de-framed and decoded. Call once.
    /// The stream finishes when the wire reaches EOF or the transport is closed.
    func makeInboundStream() -> AsyncThrowingStream<JSONRPCMessage, Error>
    /// Stop the transport and release resources. Idempotent; a later ``send(_:)``
    /// throws ``JSONRPCPeerError/closed``.
    func close()
}

/// Errors shared by the peer and its transports.
public enum JSONRPCPeerError: Error, LocalizedError {
    /// The peer or transport was closed. In-flight requests fail with this, and
    /// transports throw it from `send(_:)` after `close()`.
    case closed

    public var errorDescription: String? {
        switch self {
        case .closed: return "The JSON-RPC connection is closed"
        }
    }
}
