// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "JSONValue",
    platforms: [
        .macOS("12.0"),
        .iOS("15.0"),
        .tvOS("15.0"),
        .watchOS("8.0"),
        .macCatalyst("15.0")
    ],
    products: [
        .library(name: "JSONValue", targets: ["JSONValue"])
    ],
    targets: [
        // Pure Foundation, zero third-party dependencies — builds on every Swift
        // platform (macOS, iOS, tvOS, watchOS, Linux, Windows, Android).
        .target(name: "JSONValue"),
        .testTarget(name: "JSONValueTests", dependencies: ["JSONValue"])
    ]
)
