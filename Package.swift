// swift-tools-version: 6.1
import CompilerPluginSupport
import Foundation
import PackageDescription

// JSONFoundation — the wire model for JSON, JSON Schema, and JSON-RPC, plus the
// JSON-RPC *runtime* (a transport-agnostic peer and a set of stdio/SSE transports)
// layered into logical, opt-in modules:
//
//   JSONFoundation     value type · JSON Schema · JSON-RPC 2.0 envelope   (pure)
//   JSONRPCPeer        correlation + dispatch over an abstract transport  (pure)
//   JSONRPCWire        framing codecs (Content-Length / line) · SSE encode/decode (pure)
//   JSONRPCSSEServer   server-side SSE stream registry (replay, resume)   (pure)
//   JSONRPCStdio       Foundation.Process stdio transport                 (zero-dep)
//   JSONRPCTCP         POSIX-socket TCP client transport                  (zero-dep)
//   JSONRPCSSE         HTTP+SSE client transport (URLSession + SwiftCross) (light dep)
//   JSONRPCSubprocess  swift-subprocess stdio transport                   (trait `Subprocess`)
//   JSONRPC            umbrella module re-exporting peer + codecs + transports
//
// `JSONRPCPeer` also ships `LoopbackTransport` — an in-memory pair for running a
// client and server peer in one process (embedding, or subprocess-free tests).
//
// The model, peer, codecs, and the Foundation.Process / TCP transports are
// dependency-free.
// `JSONRPCSSE` pulls SwiftCross (a zero-further-dependency cross-platform shim that
// backfills `URLSession.bytes(for:)` off-Apple). swift-subprocess is quarantined
// behind the off-by-default `Subprocess` trait, and sets the macOS 13 floor.
let package = Package(
    name: "JSONFoundation",
    platforms: [
        .macOS("13.0"),
        .iOS("15.0"),
        .tvOS("15.0"),
        .watchOS("8.0"),
        .macCatalyst("15.0")
    ],
    products: [
        .library(name: "JSONFoundation", targets: ["JSONFoundation"]),
        .library(name: "JSONRPCPeer", targets: ["JSONRPCPeer"]),
        .library(name: "JSONRPCWire", targets: ["JSONRPCWire"]),
        .library(name: "JSONRPCStdio", targets: ["JSONRPCStdio"]),
        .library(name: "JSONRPCTCP", targets: ["JSONRPCTCP"]),
        .library(name: "JSONRPCSSE", targets: ["JSONRPCSSE"]),
        // The server-side counterpart of JSONRPCSSE: a transport-agnostic registry
        // of Server-Sent Event streams (replay, resume, retention). Foundation-only.
        .library(name: "JSONRPCSSEServer", targets: ["JSONRPCSSEServer"]),
        .library(name: "JSONRPCSubprocess", targets: ["JSONRPCSubprocess"]),
        // Batteries-included bundle: `import JSONRPC` re-exports the peer (incl.
        // loopback), codecs, and the stdio, TCP & SSE transports. Add
        // `JSONRPCSubprocess` + the trait for the swift-subprocess transport.
        .library(name: "JSONRPC", targets: ["JSONRPC"])
    ],
    traits: [
        .default(enabledTraits: []), // base graph: only SwiftCross (via JSONRPCSSE)
        .trait(name: "Subprocess") // opt-in: the swift-subprocess transport
    ],
    dependencies: [
        // Cross-platform `URLSession.bytes(for:)` for JSONRPCSSE (no further deps).
        .package(url: "https://github.com/Cocoanetics/SwiftCross.git", from: "1.2.0"),
        // Always resolved, but its product dependency (and thus its code) is only
        // active when the `Subprocess` trait is enabled.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.5.0"),
        // Build-time only: powers the `@Schema` macro plugin (host toolchain).
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "602.0.0-latest" ..< "604.0.0")
    ],
    targets: [
        // MARK: Macros (build-time compiler plugin — host only)

        .macro(
            name: "JSONFoundationMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ]
        ),

        // MARK: Model (pure Foundation; the `@Schema` macro is a build-time plugin)

        .target(name: "JSONFoundation", dependencies: ["JSONFoundationMacros"]),

        // MARK: JSON-RPC runtime (pure — no I/O, no external deps)

        .target(name: "JSONRPCPeer", dependencies: ["JSONFoundation"]),
        .target(name: "JSONRPCWire"),

        // MARK: SSE server registry (pure Foundation; reuses JSONRPCWire's encoder)

        .target(name: "JSONRPCSSEServer", dependencies: ["JSONRPCWire"]),

        // MARK: Transports (do I/O)

        .target(
            name: "JSONRPCStdio", // Foundation.Process — zero-dep
            dependencies: ["JSONFoundation", "JSONRPCPeer", "JSONRPCWire"]
        ),
        .target(
            name: "JSONRPCTCP", // POSIX sockets — zero-dep
            dependencies: ["JSONFoundation", "JSONRPCPeer", "JSONRPCWire"]
        ),
        .target(
            name: "JSONRPCSSE", // URLSession + SwiftCross (cross-platform bytes)
            dependencies: [
                "JSONFoundation", "JSONRPCPeer", "JSONRPCWire",
                .product(name: "SwiftCross", package: "SwiftCross")
            ]
        ),
        .target(
            name: "JSONRPCSubprocess", // swift-subprocess — trait-gated
            dependencies: [
                "JSONFoundation", "JSONRPCPeer", "JSONRPCWire",
                .product(name: "Subprocess", package: "swift-subprocess",
                         condition: .when(traits: ["Subprocess"]))
            ]
        ),

        // MARK: Umbrella (re-exports for `import JSONRPC`)

        .target(
            name: "JSONRPC",
            dependencies: [
                "JSONFoundation", "JSONRPCPeer", "JSONRPCWire",
                "JSONRPCStdio", "JSONRPCTCP", "JSONRPCSSE"
            ]
        ),

        // MARK: Tests

        .testTarget(name: "JSONFoundationTests", dependencies: ["JSONFoundation"]),
        .testTarget(name: "JSONRPCPeerTests", dependencies: ["JSONRPCPeer", "JSONFoundation"]),
        .testTarget(name: "JSONRPCWireTests", dependencies: ["JSONRPCWire"]),
        .testTarget(name: "JSONRPCSSEServerTests", dependencies: ["JSONRPCSSEServer", "JSONRPCWire"]),
        .testTarget(name: "JSONRPCStdioTests", dependencies: ["JSONRPCStdio", "JSONRPCWire", "JSONFoundation"]),
        .testTarget(name: "JSONRPCTCPTests", dependencies: ["JSONRPCTCP", "JSONRPCPeer", "JSONRPCWire", "JSONFoundation"]),
        .testTarget(name: "JSONRPCSSETests", dependencies: ["JSONRPCSSE", "JSONRPCPeer", "JSONRPCWire", "JSONFoundation"]),
        .testTarget(name: "JSONRPCSubprocessTests", dependencies: ["JSONRPCSubprocess", "JSONRPCWire", "JSONFoundation"])
    ] + macroTestTargets
)

// Cross-compiling a test target that links a `.macro` target is broken in
// SwiftPM (swiftlang/swift-package-manager#8094): the build dies on a missing
// index-store unit for the test module, even when its sources compile to
// nothing. The destination platform is not visible while this manifest is
// evaluated (on the host), so cross-compiling CI legs (Android) set this
// variable to keep the host-only macro test target out of their graph. The
// platform-conditioned dependencies additionally keep swift-syntax's test
// support out of native builds that never run these tests (e.g. Windows,
// where the file compiles to nothing via its canImport guard).
var macroTestTargets: [Target] {
    guard ProcessInfo.processInfo.environment["JSONFOUNDATION_SKIP_MACRO_TESTS"] == nil else {
        return []
    }
    return [
        .testTarget(
            name: "JSONFoundationMacrosTests",
            dependencies: [
                .target(name: "JSONFoundationMacros",
                        condition: .when(platforms: [.macOS, .linux])),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax",
                         condition: .when(platforms: [.macOS, .linux]))
            ]
        )
    ]
}
