//
//  SchemaPropertyInfo.swift
//  JSONFoundation
//
//  Created by Oliver Drobnik on 30.03.25.
//

import Foundation

/// Information about a single property of a schema
public struct SchemaPropertyInfo: Sendable {
    /// The name of the property
    public let name: String

    /// The actual type of the property (e.g. `Address.self`)
    public let type: Any.Type

    /// An optional description of the property
    public let description: String?

    /// An optional default value for the property
    public let defaultValue: Sendable?

    /// Whether the property is required (no default value)
    public let isRequired: Bool

    /**
     Creates a new property info with the specified name, type, description, default value,
     and required flag.

     - Parameters:
       - name: The name of the property
       - type: The actual type of the property (e.g. `Address.self`)
       - description: An optional description of the property
       - defaultValue: An optional default value for the property
       - isRequired: Whether the property is required (has no default value)
     */
    public init(
        name: String,
        type: Any.Type,
        description: String? = nil,
        defaultValue: Sendable? = nil,
        isRequired: Bool
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.defaultValue = defaultValue
        self.isRequired = isRequired
    }

    /// Converts this property info to a JSON Schema representation using the shared
    /// fallback chain (`JSONSchemaTypeConvertible` → `SchemaRepresentable` →
    /// `CaseIterable` → plain string).
    public var schema: JSONSchema {
        JSONSchema.schema(for: type, description: description)
    }

    /// Deprecated alias for ``schema``.
    @available(*, deprecated, renamed: "schema")
    public var jsonSchema: JSONSchema {
        return schema
    }
}
