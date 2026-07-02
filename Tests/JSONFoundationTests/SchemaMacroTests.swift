import Foundation
@testable import JSONFoundation
import Testing

// Deliberately not Codable: a `let` with an initial value cannot be decoded.
/// A person's contact information
@Schema
struct ContactInfo: Sendable {
    /// The person's full name
    let name: String
    /// The person's email address
    let email: String
    /// The person's phone number (optional)
    let phone: String?
    /// The person's age
    let age: Int = 0
}

/// A recipient with wire keys renamed via a (non-private) CodingKeys enum
@Schema
struct Recipient: Codable, Sendable {
    /// Die Straße des Empfängers 🏠
    let fullName: String

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
    }
}

/// Transport choices for the default-value tests
enum TransportKind: String, CaseIterable, Sendable {
    case stdio
    case tcp
}

/// Connection settings exercising every default-value classification shape
/// (deliberately not Codable: a `let` with an initial value cannot be decoded)
@Schema
struct ConnectionDefaults: Sendable {
    /// Chosen via an implicit member expression
    var transport: TransportKind = .stdio
    /// Bool literal
    var verbose: Bool = true
    /// Integer literal
    var port: Int = 8080
    /// Float literal
    var timeout: Double = 1.5
    /// Optional with an explicit nil default
    let proxy: String? = nil
    /// Array literal
    var tags: [String] = ["a", "b"]
    /// String literal containing dots
    var host: String = "127.0.0.1"
    /// Qualified member access
    var limit: Int = .max
}

@Suite("@Schema macro (moved into JSONFoundation)")
struct SchemaMacroTests {
    @Test func synthesizesSchemaRepresentableConformance() {
        // The macro adds `: SchemaRepresentable` — usable as the existential.
        let representable: any SchemaRepresentable.Type = ContactInfo.self
        #expect(representable.schemaMetadata.name == "ContactInfo")
    }

    @Test func capturesStructAndPropertyDocumentation() {
        let metadata = ContactInfo.schemaMetadata
        #expect(metadata.description == "A person's contact information")
        let byName = Dictionary(uniqueKeysWithValues: metadata.parameters.map { ($0.name, $0) })
        #expect(byName["name"]?.description == "The person's full name")
        #expect(byName["email"]?.description == "The person's email address")
    }

    @Test func marksRequiredVersusOptionalAndDefaulted() {
        let byName = Dictionary(uniqueKeysWithValues: ContactInfo.schemaMetadata.parameters.map { ($0.name, $0) })
        #expect(byName["name"]?.isRequired == true) // non-optional, no default
        #expect(byName["phone"]?.isRequired == false) // optional
        #expect(byName["age"]?.isRequired == false) // has a default value
    }

    @Test func producesAJSONSchema() {
        // SchemaMetadata bridges to a JSONSchema (the model already in JSONFoundation).
        let schema = ContactInfo.schemaMetadata.schema
        let encoded = try? JSONEncoder().encode(schema)
        #expect(encoded != nil)
    }

    /// Regression: the macro used to honor CodingKeys only when the enum was
    /// declared `private`; an internal one was silently ignored, so schema and
    /// wire format disagreed.
    @Test func honorsNonPrivateCodingKeys() {
        let names = Recipient.schemaMetadata.parameters.map(\.name)
        #expect(names == ["full_name"])
    }

    /// Regression: doc comments used to be stripped to printable ASCII, mangling
    /// umlauts, accents, and emoji in the generated descriptions.
    @Test func preservesNonASCIIDocumentation() {
        let description = Recipient.schemaMetadata.parameters.first?.description
        #expect(description == "Die Straße des Empfängers 🏠")
    }

    /// The macro classifies initializer expressions by syntax node (it used to
    /// string-match their source text); each shape must survive into
    /// `schemaMetadata` as a typed default value.
    @Test func capturesDefaultValueForEachInitializerShape() {
        let byName = Dictionary(
            uniqueKeysWithValues: ConnectionDefaults.schemaMetadata.parameters.map { ($0.name, $0) }
        )
        #expect(byName["transport"]?.defaultValue as? TransportKind == .stdio) // implicit member
        #expect(byName["verbose"]?.defaultValue as? Bool == true) // bool literal
        #expect(byName["port"]?.defaultValue as? Int == 8080) // integer literal
        #expect(byName["timeout"]?.defaultValue as? Double == 1.5) // float literal
        #expect(byName["tags"]?.defaultValue as? [String] == ["a", "b"]) // array literal
        #expect(byName["host"]?.defaultValue as? String == "127.0.0.1") // string with dots
        #expect(byName["limit"]?.defaultValue as? Int == Int.max) // explicit member

        // An explicit `= nil` stays a nil default (and the property optional).
        #expect(byName["proxy"] != nil)
        #expect(byName["proxy"]?.defaultValue == nil)
        #expect(byName["proxy"]?.isRequired == false)
    }
}
