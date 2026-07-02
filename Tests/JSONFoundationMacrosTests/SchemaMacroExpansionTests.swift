//
//  SchemaMacroExpansionTests.swift
//  JSONFoundationMacrosTests
//
//  Expansion-level tests for what the end-to-end suite in JSONFoundationTests
//  cannot cover: the macro's diagnostics. (An `@Schema enum` in a normal test
//  target would simply fail to compile.) Behavioral checks on the generated
//  metadata stay in SchemaMacroTests, which is robust against formatting drift
//  across swift-syntax versions.
//

// The macro dependencies are platform-conditioned in Package.swift (macOS/Linux
// only — cross-compiling macro test targets is broken in SwiftPM); on other
// platforms this file compiles to nothing.
#if canImport(SwiftSyntaxMacrosTestSupport)

@testable import JSONFoundationMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class SchemaMacroExpansionTests: XCTestCase {
    private let macros: [String: Macro.Type] = ["Schema": SchemaMacro.self]

    /// Applying @Schema to a non-struct emits the error and generates nothing —
    /// including no conformance extension, which would only cascade errors.
    func testOnlyStructsDiagnosticOnEnum() {
        assertMacroExpansion(
            """
            @Schema
            enum Color {
                case red
            }
            """,
            expandedSource: """
            enum Color {
                case red
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Schema can only be applied to struct declarations",
                    line: 1, column: 1, severity: .error
                )
            ],
            macros: macros
        )
    }

    /// A nested struct without its own @Schema gets a warning at its keyword,
    /// with a fix-it that inserts the attribute.
    func testNestedStructWithoutSchemaWarns() {
        assertMacroExpansion(
            """
            @Schema
            struct Outer {
                struct Inner {
                }
            }
            """,
            expandedSource: """
            struct Outer {
                struct Inner {
                }

                /// generated
                public static let schemaMetadata = SchemaMetadata(
                    name: "Outer",
                    description: nil,
                    parameters: []
                )

                public typealias MCPClientReturn = Outer
            }

            extension Outer: SchemaRepresentable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Nested struct 'Inner' needs the @Schema annotation",
                    line: 3, column: 5, severity: .warning,
                    fixIts: [FixItSpec(message: "Add '@Schema'")]
                )
            ],
            macros: macros,
            fixedSource: """
            @Schema
            struct Outer {
                @Schema struct Inner {
                }
            }
            """
        )
    }
}

#endif
