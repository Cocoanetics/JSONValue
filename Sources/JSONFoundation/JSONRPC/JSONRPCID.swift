//
//  JSONRPCID.swift
//  JSONFoundation
//
//  The request/response correlation id — an integer or a string — decoded from
//  and encoded to either wire form. Literal conformances and log/debug
//  renderings live in `JSONRPCID+Convenience.swift`.
//

import Foundation

/// Represents the identifier for a JSON-RPC message which may be an integer or a string.
///
/// The numeric case is named `integer` (not `int`/`number`) to match how
/// `JSONValue` models whole numbers: a JSON-RPC id is always integer-valued
/// (the spec forbids fractional ids), so it is stored exactly as an `Int`.
public enum JSONRPCID: Codable, Sendable, Hashable {
    case integer(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .integer(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCID.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected Int or String for JSON-RPC id"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}
