import Foundation
import JSONRPCWire

/// A single Server-Sent Events message: an ``SSEEvent`` plus the optional `id` and
/// `retry` envelope fields. `LosslessStringConvertible`, so it round-trips through
/// its on-the-wire text form.
///
/// Wire encoding is delegated to ``SSEEventEncoder`` (the shared `JSONRPCWire`
/// codec) so the producer side has a single source of truth.
public struct SSEMessage: LosslessStringConvertible, Sendable, Hashable {
    public let event: SSEEvent

    public var id: String?
    public var retry: Int?

    public init(event: SSEEvent, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.id = id
        self.retry = retry
    }

    /// Creates an SSE `data` message.
    /// - Parameters:
    ///   - data: The data content.
    ///   - eventName: Optional `event:` name.
    ///   - id: Optional event ID.
    ///   - retry: Optional reconnect delay in milliseconds.
    public init(data: String, eventName: String? = nil, id: String? = nil, retry: Int? = nil) {
        self.event = .field(name: "data", value: data, eventName: eventName)
        self.id = id
        self.retry = retry
    }

    /// Creates an SSE comment message.
    /// - Parameter comment: The comment text (without the leading colon).
    public init(comment: String) {
        self.event = .comment(comment)
        self.id = nil
        self.retry = nil
    }

    /// Whether this message is a replayable `data` event (comments are not
    /// buffered for resume).
    public var isReplayableDataEvent: Bool {
        switch event {
        case .comment:
            return false
        case .field(let name, _, _):
            return name == "data"
        }
    }

    /// Parses an SSE message from its text form. Expects:
    /// ```
    /// [id: value\n]
    /// [retry: value\n]
    /// [event: name\n]
    /// data: content\n\n
    /// ```
    public init?(_ description: String) {
        let lines = description.split(separator: "\n", omittingEmptySubsequences: false)
        var eventName: String?
        var dataLines: [String] = []
        var eventID: String?
        var retry: Int?

        for line in lines {
            if line.starts(with: "id:") {
                eventID = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.starts(with: "retry:") {
                retry = Int(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            } else if line.starts(with: "event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.starts(with: "data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }

        guard !dataLines.isEmpty else {
            return nil
        }

        self.event = .field(name: "data", value: dataLines.joined(separator: "\n"), eventName: eventName)
        self.id = eventID
        self.retry = retry
    }

    /// The message rendered in SSE wire format.
    public var description: String {
        let encoder = SSEEventEncoder()
        switch event {
        case .comment(let comment):
            return String(decoding: encoder.comment(comment), as: UTF8.self)
        case .field(_, let value, let eventName):
            return String(decoding: encoder.encode(data: value, event: eventName, id: id, retry: retry), as: UTF8.self)
        }
    }
}
