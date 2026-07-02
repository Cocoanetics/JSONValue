import Foundation

/// A JSON object: string keys mapping to ``JSONValue``s.
public typealias JSONDictionary = [String: JSONValue]

/// A JSON array of ``JSONValue``s.
public typealias JSONArray = [JSONValue]

// MARK: - Errors

/// Errors thrown by ``JSONValue``'s bridging conveniences.
public enum JSONValueError: Error, LocalizedError {
    /// The value encoded to a non-object; thrown by `[String: JSONValue].init(encoding:using:)`.
    case expectedObject

    /// Never thrown by this package; retained for source compatibility only.
    @available(*, deprecated, message: "This case is never thrown and will be removed in the next major release.")
    case invalidJSONObject

    public var errorDescription: String? {
        switch self {
        case .expectedObject:
            return "Expected a top-level JSON object."
        default: // `.invalidJSONObject`, matched via `default` to avoid referencing the deprecated case
            return "Value is not a valid JSON object."
        }
    }
}

// MARK: - Coding Policy

/// The package-wide default JSON coding policy: ISO-8601 dates (with time zone),
/// base64 `Data`, and non-conforming floats as `"Infinity"` / `"-Infinity"` /
/// `"NaN"` strings. These factories supply the default encoder/decoder arguments
/// throughout `JSONValue`'s bridging API.
public enum JSONCoding {
    /// An encoder with the package's default strategies, for turning `Encodable`
    /// values into `JSONValue` trees.
    public static func makeValueEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithTimeZone
        encoder.dataEncodingStrategy = .base64
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }

    /// `makeValueEncoder()` plus `.sortedKeys`, so wire output is deterministic
    /// (byte-identical for equal values).
    public static func makeWireEncoder() -> JSONEncoder {
        let encoder = makeValueEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// The decoding counterpart of ``makeValueEncoder()``.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithTimeZone
        decoder.dataDecodingStrategy = .base64
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }
}

/// Deprecated former name of ``JSONCoding``.
@available(*, deprecated, renamed: "JSONCoding")
public typealias MCPJSONCoding = JSONCoding

// MARK: - JSONValue

