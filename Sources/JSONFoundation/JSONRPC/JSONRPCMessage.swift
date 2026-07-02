//
//  JSONRPCMessage.swift
//  JSONFoundation
//
//  Created by Oliver Drobnik on 18.03.25.
//
//  The message enum itself: case declarations, the per-case data structs, and
//  the convenience factories. The wire codec lives in
//  `JSONRPCMessage+Decoding.swift` / `JSONRPCMessage+Encoding.swift`, and the
//  ergonomic case/field accessors in `JSONRPCMessage+Accessors.swift`.
//

/**
 Enum representing all possible JSON-RPC message types.
 This unifies all JSON-RPC message handling and makes it easier to work with collections
 of mixed message types while still being able to distinguish them in processing loops.

 Spec-mandated behavior follows the JSON-RPC 2.0 specification:
 https://www.jsonrpc.org/specification
 */
public enum JSONRPCMessage: Codable, Sendable, Hashable {
    case request(JSONRPCRequestData)
    case notification(JSONRPCNotificationData)
    case response(JSONRPCResponseData)
    case errorResponse(JSONRPCErrorResponseData)

    // MARK: - Data Structures

    /// Data structure for JSON-RPC requests (with ID, expecting response)
    public struct JSONRPCRequestData: Codable, Sendable, Hashable {
        /// The JSON-RPC protocol version, always "2.0"
        public var jsonrpc: String = "2.0"

        /// The unique identifier for the request (non-optional for requests expecting responses)
        public var id: JSONRPCID

        /// The name of the method to be invoked
        public var method: String

        /// The parameters passed to the method — any JSON value. Typically an
        /// object (named params); the JSON-RPC 2.0 spec also permits an array
        /// (positional params).
        public var params: JSONValue?

        /// Public initializer
        public init(jsonrpc: String = "2.0", id: JSONRPCID, method: String, params: JSONValue? = nil) {
            self.jsonrpc = jsonrpc
            self.id = id
            self.method = method
            self.params = params
        }
    }

    /// Data structure for JSON-RPC notifications (no ID, no response expected)
    public struct JSONRPCNotificationData: Codable, Sendable, Hashable {
        /// The JSON-RPC protocol version, always "2.0"
        public var jsonrpc: String = "2.0"

        /// The name of the method to be invoked
        public var method: String

        /// The parameters passed to the method — any JSON value. Typically an
        /// object (named params); the JSON-RPC 2.0 spec also permits an array
        /// (positional params).
        public var params: JSONValue?

        /// Public initializer
        public init(jsonrpc: String = "2.0", method: String, params: JSONValue? = nil) {
            self.jsonrpc = jsonrpc
            self.method = method
            self.params = params
        }
    }

    /// Data structure for JSON-RPC success responses
    public struct JSONRPCResponseData: Codable, Sendable, Hashable {
        /// The JSON-RPC protocol version, always "2.0"
        public var jsonrpc: String = "2.0"

        /// The unique identifier matching the request ID (non-optional for responses)
        public var id: JSONRPCID

        /// The result of the method invocation — any JSON value (object, array,
        /// primitive, or null). Required on success per the JSON-RPC 2.0 spec.
        public var result: JSONValue?

        /// Public initializer
        public init(jsonrpc: String = "2.0", id: JSONRPCID, result: JSONValue? = nil) {
            self.jsonrpc = jsonrpc
            self.id = id
            self.result = result
        }
    }

    /// Data structure for JSON-RPC error responses
    public struct JSONRPCErrorResponseData: Codable, Sendable, Hashable {
        // swiftlint:disable nesting
        /// Represents the error payload containing error details.
        /// Includes an error code and a descriptive message. Conforms to `Error`
        /// so it can be thrown directly; see the `JSONRPCError` typealias and its
        /// factories/`LocalizedError` conformance.
        public struct ErrorPayload: Codable, Sendable, Hashable, Error {
            /// The numeric error code indicating the type of error
            public var code: Int

            /// A human-readable error message describing what went wrong
            public var message: String

            /// Optional structured data with additional error details. Per the
            /// JSON-RPC 2.0 spec this may be any primitive or structured value,
            /// hence `JSONValue?` rather than an object-only type.
            public var data: JSONValue?

            public init(code: Int, message: String, data: JSONValue? = nil) {
                self.code = code
                self.message = message
                self.data = data
            }
        }
        // swiftlint:enable nesting

        /// The JSON-RPC protocol version, always "2.0"
        public var jsonrpc: String = "2.0"

        /// The unique identifier matching the request ID
        public var id: JSONRPCID?

        /// The error details containing the error code and message
        public var error: ErrorPayload

        public init(jsonrpc: String = "2.0", id: JSONRPCID?, error: ErrorPayload) {
            self.jsonrpc = jsonrpc
            self.id = id
            self.error = error
        }
    }

    // MARK: - Coding Keys

    /// Coding keys for the wire codec, shared by the `Decodable` implementation
    /// in `JSONRPCMessage+Decoding.swift` and the `Encodable` implementation in
    /// `JSONRPCMessage+Encoding.swift`.
    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    // MARK: - Convenience Initializers

    public static func request(
        jsonrpc: String = "2.0",
        id: JSONRPCID,
        method: String,
        params: JSONValue? = nil
    ) -> JSONRPCMessage {
        return .request(JSONRPCRequestData(jsonrpc: jsonrpc, id: id, method: method, params: params))
    }

    public static func request(
        jsonrpc: String = "2.0",
        id: Int,
        method: String,
        params: JSONValue? = nil
    ) -> JSONRPCMessage {
        request(jsonrpc: jsonrpc, id: .integer(id), method: method, params: params)
    }

    public static func request(
        jsonrpc: String = "2.0",
        id: String,
        method: String,
        params: JSONValue? = nil
    ) -> JSONRPCMessage {
        request(jsonrpc: jsonrpc, id: .string(id), method: method, params: params)
    }

    public static func response(
        jsonrpc: String = "2.0",
        id: JSONRPCID,
        result: JSONValue? = nil
    ) -> JSONRPCMessage {
        return .response(JSONRPCResponseData(jsonrpc: jsonrpc, id: id, result: result))
    }

    public static func response(
        jsonrpc: String = "2.0",
        id: Int,
        result: JSONValue? = nil
    ) -> JSONRPCMessage {
        response(jsonrpc: jsonrpc, id: .integer(id), result: result)
    }

    public static func response(
        jsonrpc: String = "2.0",
        id: String,
        result: JSONValue? = nil
    ) -> JSONRPCMessage {
        response(jsonrpc: jsonrpc, id: .string(id), result: result)
    }

    public static func errorResponse(
        jsonrpc: String = "2.0",
        id: JSONRPCID?,
        error: JSONRPCErrorResponseData.ErrorPayload
    ) -> JSONRPCMessage {
        return .errorResponse(JSONRPCErrorResponseData(jsonrpc: jsonrpc, id: id, error: error))
    }

    public static func notification(
        jsonrpc: String = "2.0",
        method: String,
        params: JSONValue? = nil
    ) -> JSONRPCMessage {
        return .notification(JSONRPCNotificationData(jsonrpc: jsonrpc, method: method, params: params))
    }
}
