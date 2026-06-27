// swift-tools-version: 6.1
import PackageDescription

// JSONFoundation — the wire model for JSON, JSON Schema, and JSON-RPC, plus the
// JSON-RPC *runtime* (a transport-agnostic peer and a set of stdio/SSE transports)
// layered into logical, opt-in modules:
//
//   JSONFoundation     value type · JSON Schema · JSON-RPC 2.0 envelope   (pure)
//   JSONRPCPeer        correlation + dispatch over an abstract transport  (pure)
//   JSONRPCWire        framing codecs (Content-Length / line) · SSE decode (pure)
//   JSONRPCStdio       Foundation.Process stdio transport                 (zero-dep)
//   JSONRPCTCP         POSIX-socket TCP client transport                  (zero-dep)
//   JSONRPCSSE         HTTP+SSE client transport (URLSession + SwiftCross) (light dep)
//   JSONRPCSubprocess  swift-subprocess stdio transport                   (trait `Subprocess`)
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
        .library(name: "JSONRPCSubprocess", targets: ["JSONRPCSubprocess"]),
        // Batteries-included bundle: peer (incl. loopback) + codecs + the stdio,
        // TCP & SSE transports. Add `JSONRPCSubprocess` + the trait for the
        // swift-subprocess transport.
        .library(
            name: "JSONRPC",
            targets: ["JSONRPCPeer", "JSONRPCWire", "JSONRPCStdio", "JSONRPCTCP", "JSONRPCSSE"]
        )
    ],
    traits: [
        .default(enabledTraits: []),   // base graph: only SwiftCross (via JSONRPCSSE)
        .trait(name: "Subprocess")     // opt-in: the swift-subprocess transport
    ],
    dependencies: [
        // Cross-platform `URLSession.bytes(for:)` for JSONRPCSSE (no further deps).
        .package(url: "https://github.com/Cocoanetics/SwiftCross.git", from: "1.2.0"),
        // Only resolved when the `Subprocess` trait is enabled (the product is gated).
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.5.0")
    ],
    targets: [
        // MARK: Model (pure Foundation, zero dependencies)
        .target(name: "JSONFoundation"),

        // MARK: JSON-RPC runtime (pure — no I/O, no external deps)
        .target(name: "JSONRPCPeer", dependencies: ["JSONFoundation"]),
        .target(name: "JSONRPCWire"),

        // MARK: Transports (do I/O)
        .target(
            name: "JSONRPCStdio",                       // Foundation.Process — zero-dep
            dependencies: ["JSONFoundation", "JSONRPCPeer", "JSONRPCWire"]
        ),
        .target(
            name: "JSONRPCTCP",                         // POSIX sockets — zero-dep
            dependencies: ["JSONFoundation", "JSONRPCPeer", "JSONRPCWire"]
        ),
        .target(
            name: "JSONRPCSSE",                         // URLSession + SwiftCross (cross-platform bytes)
            dependencies: [
                "JSONFoundation", "JSONRPCPeer", "JSONRPCWire",
                .product(name: "SwiftCross", package: "SwiftCross")
            ]
        ),
        .target(
            name: "JSONRPCSubprocess",                  // swift-subprocess — trait-gated
            dependencies: [
                "JSONFoundation", "JSONRPCPeer", "JSONRPCWire",
                .product(name: "Subprocess", package: "swift-subprocess",
                         condition: .when(traits: ["Subprocess"]))
            ]
        ),

        // MARK: Tests
        .testTarget(name: "JSONFoundationTests", dependencies: ["JSONFoundation"]),
        .testTarget(name: "JSONRPCPeerTests", dependencies: ["JSONRPCPeer", "JSONFoundation"]),
        .testTarget(name: "JSONRPCWireTests", dependencies: ["JSONRPCWire"]),
        .testTarget(name: "JSONRPCStdioTests", dependencies: ["JSONRPCStdio", "JSONRPCWire", "JSONFoundation"]),
        .testTarget(name: "JSONRPCTCPTests", dependencies: ["JSONRPCTCP", "JSONRPCPeer", "JSONRPCWire", "JSONFoundation"]),
        .testTarget(name: "JSONRPCSubprocessTests", dependencies: ["JSONRPCSubprocess", "JSONRPCWire", "JSONFoundation"])
    ]
)
