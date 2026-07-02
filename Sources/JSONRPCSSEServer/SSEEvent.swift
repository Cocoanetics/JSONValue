import Foundation

/// The content of a single Server-Sent Event, per the SSE ABNF: either a comment
/// line or a named field with a value.
public enum SSEEvent: Sendable, Hashable {
    /// A comment line (rendered as `: <text>`), used for keep-alive.
    case comment(String)

    /// A field with a name (`data` in practice), a value, and an optional
    /// `event:` name.
    ///
    /// - Important: Only the name `"data"` is rendered faithfully on the wire.
    ///   ``SSEMessage/description`` delegates to `SSEEventEncoder` (JSONRPCWire),
    ///   which speaks only `data:` lines — a field with any other name is still
    ///   encoded as `data: <value>`, yet ``SSEMessage/isReplayableDataEvent`` is
    ///   `false` for it, so ``SSEStreamHub`` writes it through without buffering
    ///   it for resume. Construct messages via
    ///   ``SSEMessage/init(data:eventName:id:retry:)`` (which always uses
    ///   `"data"`) unless that pass-through behavior is deliberate.
    case field(name: String, value: String, eventName: String? = nil)
}
