//
//  JSONRPCMessage+Accessors.swift
//  JSONFoundation
//
//  Ergonomic, transport-independent accessors over the four message cases:
//  classify a message by shape and pull out its common fields without switching.
//

import Foundation

public extension JSONRPCMessage {
    // MARK: - Shape

    /// `true` for a `request` — a method call carrying an `id`, expecting a reply.
    var isRequest: Bool {
        if case .request = self { return true }
        return false
    }

    /// `true` for a `notification` — a method call with no `id`, expecting no reply.
    var isNotification: Bool {
        if case .notification = self { return true }
        return false
    }

    /// `true` for a successful `response`.
    var isResponse: Bool {
        if case .response = self { return true }
        return false
    }

    /// `true` for an `errorResponse`.
    var isErrorResponse: Bool {
        if case .errorResponse = self { return true }
        return false
    }

    /// `true` for either kind of reply — a `response` or an `errorResponse`.
    ///
    /// This is the classification a correlator uses: a reply is matched back to a
    /// pending request by ``id``, whereas a `request`/`notification` is dispatched.
    var isReply: Bool {
        isResponse || isErrorResponse
    }

    // MARK: - Common fields

    /// The JSON-RPC protocol version, typically "2.0" — present on every case.
    var jsonrpc: String {
        switch self {
        case .request(let data): return data.jsonrpc
        case .response(let data): return data.jsonrpc
        case .errorResponse(let data): return data.jsonrpc
        case .notification(let data): return data.jsonrpc
        }
    }

    /// The unique identifier used to correlate requests and replies — `nil` for
    /// a `notification` (and for an `errorResponse` whose request id could not
    /// be determined).
    var id: JSONRPCID? {
        switch self {
        case .request(let data): return data.id
        case .response(let data): return data.id
        case .errorResponse(let data): return data.id
        case .notification: return nil
        }
    }

    /// The invoked method name — for a `request` or `notification`; `nil` for a
    /// reply.
    var method: String? {
        switch self {
        case .request(let data): return data.method
        case .notification(let data): return data.method
        case .response, .errorResponse: return nil
        }
    }

    /// The call parameters — for a `request` or `notification`; `nil` otherwise.
    var params: JSONValue? {
        switch self {
        case .request(let data): return data.params
        case .notification(let data): return data.params
        case .response, .errorResponse: return nil
        }
    }

    /// The success result — for a `response`; `nil` otherwise.
    var result: JSONValue? {
        switch self {
        case .response(let data): return data.result
        case .request, .notification, .errorResponse: return nil
        }
    }

    /// The error payload — for an `errorResponse`; `nil` otherwise.
    var error: JSONRPCError? {
        switch self {
        case .errorResponse(let data): return data.error
        case .request, .notification, .response: return nil
        }
    }

    // MARK: - Reply outcome

    /// A reply collapsed into a `Result` for correlation: `.success` carries the
    /// (optional) result object, `.failure` the error payload. `nil` for a
    /// `request` or `notification`, which are not replies.
    ///
    /// This is the shape a request/response correlator wants — resume a pending
    /// continuation with `.success`'s value, or throw `.failure`'s error.
    var replyOutcome: Result<JSONValue?, JSONRPCError>? {
        switch self {
        case .response(let data): return .success(data.result)
        case .errorResponse(let data): return .failure(data.error)
        case .request, .notification: return nil
        }
    }

    // MARK: - Validation

    /// Whether the `jsonrpc` field is exactly `"2.0"` — the only version this
    /// model represents.
    var isVersion2: Bool {
        jsonrpc == "2.0"
    }

    /// Validates JSON-RPC 2.0 well-formedness beyond what decoding guarantees: the
    /// `jsonrpc` field must be `"2.0"`, and a `request`/`notification` must carry a
    /// non-empty method name.
    ///
    /// - Throws: ``JSONRPCError/invalidRequest(_:)`` describing the first violation.
    func validate() throws {
        guard isVersion2 else {
            throw JSONRPCError.invalidRequest(#"Unsupported jsonrpc version "\#(jsonrpc)"; expected "2.0"."#)
        }
        if let method, method.isEmpty {
            throw JSONRPCError.invalidRequest("Empty method name.")
        }
    }
}

extension JSONRPCMessage: CustomStringConvertible {
    /// A compact, human-readable summary for logs — *not* the wire form (use
    /// ``encodedString()`` for that).
    public var description: String {
        switch self {
        case .request(let data):
            return "request(id: \(data.id), method: \(data.method))"
        case .notification(let data):
            return "notification(method: \(data.method))"
        case .response(let data):
            return "response(id: \(data.id))"
        case .errorResponse(let data):
            let identifier = data.id.map { "\($0)" } ?? "nil"
            return "error(id: \(identifier), code: \(data.error.code))"
        }
    }
}
