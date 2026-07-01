import Foundation

/// The content of a single Server-Sent Event, per the SSE ABNF: either a comment
/// line or a named field with a value.
public enum SSEEvent: Sendable, Hashable {
    /// A comment line (rendered as `: <text>`), used for keep-alive.
    case comment(String)

    /// A field with a name (`data` in practice), a value, and an optional
    /// `event:` name.
    case field(name: String, value: String, eventName: String? = nil)
}
