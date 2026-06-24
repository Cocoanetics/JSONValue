// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "JSONFoundation",
    platforms: [
        .macOS("12.0"),
        .iOS("15.0"),
        .tvOS("15.0"),
        .watchOS("8.0"),
        .macCatalyst("15.0")
    ],
    products: [
        .library(name: "JSONFoundation", targets: ["JSONFoundation"])
    ],
    targets: [
        // Pure Foundation, zero third-party dependencies — builds on every Swift
        // platform (macOS, iOS, tvOS, watchOS, Linux, Windows, Android).
        // Bundles three layers under the single `JSONFoundation` module: the
        // `JSONValue` value type, a `JSONSchema` model, and JSON-RPC 2.0 envelope
        // types.
        .target(name: "JSONFoundation"),
        .testTarget(name: "JSONFoundationTests", dependencies: ["JSONFoundation"])
    ]
)