/// A type-safe model of any JSON document. `@frozen` because JSON's grammar
/// is fixed: these eight cases cover every value it can express, with whole
/// numbers split into signed/unsigned so 64-bit values keep full precision.
@frozen public indirect enum JSONValue: Codable, Sendable, Hashable {
    /// JSON `null`.
    case null
    /// A JSON boolean.
    case bool(Bool)
    /// A whole JSON number within `Int`'s range.
    case integer(Int)
    /// A whole JSON number carried as `UInt` (used when decoding values above `Int.max`).
    case unsignedInteger(UInt)
    /// Any other JSON number.
    case double(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array(JSONArray)
    /// A JSON object.
    case object(JSONDictionary)

    // MARK: Codable

    /// Decodes any JSON value, trying `null`, `Bool`, `Int`, `UInt`, `Double`, `String`,
    /// array, then object — first match wins.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(JSONArray.self) {
            self = .array(value)
        } else if let value = try? container.decode(JSONDictionary.self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON value cannot be decoded"
            )
        }
    }

    /// Encodes the payload transparently — plain JSON on the wire, no case labels.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .unsignedInteger(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    // MARK: Bridging Encodable

    /// Encodes `value` with `encoder` and re-reads the result as a `JSONValue` tree.
    /// The generic fast path: the concrete type is statically known, so the encoder's
    /// strategies (dates, data, floats) apply at every level, including the top.
    public init<T: Encodable>(encoding value: T, using encoder: JSONEncoder = JSONCoding.makeValueEncoder()) throws {
        let data = try encoder.encode(value)
        self = try JSONCoding.makeDecoder().decode(JSONValue.self, from: data)
    }

    /// The existential counterpart of the generic `init(encoding:using:)`, for values
    /// only known as `any Encodable` at the call site (the generic overload wins whenever
    /// the concrete type is visible). This path routes through a type-erasing wrapper
    /// whose `encode(to:)` calls the value directly, bypassing `JSONEncoder`'s *top-level*
    /// strategies — hence the special cases: a bare `Data` (or `[Data]`) would otherwise
    /// encode as a byte array instead of base64.
    public init(encoding value: any Encodable, using encoder: JSONEncoder = JSONCoding.makeValueEncoder()) throws {
        // The opaque wrapper defeats the top-level `dataEncodingStrategy`, so
        // base64-encode `Data` explicitly to match the generic overload.
        if let data = value as? Data {
            self = .string(data.base64EncodedString())
            return
        }

        if let values = value as? [Data] {
            self = .array(values.map { .string($0.base64EncodedString()) })
            return
        }

        let data = try encoder.encode(_JSONValueOpaqueEncodable(value))
        self = try JSONCoding.makeDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: Foundation Bridging

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Builds a `JSONValue` from a Foundation JSON object graph — the `Any?`
    /// produced by `JSONSerialization` (`NSNull`, `NSNumber`, `String`,
    /// `Array`, `Dictionary`). `nil`/`NSNull` map to `.null`; unsupported values
    /// trip an assertion in debug and fall back to a string description.
    public init(jsonObject value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let jsonValue as JSONValue:
            self = jsonValue
        case let bool as Bool:
            // JSONSerialization vends numbers as NSNumber, and on every platform
            // NSNumber(0)/NSNumber(1) dynamic-cast to Bool — which would turn
            // JSON 0/1 into booleans here. Only a true boolean NSNumber may
            // become `.bool`; every other NSNumber is a number.
            if let number = value as? NSNumber, !Self.isBooleanNSNumber(number) {
                self = JSONValue(bridging: number)
                break
            }
            self = .bool(bool)
        case let int as Int:
            self = .integer(int)
        case let int8 as Int8:
            self = .integer(Int(int8))
        case let int16 as Int16:
            self = .integer(Int(int16))
        case let int32 as Int32:
            self = .integer(Int(int32))
        case let int64 as Int64:
            self = Int(exactly: int64).map(JSONValue.integer) ?? .double(Double(int64))
        case let uint as UInt:
            self = .unsignedInteger(uint)
        case let uint8 as UInt8:
            self = .unsignedInteger(UInt(uint8))
        case let uint16 as UInt16:
            self = .unsignedInteger(UInt(uint16))
        case let uint32 as UInt32:
            self = .unsignedInteger(UInt(uint32))
        case let uint64 as UInt64:
            self = UInt(exactly: uint64).map(JSONValue.unsignedInteger) ?? .double(Double(uint64))
        case let float as Float:
            self = .double(Double(float))
        case let double as Double:
            self = .double(double)
        case let number as NSNumber:
            // Re-check: a boolean NSNumber usually matches the `Bool` case
            // above, but not on every platform/bridging path.
            if Self.isBooleanNSNumber(number) {
                self = .bool(number.boolValue)
                break
            }
            self = JSONValue(bridging: number)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue(jsonObject: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(jsonObject: $0) })
        default:
            assertionFailure("Unsupported JSON object value: \(String(describing: value))")
            self = .string(String(describing: value))
        }
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    /// Whether `number` is a true boolean. On Darwin that means a `CFBoolean`;
    /// swift-corelibs-foundation backs every boolean `NSNumber` with the
    /// `kCFBooleanTrue`/`kCFBooleanFalse` singletons (`Bool._bridgeToObjectiveC`),
    /// so there identity distinguishes JSON `true`/`false` from the numeric 0/1.
    private static func isBooleanNSNumber(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        return number === NSNumber(value: true) || number === NSNumber(value: false)
        #endif
    }

    /// Classifies a non-boolean `NSNumber` as `.integer`, `.unsignedInteger`,
    /// or `.double`, preferring the narrowest case that is value-preserving.
    private init(bridging number: NSNumber) {
        if let int = Int(exactly: number.int64Value), number.doubleValue == Double(int) {
            self = .integer(int)
        } else if let uint = UInt(exactly: number.uint64Value), number.doubleValue == Double(uint) {
            self = .unsignedInteger(uint)
        } else {
            self = .double(number.doubleValue)
        }
    }

    /// The Foundation object graph accepted by `JSONSerialization` — the inverse of
    /// ``init(jsonObject:)``. `.null` maps to `NSNull()`; containers convert recursively.
    public var jsonObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .integer(let value):
            return value
        case .unsignedInteger(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.jsonObject)
        case .object(let values):
            return values.mapValues(\.jsonObject)
        }
    }

    /// Deprecated former name of ``jsonObject``.
    @available(*, deprecated, renamed: "jsonObject")
    public var value: Any { jsonObject }

    // MARK: Accessors

    /// The payload if this is `.string`; `nil` otherwise.
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// The payload if this is `.bool`; `nil` otherwise.
    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    /// The `.integer` payload, or an `.unsignedInteger` payload that fits via `Int(exactly:)`.
    public var intValue: Int? {
        switch self {
        case .integer(let value):
            return value
        case .unsignedInteger(let value):
            return Int(exactly: value)
        default:
            return nil
        }
    }

    /// The `.unsignedInteger` payload, or a non-negative `.integer` payload via `UInt(exactly:)`.
    public var uintValue: UInt? {
        switch self {
        case .unsignedInteger(let value):
            return value
        case .integer(let value):
            return UInt(exactly: value)
        default:
            return nil
        }
    }

    /// The `.double` payload, or either integer case converted (lossy above 2^53).
    public var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .integer(let value):
            return Double(value)
        case .unsignedInteger(let value):
            return Double(value)
        default:
            return nil
        }
    }

    /// The payload if this is `.array`; `nil` otherwise.
    public var arrayValue: JSONArray? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    /// The payload if this is `.object`; `nil` otherwise.
    public var dictionaryValue: JSONDictionary? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    // MARK: Decoding Helpers

    /// Re-encodes this value and decodes the result as `T` — the inverse of ``init(encoding:using:)``.
    public func decoded<T: Decodable>(
        _ type: T.Type = T.self,
        using decoder: JSONDecoder = JSONCoding.makeDecoder()
    ) throws -> T {
        let data = try JSONCoding.makeWireEncoder().encode(self)
        return try decoder.decode(T.self, from: data)
    }

    /// Decodes this value into a dynamically-supplied `Decodable` type — the
    /// type-erased counterpart to `decoded(_:using:)`, for when the concrete
    /// type is only known at runtime (e.g. `any Decodable.Type`).
    public func decodeDynamically(
        _ type: any Decodable.Type,
        using decoder: JSONDecoder = JSONCoding.makeDecoder()
    ) throws -> any Decodable {
        let data = try JSONCoding.makeWireEncoder().encode(self)
        return try decoder.decode(type, from: data)
    }
}

