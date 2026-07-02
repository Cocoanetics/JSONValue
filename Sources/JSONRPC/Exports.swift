//
//  Exports.swift
//  JSONRPC
//
//  The batteries-included umbrella: `import JSONRPC` re-exports the peer, the
//  framing/SSE codecs, and the always-available transports, so the product name
//  and the module name match (the same pattern as swift-collections' Collections
//  and swift-nio's NIO). The trait-gated JSONRPCSubprocess is deliberately not
//  part of the bundle — add it (plus the `Subprocess` trait) explicitly.
//

@_exported import JSONFoundation
@_exported import JSONRPCPeer
@_exported import JSONRPCSSE
@_exported import JSONRPCStdio
@_exported import JSONRPCTCP
@_exported import JSONRPCWire
