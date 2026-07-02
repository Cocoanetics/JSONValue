//
//  SchemaRepresentable.swift
//  JSONFoundation
//
//  Created by Oliver Drobnik on 30.03.25.
//

import Foundation

/// Protocol for types that can represent themselves as a JSON Schema
public protocol SchemaRepresentable: Sendable {
    /// The metadata for the schema
    static var schemaMetadata: SchemaMetadata { get }
}

// MARK: - MCPClientReturn default

/// Provides a default `MCPClientReturn` typealias for all `Decodable` types.
///
/// This resolves to `Self` by default. The `@Schema` macro overrides it for
/// single-array wrapper structs, so the generated proxy returns `[Element]`
/// instead of the wrapper.
///
/// This retroactive extension of a standard-library protocol exists solely for
/// SwiftMCP's client-proxy generator, which emits `<ReturnType>.MCPClientReturn`
/// for *every* proxied method — including plain `Decodable` return types like
/// `String` or `[Int]` that only resolve through this default. It deliberately
/// lives here (not in SwiftMCP) so generated code needs no extra import; moving
/// it out would break SwiftMCP's generated proxies until coordinated releases.
public extension Decodable {
    typealias MCPClientReturn = Self
}
