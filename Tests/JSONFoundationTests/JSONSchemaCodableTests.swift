import Foundation
import JSONFoundation
import Testing

@Suite("JSONSchema Codable")
struct JSONSchemaCodableTests {
    // MARK: - Helpers

    /// Encodes a schema with sorted keys so two structurally equal schemas produce
    /// byte-identical JSON (`JSONSchema` is not `Equatable`).
    private func canonicalJSON(of schema: JSONSchema) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(bytes: try encoder.encode(schema), encoding: .utf8) ?? ""
    }

    /// Asserts that a schema survives an encode → decode → re-encode round-trip unchanged.
    private func expectLosslessRoundTrip(
        _ schema: JSONSchema,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let encoded = try canonicalJSON(of: schema)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: Data(encoded.utf8))
        let reEncoded = try canonicalJSON(of: decoded)
        #expect(reEncoded == encoded, sourceLocation: sourceLocation)
    }

    private func decodeSchema(_ json: String) throws -> JSONSchema {
        try JSONDecoder().decode(JSONSchema.self, from: Data(json.utf8))
    }

    // MARK: - Lossless round-trips

    @Test func stringSchemaRoundTrips() throws {
        try expectLosslessRoundTrip(.string(
            title: "Name",
            description: "A name",
            format: "email",
            minLength: 1,
            maxLength: 64,
            defaultValue: .string("nobody@example.com")
        ))
    }

    @Test func numberSchemaRoundTrips() throws {
        try expectLosslessRoundTrip(.number(
            title: "Ratio",
            description: "A bounded ratio",
            minimum: 0.5,
            maximum: 2.5,
            defaultValue: .double(1.5)
        ))
    }

    @Test func booleanSchemaRoundTrips() throws {
        try expectLosslessRoundTrip(.boolean(
            title: "Flag",
            description: "On or off",
            defaultValue: .bool(true)
        ))
    }

    @Test func arraySchemaRoundTrips() throws {
        try expectLosslessRoundTrip(.array(
            items: .string(format: "uri"),
            title: "Links",
            description: "A list of links",
            defaultValue: .array([.string("https://example.com")])
        ))
    }

    @Test func objectSchemaRoundTrips() throws {
        try expectLosslessRoundTrip(.object(JSONSchema.Object(
            properties: [
                "name": .string(description: "The name"),
                "age": .number(minimum: 0),
                "address": .object(JSONSchema.Object(
                    properties: ["street": .string()],
                    required: ["street"],
                    title: "Address"
                ))
            ],
            required: ["name"],
            title: "Person",
            description: "A person",
            additionalProperties: false
        )))
    }

    @Test func enumSchemaRoundTrips() throws {
        try expectLosslessRoundTrip(.enum(
            values: ["red", "green", "blue"],
            title: "Color",
            description: "A color",
            enumNames: ["Red", "Green", "Blue"],
            defaultValue: .string("red")
        ))
    }

    @Test func oneOfSchemaRoundTrips() throws {
        // All-object branches also exercise the `"type": "object"` marker in the encoder.
        let objectBranches = JSONSchema.oneOf(
            [
                .object(JSONSchema.Object(properties: ["a": .string()], required: ["a"], title: "A")),
                .object(JSONSchema.Object(properties: ["b": .number()], required: [], title: "B"))
            ],
            title: "Union",
            description: "One of A or B"
        )
        try expectLosslessRoundTrip(objectBranches)

        // Mixed branches encode without a top-level `type` key.
        try expectLosslessRoundTrip(.oneOf([.string(), .number()]))
    }

    // MARK: - Permissive decoding (lossy by design, so assert the decoded case)

    @Test func missingTypeWithPropertiesDecodesAsObject() throws {
        let schema = try decodeSchema(#"{"properties":{"name":{"type":"string"}},"required":["name"]}"#)
        guard case .object(let object, _) = schema else {
            Issue.record("expected an object schema, got \(schema)")
            return
        }
        #expect(object.properties.keys.contains("name"))
        #expect(object.required == ["name"])
    }

    @Test func missingTypeWithItemsDecodesAsArray() throws {
        let schema = try decodeSchema(#"{"items":{"type":"string"}}"#)
        guard case .array(let items, _, _, _) = schema else {
            Issue.record("expected an array schema, got \(schema)")
            return
        }
        guard case .string = items else {
            Issue.record("expected string items, got \(items)")
            return
        }
    }

    @Test func missingTypeWithEnumDecodesAsEnum() throws {
        let schema = try decodeSchema(#"{"enum":["a","b"]}"#)
        guard case .enum(let values, _, _, _, _) = schema else {
            Issue.record("expected an enum schema, got \(schema)")
            return
        }
        #expect(values == ["a", "b"])
    }

    @Test func unknownShapeFallsBackToString() throws {
        let schema = try decodeSchema(#"{"description":"anything"}"#)
        guard case .string(_, let description, _, _, _, _) = schema else {
            Issue.record("expected the string fallback, got \(schema)")
            return
        }
        #expect(description == "anything")
    }

    @Test func nullableTypeArrayDecodesAsUnderlyingType() throws {
        let schema = try decodeSchema(#"{"type":["string","null"]}"#)
        guard case .string = schema else {
            Issue.record("expected a string schema, got \(schema)")
            return
        }
    }

    @Test func anyOfDecodesAsOneOf() throws {
        let schema = try decodeSchema(#"{"anyOf":[{"type":"string"},{"type":"number"}]}"#)
        guard case .oneOf(let branches, _, _) = schema else {
            Issue.record("expected a oneOf schema, got \(schema)")
            return
        }
        #expect(branches.count == 2)
    }

    @Test func schemaFormAdditionalPropertiesCollapsesToTrue() throws {
        let json = #"{"type":"object","properties":{},"additionalProperties":{"type":"string"}}"#
        let schema = try decodeSchema(json)
        guard case .object(let object, _) = schema else {
            Issue.record("expected an object schema, got \(schema)")
            return
        }
        #expect(object.additionalProperties == true)
    }

    @Test func integerTypeDecodesAsNumber() throws {
        let schema = try decodeSchema(#"{"type":"integer","minimum":0,"maximum":10}"#)
        guard case .number(_, _, let minimum, let maximum, _) = schema else {
            Issue.record("expected a number schema, got \(schema)")
            return
        }
        #expect(minimum == 0)
        #expect(maximum == 10)
    }

    @Test func unsupportedTypeThrows() {
        #expect(throws: DecodingError.self) {
            _ = try decodeSchema(#"{"type":"banana"}"#)
        }
    }
}
