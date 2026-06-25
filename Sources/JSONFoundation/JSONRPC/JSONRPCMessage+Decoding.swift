//
//  JSONRPCMessage+Decoding.swift
//  JSONFoundation
//
//  Foundation-only, transport-independent decoding helpers. The protocol-version
//  batching gate (which needs a negotiated session) and any NIO `ByteBuffer`
//  overloads deliberately live in the consuming package, not here. Encoding is
//  the symmetric inverse in `JSONRPCMessage+Encoding.swift`.
//

import Foundation

extension JSONRPCMessage {
    /// Decode a single or batched JSON-RPC payload from `Data`.
    /// - Parameter data: Raw JSON data — either one message object or a top-level
    ///   array of messages (a JSON-RPC batch).
    /// - Returns: An array of `JSONRPCMessage` items (one element for a single
    ///   message).
    public static func decodeMessages(from data: Data) throws -> [JSONRPCMessage] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let batch = try? decoder.decode([JSONRPCMessage].self, from: data) {
            return batch
        } else {
            let single = try decoder.decode(JSONRPCMessage.self, from: data)
            return [single]
        }
    }

    /// Whether `data` is a top-level JSON array (a JSON-RPC batch) rather than a
    /// single message.
    ///
    /// A single message is also decoded into a one-element array by
    /// ``decodeMessages(from:)``, so inspecting the raw payload is the only
    /// reliable way to recover the wire shape afterwards.
    public static func isBatchPayload(_ data: Data) -> Bool {
        for byte in data {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:   // space, tab, LF, CR — skip leading JSON whitespace
                continue
            case UInt8(ascii: "["):
                return true
            default:
                return false
            }
        }
        return false   // empty or whitespace-only: not a batch
    }
}
