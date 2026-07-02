//
//  JSONRPCID+Convenience.swift
//  JSONFoundation
//
//  Literal conformances and accessors so ids read naturally at call sites
//  (`let id: JSONRPCID = 1` / `let id: JSONRPCID = "abc"`), plus the log and
//  debug renderings.
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
    /// A compact form for log summaries — the bare number or the unquoted
    /// string. `.integer(1)` and `.string("1")` both render as `1`; use
    /// ``debugDescription`` when that distinction matters.
    public var description: String {
        switch self {
        case .integer(let value): return String(value)
        case .string(let value): return value
        }
    }
}

extension JSONRPCID: CustomDebugStringConvertible {
    /// The id in its wire form, disambiguating the cases that ``description``
    /// conflates: an integer id stays bare (`.integer(1)` → `1`) while a
    /// string id is quoted (`.string("1")` → `"1"`).
    public var debugDescription: String {
        switch self {
        case .integer(let value): return String(value)
        case .string(let value): return "\"\(value)\""
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
