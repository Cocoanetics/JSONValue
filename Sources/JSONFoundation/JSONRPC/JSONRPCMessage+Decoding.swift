//
//  JSONRPCMessage+Decoding.swift
//  JSONFoundation
//
//  Foundation-only, transport-independent decoding helpers. The protocol-version
//  batching gate (which needs a negotiated session) and any NIO `ByteBuffer`
//  overloads deliberately live in the consuming package, not here.
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

/// Ergonomic top-level name for the JSON-RPC error payload (`code` / `message` /
/// `data`), which is otherwise nested under the error-response data structure.
public typealias JSONRPCError = JSONRPCMessage.JSONRPCErrorResponseData.ErrorPayload

extension JSONRPCError {
    /// `-32700` — invalid JSON was received.
    public static func parseError(_ message: String = "Parse error") -> JSONRPCError {
        .init(code: -32700, message: message)
    }

    /// `-32600` — the payload was not a valid JSON-RPC request.
    public static func invalidRequest(_ message: String = "Invalid request") -> JSONRPCError {
        .init(code: -32600, message: message)
    }

    /// `-32601` — the requested method does not exist.
    public static func methodNotFound(_ method: String) -> JSONRPCError {
        .init(code: -32601, message: "Method not found: \(method)")
    }

    /// `-32602` — the method's parameters were invalid.
    public static func invalidParams(_ message: String) -> JSONRPCError {
        .init(code: -32602, message: "Invalid params: \(message)")
    }

    /// `-32603` — an internal JSON-RPC error.
    public static func internalError(_ message: String) -> JSONRPCError {
        .init(code: -32603, message: message)
    }
}

extension JSONRPCError: LocalizedError {
    public var errorDescription: String? {
        // Surface any structured `data` (e.g. `{"errorKind":"rate_limit"}`) so
        // detail attached there reaches callers — including MCP clients, which
        // present `error.localizedDescription` as the tool-result text.
        guard let data, data != .null,
            let encoded = try? JSONEncoder().encode(data),
            let json = String(bytes: encoded, encoding: .utf8)
        else {
            return "JSON-RPC error \(code): \(message)"
        }
        return "JSON-RPC error \(code): \(message) — \(json)"
    }
}