// MARK: - Descriptions

extension JSONValue: CustomStringConvertible {
    /// A human-readable rendering for logs — not JSON text: `.string` yields
    /// the raw, unquoted payload. Encode the value for wire output.
    public var description: String {
        switch self {
        case .null:
            return "null"
        case .string(let value):
            return value
        default:
            return String(describing: jsonObject)
        }
    }
}

extension JSONValue: CustomDebugStringConvertible {
    /// ``description`` wrapped in `JSONValue(...)`.
    public var debugDescription: String { "JSONValue(\(description))" }
}

// MARK: - Literal Conformances

extension JSONValue: ExpressibleByNilLiteral {
    /// A `nil` literal is `.null`.
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    /// A boolean literal is `.bool`.
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    /// An integer literal is `.integer`.
    public init(integerLiteral value: Int) {
        self = .integer(value)
    }
}

extension JSONValue: ExpressibleByFloatLiteral {
    /// A float literal is `.double`.
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    /// A string literal is `.string`.
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    /// An array literal is `.array` of its elements.
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    /// A dictionary literal is `.object`; keys must be unique.
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Type-Erasing Wrapper

// Erases `any Encodable` into a concrete `Encodable` for `JSONEncoder`. Its `encode(to:)`
// forwards to the wrapped value directly, so the encoder's *top-level* strategies
// (e.g. `Data` → base64) do not apply; `JSONValue.init(encoding:using:)` special-cases those.
// Leading underscore marks this as an internal, unstable type-erasing wrapper.
// swiftlint:disable:next type_name
struct _JSONValueOpaqueEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        encodeImpl = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}
