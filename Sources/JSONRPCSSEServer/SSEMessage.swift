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
    ///
    /// Also `false` for a ``SSEEvent/field(name:value:eventName:)`` whose name is
    /// not `"data"`: such a message still *renders* as a `data:` event (see the
    /// note on that case), but it never enters ``SSEStreamHub``'s replay buffer.
    public var isReplayableDataEvent: Bool {
        switch event {
        case .comment:
            return false
        case .field(let name, _, _):
            return name == "data"
        }
    }

    /// Parses an SSE message from its text form. Expects either a data event:
    /// ```
    /// [id: value\n]
    /// [retry: value\n]
    /// [event: name\n]
    /// data: content\n\n
    /// ```
    /// or a comment message:
    /// ```
    /// : comment\n
    /// ```
    public init?(_ description: String) {
        let lines = description.split(separator: "\n", omittingEmptySubsequences: false)
        var eventName: String?
        var dataLines: [String] = []
        var eventID: String?
        var retry: Int?
        var comment: String?

        for line in lines {
            if line.starts(with: "id:") {
                eventID = Self.fieldValue(line, colonPrefix: 3)
            } else if line.starts(with: "retry:") {
                retry = Int(Self.fieldValue(line, colonPrefix: 6))
            } else if line.starts(with: "event:") {
                eventName = Self.fieldValue(line, colonPrefix: 6)
            } else if line.starts(with: "data:") {
                dataLines.append(Self.fieldValue(line, colonPrefix: 5))
            } else if line.starts(with: ":"), comment == nil {
                comment = Self.fieldValue(line, colonPrefix: 1)
            }
        }

        guard !dataLines.isEmpty else {
            // No data lines: the message can still be a lone comment, which
            // carries no id/retry envelope — mirroring ``init(comment:)``.
            guard let comment else {
                return nil
            }
            self.event = .comment(comment)
            self.id = nil
            self.retry = nil
            return
        }

        self.event = .field(name: "data", value: dataLines.joined(separator: "\n"), eventName: eventName)
        self.id = eventID
        self.retry = retry
    }

    /// The value of an SSE `field: value` line: everything after the colon with a
    /// **single** optional leading space removed, per the SSE spec — not trimmed,
    /// so a payload's intentional surrounding whitespace (e.g. `" x "`) survives the
    /// `description` → `init?` round trip.
    private static func fieldValue(_ line: Substring, colonPrefix: Int) -> String {
        var value = String(line.dropFirst(colonPrefix))
        if value.hasPrefix(" ") { value.removeFirst() }
        return value
    }

    /// The message rendered in SSE wire format.
    public var description: String {
        let encoder = SSEEventEncoder()
        switch event {
        case .comment(let comment):
            return String(data: encoder.comment(comment), encoding: .utf8) ?? ""
        case .field(_, let value, let eventName):
            let bytes = encoder.encode(data: value, event: eventName, id: id, retry: retry)
            return String(data: bytes, encoding: .utf8) ?? ""
        }
    }
}
