//
//  SchemaMacro.swift
//  JSONFoundationMacros
//
//  Implementation of the `@Schema` macro. Synthesizes `SchemaRepresentable`
//  conformance for a struct by generating its `schemaMetadata` (a JSONFoundation
//  `SchemaMetadata` describing each stored property, with descriptions pulled
//  from doc comments) plus the `MCPClientReturn` typealias.
//
//  Moved here from SwiftMCP so that `@Schema` is available to any JSONFoundation
//  consumer without depending on SwiftMCP — the schema *model* it targets
//  (`SchemaMetadata`, `SchemaPropertyInfo`, `SchemaRepresentable`) already lives
//  in JSONFoundation.
//

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/**
 Implementation of the Schema macro.

 This macro transforms a struct into a schema by generating metadata about its properties.

 Example usage:
 ```swift
 /// A person's contact information
 @Schema
 struct ContactInfo {
     /// The person's full name
     let name: String

     /// The person's email address
     let email: String

     /// The person's phone number (optional)
     let phone: String?

     /// The person's age
     let age: Int = 0

     /// The person's address
     let address: Address
 }

 /// A person's address
 @Schema
 struct Address {
     /// The street name
     let street: String

     /// The city name
     let city: String
 }
 ```

 - Note: The macro extracts documentation from the struct's comments for:
   * Struct description
   * Property descriptions

 - Attention: The macro will emit diagnostics for:
   * Non-struct declarations (error)
   * Nested structs missing their own `@Schema` (warning, with a fix-it)
 */
