//
//  JSONRPCID+Convenience.swift
//  JSONFoundation
//
//  Literal conformances and accessors so ids read naturally at call sites:
//  `let id: JSONRPCID = 1` / `let id: JSONRPCID = "abc"`.
//

import Foundation

extension JSONRPCID: ExpressibleByIntegerLiteral {
    /// `let id: JSONRPCID = 1` → `.integer(1)`.
    public init(integerLiteral value: Int) {
        self = .integer(value)
    }
}

extension JSONRPCID: ExpressibleByStringLiteral {
    /// `let id: JSONRPCID = "abc"` → `.string("abc")`.
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONRPCID: CustomStringConvertible {
    /// The id as it travels on the wire — a bare number or the raw string.
    public var description: String {
        switch self {
        case .integer(let value): return String(value)
        case .string(let value): return value
        }
    }
}

public extension JSONRPCID {
    /// The integer value, or `nil` for a string id.
    var intValue: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }

    /// The string value, or `nil` for an integer id.
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
