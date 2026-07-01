import Foundation

/// The identifier carried on a replayable SSE event, encoding the stream it
/// belongs to so a resuming client's `Last-Event-ID` self-routes back to the
/// right buffer without a side lookup.
///
/// Wire form is `<stream-uuid>:<sequence>` where `sequence >= 1`. Parsing splits
/// on the **last** colon, so the UUID's own representation is unambiguous.
public struct SSEEventID: LosslessStringConvertible, Sendable, Hashable {
    public let streamID: UUID
    public let sequence: Int

    public init(streamID: UUID, sequence: Int) {
        self.streamID = streamID
        self.sequence = sequence
    }

    /// Parses `<stream-uuid>:<sequence>` (sequence must be `>= 1`); returns `nil`
    /// on any malformed input.
    public init?(_ description: String) {
        guard let separator = description.lastIndex(of: ":") else { return nil }
        let streamPart = String(description[..<separator])
        let sequencePart = String(description[description.index(after: separator)...])
        guard let streamID = UUID(uuidString: streamPart),
              let sequence = Int(sequencePart),
              sequence >= 1 else {
            return nil
        }
        self.streamID = streamID
        self.sequence = sequence
    }

    public var description: String {
        "\(streamID.uuidString):\(sequence)"
    }
}
