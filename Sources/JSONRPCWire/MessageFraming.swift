import Foundation

/// How JSON-RPC message bodies are delimited on a byte stream.
///
/// This is the *one* axis on which LSP, ACP, and MCP-over-stdio actually differ:
/// LSP uses HTTP-style `Content-Length` headers; ACP and MCP use one
/// newline-terminated JSON line. Everything else about a stdio transport is
/// identical, so making framing pluggable is what lets a single
/// `StdioTransport` serve all three.
///
/// `frame(_:)` is pure (body → bytes-on-wire). Decoding is stateful — bytes arrive
/// without respecting message boundaries — so a transport keeps its own *value
/// copy* of the framing and feeds it via `push(_:)`; the copy carries the buffer.
public protocol MessageFraming: Sendable {
    /// Wrap one message body for the wire (prepend a header / append a terminator).
    func frame(_ body: Data) -> Data
    /// Feed newly-read bytes; return every complete message body they now yield
    /// (header/terminator stripped), buffering any partial remainder.
    mutating func push(_ bytes: Data) -> [Data]
}

/// LSP base-protocol framing: `Content-Length: <n>\r\n\r\n<n bytes of JSON>`.
///
/// Lenient on receipt: only `Content-Length` is required, other headers are
/// ignored, and the body length is counted in bytes (frames may split mid-UTF-8).
public struct ContentLengthFraming: MessageFraming {
    private var buffer = Data()
    private var expectedLength: Int?

    public init() {}

    public func frame(_ body: Data) -> Data {
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }

    public mutating func push(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var messages: [Data] = []
        while let message = next() { messages.append(message) }
        return messages
    }

    private mutating func next() -> Data? {
        if let length = expectedLength {
            guard buffer.count >= length else { return nil }
            let body = Data(buffer.prefix(length))
            buffer.removeFirst(length)
            expectedLength = nil
            return body
        }
        guard let separator = buffer.range(of: Self.headerSeparator) else { return nil }
        let headerBytes = buffer[buffer.startIndex ..< separator.lowerBound]
        let length = Self.contentLength(in: headerBytes)
        buffer.removeSubrange(buffer.startIndex ..< separator.upperBound)
        guard let length else { return next() }
        expectedLength = length
        return next()
    }

    private static let headerSeparator = Data("\r\n\r\n".utf8)

    private static func contentLength(in header: some DataProtocol) -> Int? {
        guard let text = String(bytes: header, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                      .caseInsensitiveCompare("Content-Length") == .orderedSame
            else { continue }
            // Reject a non-numeric or negative length — a bad header must never
            // become a frame size (`buffer.prefix(negative)` would trap).
            guard let length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  length >= 0 else { return nil }
            return length
        }
        return nil
    }
}

/// Newline-delimited JSON framing (ACP and MCP-over-stdio): `<json>\n`.
public struct LineFraming: MessageFraming {
    private var buffer = Data()

    public init() {}

    public func frame(_ body: Data) -> Data {
        var out = body
        out.append(0x0A) // newline terminator
        return out
    }

    public mutating func push(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var messages: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            if !line.isEmpty { messages.append(Data(line)) }
        }
        return messages
    }
}
