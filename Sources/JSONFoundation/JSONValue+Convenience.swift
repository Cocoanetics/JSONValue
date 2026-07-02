//
//  JSONValue+Convenience.swift
//  JSONFoundation
//
//  Ergonomic helpers for reading and building `JSONValue` values.
//

import Foundation

public extension JSONValue {
    /// Reads a value out of a `.object(...)` by key. Returns `nil` for
    /// non-objects or missing keys.
    subscript(key: String) -> JSONValue? {
        dictionaryValue?[key]
    }

    /// Reads a value out of an `.array(...)` by index. Returns `nil` for
    /// non-arrays or out-of-bounds indices.
    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Builds an object from a Swift dictionary, converting each value via
    /// ``init(jsonObject:)``.
    init(_ value: [String: Any]) {
        self = .object(value.mapValues(JSONValue.init(jsonObject:)))
    }

    /// Builds an array from a Swift array, converting each element via
    /// ``init(jsonObject:)``.
    init(_ value: [Any]) {
        self = .array(value.map(JSONValue.init(jsonObject:)))
    }

    /// Best-effort wrap of any `Encodable` as a `JSONValue`.
    ///
    /// Unlike the throwing ``init(encoding:using:)``, this is non-throwing: a
    /// value that is already a `JSONValue` is returned as-is, otherwise it is
    /// encoded. On an encoding failure it triggers `assertionFailure` in debug
    /// builds and degrades to `.string(String(describing:))` in release —
    /// i.e. it deliberately swallows the error. Prefer `init(encoding:)` when
    /// you need to handle failure.
    init(_ value: any Encodable) {
        if let jsonValue = value as? JSONValue {
            self = jsonValue
            return
        }

        do {
            self = try JSONValue(encoding: value)
        } catch {
            assertionFailure("Failed to encode \(type(of: value)) as JSONValue: \(error)")
            self = .string(String(describing: value))
        }
    }

    /// Best-effort wrap of an optional `Encodable`; `nil` maps to `.null`.
    init(_ value: (any Encodable)?) {
        guard let value else {
            self = .null
            return
        }

        self.init(value)
    }
}

public extension [String: JSONValue] {
    /// Builds a `JSONValue` dictionary from a Swift `[String: Any]`, converting
    /// each value via ``JSONValue/init(jsonObject:)``.
    init(jsonObject value: [String: Any]) {
        self = value.mapValues(JSONValue.init(jsonObject:))
    }
}

// MARK: - Collection Conveniences

public extension [String: JSONValue] {
    /// Encodes `value` and returns the resulting top-level object; throws
    /// ``JSONValueError/expectedObject`` otherwise.
    init<T: Encodable>(encoding value: T, using encoder: JSONEncoder = JSONCoding.makeValueEncoder()) throws {
        let jsonValue = try JSONValue(encoding: value, using: encoder)
        guard case .object(let object) = jsonValue else { throw JSONValueError.expectedObject }
        self = object
    }

    /// The existential counterpart of the generic `init(encoding:using:)`, mirroring `JSONValue`'s pair.
    init(encoding value: any Encodable, using encoder: JSONEncoder = JSONCoding.makeValueEncoder()) throws {
        let jsonValue = try JSONValue(encoding: value, using: encoder)
        guard case .object(let object) = jsonValue else { throw JSONValueError.expectedObject }
        self = object
    }

    /// Decodes this object into `T` via ``JSONValue/decoded(_:using:)``.
    func decoded<T: Decodable>(
        _ type: T.Type = T.self,
        using decoder: JSONDecoder = JSONCoding.makeDecoder()
    ) throws -> T {
        try JSONValue.object(self).decoded(type, using: decoder)
    }
}

public extension [JSONValue] {
    /// Decodes this array into `T` via ``JSONValue/decoded(_:using:)``.
    func decoded<T: Decodable>(
        _ type: T.Type = T.self,
        using decoder: JSONDecoder = JSONCoding.makeDecoder()
    ) throws -> T {
        try JSONValue.array(self).decoded(type, using: decoder)
    }
}
