import Foundation
@testable import JSONFoundation
import Testing

@Suite("JSONSchema transforms")
struct JSONSchemaTransformTests {
    /// A titled object schema, nested one level deep to catch the recursive case.
    private static func makeTitledSchema() -> JSONSchema {
        .object(.init(
            properties: [
                "inner": .object(.init(
                    properties: ["x": .number()],
                    required: ["x"],
                    title: "Inner",
                    description: "inner object"
                ))
            ],
            required: ["inner"],
            title: "Outer",
            description: "outer object"
        ))
    }

    /// Regression: both transforms used to rebuild `Object` without `title:`,
    /// erasing it at every nesting level.
    @Test func withoutRequiredKeepsTitles() {
        guard case .object(let outer, _) = Self.makeTitledSchema().withoutRequired else {
            Issue.record("expected an object schema")
            return
        }
        #expect(outer.title == "Outer")
        #expect(outer.required.isEmpty)
        guard case .object(let inner, _)? = outer.properties["inner"] else {
            Issue.record("expected a nested object schema")
            return
        }
        #expect(inner.title == "Inner")
        #expect(inner.required.isEmpty)
    }

    @Test func addingAdditionalPropertiesRestrictionKeepsTitles() {
        let transformed = Self.makeTitledSchema().addingAdditionalPropertiesRestrictionToObjects
        guard case .object(let outer, _) = transformed else {
            Issue.record("expected an object schema")
            return
        }
        #expect(outer.title == "Outer")
        #expect(outer.additionalProperties == false)
        #expect(outer.required == ["inner"]) // required is preserved by this transform
        guard case .object(let inner, _)? = outer.properties["inner"] else {
            Issue.record("expected a nested object schema")
            return
        }
        #expect(inner.title == "Inner")
        #expect(inner.additionalProperties == false)
    }
}
