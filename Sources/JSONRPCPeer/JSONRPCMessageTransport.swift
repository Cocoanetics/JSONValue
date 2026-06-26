import Foundation
import JSONFoundation

/// The outbound half of a transport: a place to write one ``JSONRPCMessage``. The
/// sink owns serialization and framing; a peer hands it whole messages.
///
/// Split out from ``JSONRPCMessageTransport`` so a peer can be used in **push**
/// mode — where some *other* component already owns the read loop (e.g. SwiftMCP's
/// `MCPTransport`, which reads its wire and drives dispatch itself) and only needs
/// the peer for outbound request/response correlation. Such a consumer constructs
/// `JSONRPCPeer(sink:)` and feeds inbound replies via ``JSONRPCPeer/ingest(_:)``.
public protocol JSONRPCMessageSink: Sendable {
    /// Serialize and write one message. Ordering of successive sends must be
    /// preserved (a locked write satisfies this).
    func send(_ message: JSONRPCMessage) throws
}

/// A bidirectional transport that both writes and reads whole ``JSONRPCMessage``
/// values — the **pull** model, where the peer owns the read loop.
///
/// This is the seam that makes ``JSONRPCPeer`` framing-agnostic: the peer owns only
/// JSON-RPC *semantics*; the transport owns the entire wire — framing *and* JSON
/// (de)serialization. Concrete transports are tiny:
/// - **LSP** frames as `Content-Length: <n>\r\n\r\n<json>` (`LSPFramedTransport`).
/// - **ACP / MCP-over-stdio** frame as one newline-terminated JSON line.
/// - A **loopback** transport (tests) does no framing and hands messages straight across.
public protocol JSONRPCMessageTransport: JSONRPCMessageSink {
    /// The stream of inbound messages, already de-framed and decoded. Call once.
    func makeInboundStream() -> AsyncThrowingStream<JSONRPCMessage, Error>
    /// Stop the transport and release resources.
    func close()
}

/// Errors originating in the peer itself (as opposed to a transport's own errors).
public enum JSONRPCPeerError: Error, LocalizedError {
    /// The peer (or its transport) was closed; in-flight requests fail with this.
    case closed

    public var errorDescription: String? {
        switch self {
        case .closed: return "The JSON-RPC connection is closed"
        }
    }
}
