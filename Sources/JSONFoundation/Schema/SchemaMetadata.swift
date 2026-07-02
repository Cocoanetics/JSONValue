//
//  SchemaMetadata.swift
//  JSONFoundation
//
//  Created by Oliver Drobnik on 30.03.25.
//

import Foundation

/// Metadata about a SchemaRepresentable struct
public struct SchemaMetadata: Sendable {
    /// The name of the type
    public let name: String

    /// The properties making up the type's schema
    public let parameters: [SchemaPropertyInfo]

    /// A description of the type's purpose
    public let description: String?

    /**
     Creates a new SchemaMetadata instance.

     - Parameters:
       - name: The name of the type
       - description: A description of the type's purpose
       - parameters: The properties making up the type's schema
     */
    public init(name: String, description: String? = nil, parameters: [SchemaPropertyInfo]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// Converts this schema metadata to a JSON Schema representation
    public var schema: JSONSchema {
        // Convert parameters to properties
        var properties: [String: JSONSchema] = [:]
        var required: [String] = []

        for param in parameters {
            let schema = param.schema
            properties[param.name] = schema

            if param.isRequired {
                required.append(param.name)
            }
        }

        return .object(JSONSchema.Object(
            properties: properties,
            required: required,
            description: description
        ))
    }
}
