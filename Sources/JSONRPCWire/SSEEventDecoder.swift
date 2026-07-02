import Foundation

/// Incremental decoder for the `text/event-stream` (SSE) wire format, yielding the
/// `data` payload of each dispatched event — which, for JSON-RPC over SSE, is one
/// JSON message.
///
/// This is the inbound counterpart of the stdio `MessageFraming`, but SSE is
/// *asymmetric*: the client sends plain JSON in a POST body and receives SSE, so
/// there is no `frame` half here — only decode. Per the SSE spec: lines are
/// `field: value`, `:`-prefixed lines are comments, a blank line dispatches the
/// event, and multiple `data:` lines join with `\n`. Only `data` is surfaced;
/// `event` / `id` / `retry` are accepted and ignored (resumability is a separate
/// concern that lives in the transport).
public struct SSEEventDecoder: Sendable {
    private var buffer = Data()
    private var dataLines: [String] = []

    public init() {}

    /// Feed newly-read bytes; return the `data` payload of every event that now
    /// completes (each a JSON-RPC message body).
    public mutating func push(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var events: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = Data(buffer[buffer.startIndex ..< newlineIndex])
            buffer.removeSubrange(buffer.startIndex ... newlineIndex)
            var line = String(data: lineData, encoding: .utf8) ?? ""
            if line.hasSuffix("\r") { line.removeLast() } // tolerate CRLF

            if line.isEmpty {
                // Blank line: dispatch the buffered event.
                if !dataLines.isEmpty {
                    events.append(Data(dataLines.joined(separator: "\n").utf8))
                    dataLines.removeAll()
                }
            } else if line.hasPrefix(":") {
                continue // comment
            } else {
                let (field, value) = Self.splitField(line)
                if field == "data" { dataLines.append(value) }
            }
        }
        return events
    }

    /// Split `field: value`, stripping a single optional space after the colon. A
    /// line with no colon is a field name with an empty value.
    private static func splitField(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[line.startIndex ..< colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (field, value)
    }
}
