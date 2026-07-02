import Foundation

/// A type that supplies its own JSON Schema representation.
///
/// Conformance is the first stop in the runtime type-to-schema fallback chain
/// (see `JSONSchema.schema(for:description:)`): it takes precedence over
/// `SchemaRepresentable` metadata and the `CaseIterable` enum handling.
public protocol JSONSchemaTypeConvertible {
    /// The JSON Schema representation for this type
    static func jsonSchema(description: String?) -> JSONSchema
}

// MARK: - Shared fallback chain

extension JSONSchema {
    /// Resolves the schema for an arbitrary runtime type using the shared fallback chain:
    /// `JSONSchemaTypeConvertible` → `SchemaRepresentable` → `CaseIterable` → plain string.
    ///
    /// Used by `SchemaPropertyInfo.schema` and the `Array`/`Optional` conformances below,
    /// so future additions to the chain only need to be made here.
    static func schema(for type: Any.Type, description: String?) -> JSONSchema {
        // If this is a JSONSchemaTypeConvertible type, use its schema
        if let convertibleType = type as? any JSONSchemaTypeConvertible.Type {
            return convertibleType.jsonSchema(description: description)
        }

        // If this is a SchemaRepresentable type, use its schema
        if let schemaType = type as? any SchemaRepresentable.Type {
            return schemaType.schemaMetadata.schema
        }

        // If this is a CaseIterable type that isn't JSONSchemaTypeConvertible,
        // return a string schema with enum values
        if let caseIterableType = type as? any CaseIterable.Type {
            return .enum(values: caseIterableType.caseLabels, title: nil, description: description, enumNames: nil)
        }

        // Default to string for unknown types
        return .string(title: nil, description: description, format: nil, minLength: nil, maxLength: nil)
    }
}

// MARK: - CaseIterable default implementation

// Default implementation so a CaseIterable enum gets an enum schema simply by
// declaring JSONSchemaTypeConvertible conformance (opt-in, not automatic).
extension CaseIterable {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .enum(values: caseLabels, title: nil, description: description, enumNames: nil)
    }
}

// MARK: - Numeric conformances

extension Int: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .number(title: nil, description: description, minimum: nil, maximum: nil)
    }
}

extension UInt: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .number(title: nil, description: description, minimum: nil, maximum: nil)
    }
}

extension Int8: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .number(title: nil, description: description, minimum: nil, maximum: nil)
    }
}

extension Int16: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .number(title: nil, description: description, minimum: nil, maximum: nil)
    }
}

extension Int32: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .number(title: nil, description: description, minimum: nil, maximum: nil)
    }
}

extension Int64: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .number(title: nil, description: description, minimum: nil, maximum: nil)
    }
}

extension UInt8: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .number(title: nil, description: description, minimum: nil, maximum: nil)
    }
}

extension UInt16: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .number(title: nil, description: description, minimum: nil, maximum: nil)
    }
}

extension UInt32: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .number(title: nil, description: description, minimum: nil, maximum: nil)
    }
}

extension UInt64: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .number(title: nil, description: description, minimum: nil, maximum: nil)
    }
}

extension Float: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .number(title: nil, description: description, minimum: nil, maximum: nil)
    }
}

extension Double: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .number(title: nil, description: description, minimum: nil, maximum: nil)
    }
}

// MARK: - Boolean conformance

extension Bool: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .boolean(title: nil, description: description, defaultValue: nil)
    }
}

// MARK: - String-encoded conformances

extension String: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .string(title: nil, description: description, format: nil, minLength: nil, maxLength: nil)
    }
}

extension Character: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .string(title: nil, description: description, format: nil, minLength: nil, maxLength: nil)
    }
}

extension Data: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .string(title: nil, description: description, format: "byte", minLength: nil, maxLength: nil)
    }
}

extension Date: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .string(title: nil, description: description, format: "date-time", minLength: nil, maxLength: nil)
    }
}

extension URL: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .string(title: nil, description: description, format: "uri", minLength: nil, maxLength: nil)
    }
}

extension UUID: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .string(title: nil, description: description, format: "uuid", minLength: nil, maxLength: nil)
    }
}

// MARK: - Container conformances

extension Array: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        // The array-level description stays on the wrapper; the element schema carries none.
        .array(
            items: JSONSchema.schema(for: Element.self, description: nil),
            title: nil,
            description: description
        )
    }
}

extension Dictionary: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        .object(JSONSchema.Object(properties: [:], required: [], title: nil, description: description))
    }
}

extension Optional: JSONSchemaTypeConvertible {
    public static func jsonSchema(description: String?) -> JSONSchema {
        JSONSchema.schema(for: Wrapped.self, description: description)
    }
}
