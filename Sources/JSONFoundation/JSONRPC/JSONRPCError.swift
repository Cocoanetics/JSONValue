//
//  JSONRPCError.swift
//  JSONFoundation
//
//  The JSON-RPC 2.0 error payload as a throwable `Error`, plus factories for the
//  spec's reserved error codes and helpers to classify a code.
//

import Foundation

/// Ergonomic top-level name for the JSON-RPC error payload (`code` / `message` /
/// `data`), which is otherwise nested under the error-response data structure.
///
/// Conforms to `Error` (and `LocalizedError`), so it can be thrown directly and
/// wrapped into an `errorResponse` via
/// ``JSONRPCMessage/errorResponse(jsonrpc:id:error:)``.
public typealias JSONRPCError = JSONRPCMessage.JSONRPCErrorResponseData.ErrorPayload

public extension JSONRPCError {

    // MARK: - Reserved spec codes

    /// `-32700` — invalid JSON was received.
    static func parseError(_ message: String = "Parse error") -> JSONRPCError {
        .init(code: -32700, message: message)
    }

    /// `-32600` — the payload was not a valid JSON-RPC request.
    static func invalidRequest(_ message: String = "Invalid request") -> JSONRPCError {
        .init(code: -32600, message: message)
    }

    /// `-32601` — the requested method does not exist.
    static func methodNotFound(_ method: String) -> JSONRPCError {
        .init(code: -32601, message: "Method not found: \(method)")
    }

    /// `-32602` — the method's parameters were invalid.
    static func invalidParams(_ message: String) -> JSONRPCError {
        .init(code: -32602, message: "Invalid params: \(message)")
    }

    /// `-32603` — an internal JSON-RPC error.
    static func internalError(_ message: String) -> JSONRPCError {
        .init(code: -32603, message: message)
    }

    // MARK: - Implementation-defined server errors

    /// An implementation-defined server error. The JSON-RPC 2.0 spec reserves
    /// `-32000…-32099` for these; `code` is expected to fall in that range.
    static func serverError(code: Int, message: String, data: JSONValue? = nil) -> JSONRPCError {
        .init(code: code, message: message, data: data)
    }

    // MARK: - Classification

    /// Whether `code` lies in the spec's reserved range (`-32768…-32000`), which
    /// covers the pre-defined errors above and the server-error band.
    var isReservedCode: Bool {
        (-32768 ... -32000).contains(code)
    }

    /// Whether `code` lies in the implementation-defined server-error band
    /// (`-32000…-32099`).
    var isServerError: Bool {
        (-32099 ... -32000).contains(code)
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
