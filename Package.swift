// swift-tools-version: 6.1
import PackageDescription

// JSONFoundation — the wire model for JSON, JSON Schema, and JSON-RPC, plus the
// JSON-RPC *runtime* (a transport-agnostic peer and dependency-free transports),
// layered into logical, opt-in modules:
//
//   JSONFoundation   value type · JSON Schema · JSON-RPC 2.0 envelope    (pure)
//   JSONRPCPeer      correlation + dispatch over an abstract transport   (pure)
//   JSONRPCWire      framing codecs (Content-Length / line) · SSE decode (pure)
//   JSONRPCStdio     Foundation.Process stdio transport                  (zero-dep)
//   JSONRPCSSE       HTTP+SSE client transport (URLSession)              (zero-dep)
//
// Every module is dependency-free, so the package stays zero-third-party and keeps
// its broad platform floor (macOS 12 / iOS 15 / …). The clean split is pure
// value-transforms (model · peer · codecs) vs. things that touch the outside world
// (the two transports). A lock-free, cross-platform transport on swift-subprocess
// lives downstream — kept out here because swift-subprocess requires macOS 13,
// which would raise this package's whole floor.
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
        .library(name: "JSONFoundation", targets: ["JSONFoundation"]),
        .library(name: "JSONRPCPeer", targets: ["JSONRPCPeer"]),
        .library(name: "JSONRPCWire", targets: ["JSONRPCWire"]),
        .library(name: "JSONRPCStdio", targets: ["JSONRPCStdio"]),
        .library(name: "JSONRPCSSE", targets: ["JSONRPCSSE"]),
        // Batteries-included bundle: peer + codecs + both transports.
        .library(name: "JSONRPC", targets: ["JSONRPCPeer", "JSONRPCWire", "JSONRPCStdio", "JSONRPCSSE"])
    ],
    targets: [
        // MARK: Model (pure Foundation, zero dependencies)
        .target(name: "JSONFoundation"),

        // MARK: JSON-RPC runtime (pure — no I/O, no external deps)
        .target(name: "JSONRPCPeer", dependencies: ["JSONFoundation"]),
        .target(name: "JSONRPCWire"),

        // MARK: Transports (do I/O; still dependency-free)
        .target(
            name: "JSONRPCStdio",                       // Foundation.Process
            dependencies: ["JSONFoundation", "JSONRPCPeer", "JSONRPCWire"]
        ),
        .target(
            name: "JSONRPCSSE",                         // URLSession
            dependencies: ["JSONFoundation", "JSONRPCPeer", "JSONRPCWire"]
        ),

        // MARK: Tests
        .testTarget(name: "JSONFoundationTests", dependencies: ["JSONFoundation"]),
        .testTarget(name: "JSONRPCPeerTests", dependencies: ["JSONRPCPeer", "JSONFoundation"]),
        .testTarget(name: "JSONRPCWireTests", dependencies: ["JSONRPCWire"]),
        .testTarget(name: "JSONRPCStdioTests", dependencies: ["JSONRPCStdio", "JSONRPCWire", "JSONFoundation"])
    ]
)
