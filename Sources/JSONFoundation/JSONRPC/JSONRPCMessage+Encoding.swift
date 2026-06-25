//
//  JSONRPCMessage+Encoding.swift
//  JSONFoundation
//
//  Transport-independent encoding — the symmetric inverse of
//  `decodeMessages(from:)`. Newline framing and any `ByteBuffer` overloads stay
//  in the consuming transport.
//

import Foundation

public extension JSONRPCMessage {
    /// A `JSONEncoder` configured to round-trip with ``decodeMessages(from:)``:
    /// ISO-8601 dates, sorted keys for deterministic output, and unescaped slashes
    /// so URLs in params/results stay readable on the wire.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Encodes this single message as a JSON object.
    func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Encodes this single message as a UTF-8 JSON object string (no trailing
    /// newline — a line-delimited transport appends its own terminator).
    func encodedString() throws -> String {
        // JSON is always valid UTF-8, so this conversion never actually fails.
        String(bytes: try encoded(), encoding: .utf8) ?? ""
    }

    /// Encodes a batch as a top-level JSON array — the inverse of
    /// ``decodeMessages(from:)`` on an array payload.
    ///
    /// This always produces an array, even for a single element (a one-element
    /// JSON-RPC batch is distinct from a bare object on the wire). To send one
    /// message as an object, use ``encoded()`` instead.
    static func encodeBatch(_ messages: [JSONRPCMessage]) throws -> Data {
        try makeEncoder().encode(messages)
    }
}