public struct SchemaMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try expansion(of: node, providingMembersOf: declaration, in: context)
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            let diagnostic = Diagnostic(node: node, message: SchemaDiagnostic.onlyStructs)
            context.diagnose(diagnostic)
            return []
        }

        let structName = structDecl.name.text
        let documentation = Documentation(from: structDecl.leadingTrivia.description)
        let (propertyString, propertyTypes) = collectProperties(of: structDecl, context: context)

        let registrationDecl = makeRegistrationDeclaration(
            structName: structName,
            documentation: documentation,
            propertyString: propertyString
        )

        var declarations = [DeclSyntax(stringLiteral: registrationDecl)]
        declarations.append(DeclSyntax(stringLiteral: makeClientReturnTypealias(
            structName: structName,
            propertyTypes: propertyTypes
        )))
        return declarations
    }

    /// Walks the struct members collecting property metadata. Emits a
    /// diagnostic for nested structs lacking `@Schema`. Returns the generated
    /// `SchemaPropertyInfo` argument list plus the declared type of each
    /// included property (consumed by `makeClientReturnTypealias`).
    private static func collectProperties(
        of structDecl: StructDeclSyntax,
        context: MacroExpansionContext
    ) -> (propertyString: String, propertyTypes: [String]) {
        // Resolve the CodingKeys mapping once per struct, not once per property.
        let codingKeys = codingKeyRawValues(of: structDecl)
        var propertyString = ""
        var propertyTypes: [String] = []

        for member in structDecl.memberBlock.members {
            if let property = member.decl.as(VariableDeclSyntax.self) {
                guard shouldIncludeProperty(property) else { continue }
                let (propertyStr, propertyType) = processProperty(
                    property: property,
                    codingKeys: codingKeys
                )
                if !propertyString.isEmpty {
                    propertyString += ", "
                }
                propertyString += propertyStr
                propertyTypes.append(propertyType)
            } else if let nestedStruct = member.decl.as(StructDeclSyntax.self) {
                diagnoseNestedStructIfNeeded(nestedStruct, context: context)
            }
        }

        return (propertyString, propertyTypes)
    }

    private static func diagnoseNestedStructIfNeeded(
        _ nestedStruct: StructDeclSyntax,
        context: MacroExpansionContext
    ) {
        let hasSchemaAttribute = nestedStruct.attributes.contains { attribute in
            guard let identifierAttr = attribute.as(AttributeSyntax.self),
                  let identifier = identifierAttr.attributeName.as(IdentifierTypeSyntax.self) else {
                return false
            }
            return identifier.name.text == "Schema"
        }
        guard !hasSchemaAttribute else { return }
        let diagnostic = Diagnostic(
            node: nestedStruct.structKeyword,
            message: SchemaDiagnostic.nestedStructNeedsSchema(nestedStruct.name.text),
            fixIts: [makeAddSchemaFixIt(for: nestedStruct)]
        )
        context.diagnose(diagnostic)
    }

    /// Builds the one-click fix inserting `@Schema ` ahead of a nested struct.
    /// The struct's leading trivia (doc comments, indentation) moves onto the
    /// inserted attribute so the rewritten declaration stays well-formed.
    private static func makeAddSchemaFixIt(for nestedStruct: StructDeclSyntax) -> FixIt {
        let schemaAttribute = AttributeSyntax(
            attributeName: IdentifierTypeSyntax(name: .identifier("Schema"))
        )
        .with(\.leadingTrivia, nestedStruct.leadingTrivia)
        .with(\.trailingTrivia, .space)

        var fixedStruct = nestedStruct
        fixedStruct.leadingTrivia = Trivia(pieces: [])
        var attributes = Array(fixedStruct.attributes)
        attributes.insert(.attribute(schemaAttribute), at: 0)
        fixedStruct.attributes = AttributeListSyntax(attributes)

        return FixIt(
            message: SchemaFixIt.addSchemaAttribute,
            changes: [.replace(oldNode: Syntax(nestedStruct), newNode: Syntax(fixedStruct))]
        )
    }

    private static func makeRegistrationDeclaration(
        structName: String,
        documentation: Documentation,
        propertyString: String
    ) -> String {
        let descriptionArg = documentation.description.isEmpty
            ? "nil"
            : "\"\(documentation.description.escapedForSwiftString)\""
        return """
        /// generated
        public static let schemaMetadata = SchemaMetadata(
            name: "\(structName)",
            description: \(descriptionArg),
            parameters: [\(propertyString)]
        )
        """
    }

    /// Generates the `MCPClientReturn` typealias for the proxy generator.
    /// Single-array wrapper structs (exactly one stored array property) resolve
    /// to `[Element]`; all other structs resolve to `Self`.
    private static func makeClientReturnTypealias(
        structName: String,
        propertyTypes: [String]
    ) -> String {
        if propertyTypes.count == 1,
           let onlyType = propertyTypes.first,
           let elementType = arrayElementType(
               from: onlyType.trimmingCharacters(in: .whitespacesAndNewlines)
           ) {
            return "public typealias MCPClientReturn = [\(elementType)]"
        }
        return "public typealias MCPClientReturn = \(structName)"
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Non-structs already got the onlyStructs error from the member role;
        // adding the conformance anyway would only pile on follow-up errors.
        guard declaration.is(StructDeclSyntax.self) else {
            return []
        }

        // Check if the declaration already conforms to SchemaRepresentable
        let inheritedTypes = declaration.inheritanceClause?.inheritedTypes ?? []
        let alreadyConformsToSchemaRepresentable = inheritedTypes.contains { type in
            type.type.trimmedDescription == "SchemaRepresentable"
        }

        // If it already conforms, don't add the conformance again
        if alreadyConformsToSchemaRepresentable {
            return []
        }

        // Create an extension that adds the SchemaRepresentable protocol conformance
        let extensionDecl = try ExtensionDeclSyntax("extension \(type): SchemaRepresentable {}")

        return [extensionDecl]
    }

    private static func processProperty(
        property: VariableDeclSyntax,
        codingKeys: [String: String]
    ) -> (propertyString: String, propertyType: String) {
        // Get the property name and type
        let propertyName = property.bindings.first?
            .pattern.as(IdentifierPatternSyntax.self)?.identifier.text ?? ""
        let propertyType = property.bindings.first?
            .typeAnnotation?.type.description
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""

        // Get property description from property's documentation
        var propertyDescription = "nil"
        let propertyDoc = Documentation(from: property.leadingTrivia.description)
        if !propertyDoc.description.isEmpty {
            propertyDescription = "\"\(propertyDoc.description.escapedForSwiftString)\""
        }

        // Check for default value
        var defaultValue = "nil"
        if let initializer = property.bindings.first?.initializer {
            defaultValue = defaultValueSource(for: initializer.value, propertyType: propertyType)
        }

        // Create property info with isRequired property
        let isOptionalType = propertyType.hasSuffix("?") || propertyType.hasSuffix("!")
        let isRequired = defaultValue == "nil" && !isOptionalType

        // Strip optional marker from type for JSON schema
        let baseType = isOptionalType ? String(propertyType.dropLast()) : propertyType

        // Get the coding key raw value if available, otherwise use property name
        let schemaName = codingKeys[propertyName] ?? propertyName

        // Create parameter info with the type directly
        let propertyStr = "SchemaPropertyInfo(name: \"\(schemaName)\", type: \(baseType).self, "
            + "description: \(propertyDescription), "
            + "defaultValue: \(defaultValue) as Sendable?, "
            + "isRequired: \(isRequired))"

        return (propertyStr, propertyType)
    }

    /// Renders a property initializer as the source text emitted for the
    /// generated `defaultValue:` argument, classified by syntax node rather
    /// than by string matching.
    private static func defaultValueSource(for expression: ExprSyntax, propertyType: String) -> String {
        let source = expression.trimmedDescription

        // Implicit member expressions (`.gpt4`, `.custom(1)`) need the
        // property type prefixed so they resolve outside the property
        // declaration's inference context.
        if isRootedInImplicitMemberAccess(expression) {
            return "\(propertyType)\(source)"
        }

        // Everything else — bool/integer/float/nil/array/string literals,
        // qualified member accesses (`Date.now`), calls — is valid Swift as
        // written and re-emitted verbatim. A string literal's source text
        // already carries its own quotes and escapes.
        return source
    }

    /// True when the expression's leftmost base is an elided member access —
    /// `.stdio`, `.custom(1)`, `.a.b` — i.e. the shapes that only type-check
    /// against the property's declared type.
    private static func isRootedInImplicitMemberAccess(_ expression: ExprSyntax) -> Bool {
        if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
            guard let base = memberAccess.base else { return true }
            return isRootedInImplicitMemberAccess(base)
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return isRootedInImplicitMemberAccess(call.calledExpression)
        }
        return false
    }

    private static func shouldIncludeProperty(_ property: VariableDeclSyntax) -> Bool {
        let modifiers = property.modifiers
        if modifiers.contains(where: { $0.name.text == "static" || $0.name.text == "class" }) {
            return false
        }

        for binding in property.bindings where binding.accessorBlock != nil {
            return false
        }

        return true
    }

    /// Extracts the element type from an array type string, or returns nil if not an array.
    /// Handles `[Foo]` and `Array<Foo>` syntax. Returns nil for optional arrays like `[Foo]?`.
    private static func arrayElementType(from typeString: String) -> String? {
        // Exclude optional types
        if typeString.hasSuffix("?") || typeString.hasSuffix("!") {
            return nil
        }

        if typeString.hasPrefix("[") && typeString.hasSuffix("]") {
            let inner = typeString.dropFirst().dropLast()
            let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if typeString.hasPrefix("Array<") && typeString.hasSuffix(">") {
            let start = typeString.index(typeString.startIndex, offsetBy: 6)
            let end = typeString.index(before: typeString.endIndex)
            let trimmed = typeString[start ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
    }

    /// Builds the property-name → wire-name mapping from the struct's own
    /// nested `CodingKeys` enum (`String` raw values + `CodingKey`
    /// conformance), if any, so the enum is scanned once per struct rather
    /// than once per property. Cases without an explicit raw value map to
    /// their own name; only the annotated struct's members are considered,
    /// never an outer scope's `CodingKeys`.
    private static func codingKeyRawValues(of structDecl: StructDeclSyntax) -> [String: String] {
        for member in structDecl.memberBlock.members {
            // Any access level counts — Codable places no requirement on
            // the CodingKeys enum's visibility.
            guard let enumDecl = member.decl.as(EnumDeclSyntax.self),
                  enumDecl.name.text == "CodingKeys" else {
                continue
            }

            // Get all inherited types as strings
            let inheritedTypeDescriptions = enumDecl.inheritanceClause?.inheritedTypes.map {
                $0.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? []

            guard inheritedTypeDescriptions.contains("String"),
                  inheritedTypeDescriptions.contains("CodingKey") else {
                continue
            }

            var rawValues: [String: String] = [:]
            for enumMember in enumDecl.memberBlock.members {
                guard let enumCase = enumMember.decl.as(EnumCaseDeclSyntax.self) else { continue }

                for element in enumCase.elements {
                    if let stringLiteral = element.rawValue?.value.as(StringLiteralExprSyntax.self) {
                        rawValues[element.name.text] = stringLiteral.segments.description
                            .trimmingCharacters(in: .init(charactersIn: "\""))
                    } else {
                        // No string raw value: the wire name is the case name.
                        rawValues[element.name.text] = element.name.text
                    }
                }
            }
            return rawValues
        }

        return [:]
    }
}

// Diagnostic messages for the Schema macro
enum SchemaDiagnostic: DiagnosticMessage {
    case onlyStructs
    case nestedStructNeedsSchema(String)

    var message: String {
        switch self {
        case .onlyStructs:
            return "@Schema can only be applied to struct declarations"
        case .nestedStructNeedsSchema(let structName):
            return "Nested struct '\(structName)' needs the @Schema annotation"
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .onlyStructs:
            return MessageID(domain: "SchemaMacro", id: "onlyStructs")
        case .nestedStructNeedsSchema:
            return MessageID(domain: "SchemaMacro", id: "nestedStructNeedsSchema")
        }
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .onlyStructs:
            return .error
        case .nestedStructNeedsSchema:
            return .warning
        }
    }
}

// Fix-it labels attached to the Schema macro's diagnostics
enum SchemaFixIt: FixItMessage {
    case addSchemaAttribute

    var message: String {
        switch self {
        case .addSchemaAttribute:
            return "Add '@Schema'"
        }
    }

    var fixItID: MessageID {
        switch self {
        case .addSchemaAttribute:
            return MessageID(domain: "SchemaMacro", id: "addSchemaAttribute")
        }
    }
}
