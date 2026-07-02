# JSONFoundation

The wire model for JSON, JSON Schema, and JSON-RPC 2.0 — plus a transport-agnostic
JSON-RPC runtime with stdio, TCP, and HTTP+SSE transports. Layered into small,
opt-in modules:

| Product | What it is |
| --- | --- |
| `JSONFoundation` | `JSONValue` · `JSONSchema` + `@Schema` macro · JSON-RPC 2.0 envelope |
| `JSONRPCPeer` | request/response correlation + dispatch over an abstract transport (incl. `LoopbackTransport`) |
| `JSONRPCWire` | framing codecs (`Content-Length` / newline) · SSE encode/decode |
| `JSONRPCStdio` | `Foundation.Process` stdio transport |
| `JSONRPCTCP` | POSIX-socket TCP client transport |
| `JSONRPCSSE` | HTTP+SSE client transport (`URLSession`) |
| `JSONRPCSSEServer` | server-side SSE stream registry (replay, resume, retention) |
| `JSONRPCSubprocess` | swift-subprocess stdio transport (behind the `Subprocess` trait) |
| `JSONRPC` | batteries-included umbrella: peer + codecs + the stdio/TCP/SSE transports |

The model, peer, codecs, and the stdio/TCP transports are pure Foundation with no
third-party dependencies; `JSONRPCSSE` adds
[SwiftCross](https://github.com/Cocoanetics/SwiftCross) (a zero-further-dependency
shim that backfills `URLSession.bytes(for:)` off-Apple), and the `@Schema` macro
builds with swift-syntax at compile time only. Everything builds on every Swift
platform (macOS, iOS, tvOS, watchOS, Linux, Windows, Android). Extracted from
[SwiftMCP](https://github.com/Cocoanetics/SwiftMCP) and shared across SwiftMCP,
SwiftACP and SwiftAgents.

## JSONValue

`JSONValue` is an `enum` over the JSON types — `null`, `bool`, `integer`,
`unsignedInteger`, `double`, `string`, `array`, `object` — that is `Codable`,
`Sendable`, `Hashable`, and ergonomic to build and inspect:

```swift
import JSONFoundation

// ExpressibleBy* literals make construction terse:
let payload: JSONValue = [
    "name": "acp",
    "tags": ["a", "b"],
    "count": 3,
]

// Subscripts + typed accessors to read back out:
payload["name"]?.stringValue      // "acp"
payload["tags"]?[0]?.stringValue  // "a"

let data = try JSONEncoder().encode(payload)
let back = try JSONDecoder().decode(JSONValue.self, from: data)

// Bridge from / wrap other values:
let a = JSONValue(jsonObject: anyFromJSONSerialization) // Foundation `Any` -> JSONValue
let b = try JSONValue(encoding: someEncodable)          // throwing
let c = JSONValue(someEncodable)                        // best-effort, non-throwing
```

Typed accessors (`stringValue`, `intValue`, `uintValue`, `doubleValue`,
`boolValue`, `arrayValue`, `dictionaryValue`) and the `JSONDictionary` /
`JSONArray` typealiases round it out. `JSONCoding` supplies the package's default
encoder/decoder (ISO-8601 dates, base64 data, deterministic wire output).

## JSONSchema

`JSONSchema` is an `indirect enum` describing a JSON shape — `string`,
`number`, `boolean`, `array`, `object`, `enum`, `oneOf` — that round-trips to
and from standard JSON Schema. Use it wherever you need to *describe* data
rather than carry it, such as tool/function parameter schemas for LLMs or MCP:

```swift
let schema: JSONSchema = .object(.init(
    properties: [
        "city": .string(description: "City name"),
        "units": .enum(values: ["metric", "imperial"]),
    ],
    required: ["city"]
))
```

### The `@Schema` macro

Attach `@Schema` to a struct and its schema is derived at compile time, with
descriptions pulled from the doc comments:

```swift
/// A person's contact information
@Schema
struct ContactInfo {
    /// The person's full name
    let name: String

    /// The person's phone number (optional)
    let phone: String?
}

ContactInfo.schemaMetadata   // name, description, and typed property info
```

`SchemaRepresentable`, `SchemaMetadata`, `SchemaPropertyInfo` and
`JSONSchemaTypeConvertible` are the underlying protocol surface if you want to
derive schemas without the macro.

## JSON-RPC 2.0 envelope

Foundation-only envelope types for JSON-RPC 2.0. `params` and `result` are any
`JSONValue` (object, array, primitive, or `null` — the full spec shape). Ids
accept integer/string literals, messages are `Equatable`/`Hashable`, and
encoding is the symmetric inverse of decoding:

```swift
let request: JSONRPCMessage = .request(id: 1, method: "ping", params: ["x": .integer(1)])

// Encode one message as an object, or a batch as an array:
let object = try request.encoded()                              // {"id":1,"jsonrpc":"2.0",…}
let batch  = try JSONRPCMessage.encodeBatch([request, request]) // [ …, … ]

// Decode a single message or a batch from raw bytes (and recover the shape):
let messages = try JSONRPCMessage.decodeMessages(from: data)
let wasBatch = JSONRPCMessage.isBatchPayload(data)
```

Classify and read any message without switching, and correlate replies:

```swift
if message.isRequest, let method = message.method {
    route(method, message.params)
}

switch message.replyOutcome {                 // nil for a request/notification
case .success(let result)?: continuation.resume(returning: result)
case .failure(let error)?:  continuation.resume(throwing: error)
case .none: break
}
```

Errors are throwable, carry the reserved codes, and classify their range:

```swift
throw JSONRPCError.methodNotFound("frobnicate")            // -32601
throw JSONRPCError.serverError(code: -32050, message: "busy")
JSONRPCError.parseError().isReservedCode                  // true
```

- `JSONRPCID` — `.integer` / `.string`; `ExpressibleBy{Integer,String}Literal`, `intValue` / `stringValue` / `description`
- `JSONRPCMessage` — `request` / `notification` / `response` / `errorResponse`; `Equatable` + `Hashable`; accessors `id` / `method` / `params` / `result` / `error`, predicates `isRequest` / `isNotification` / `isResponse` / `isErrorResponse` / `isReply`, `replyOutcome`, `validate()`; framing `encoded()` / `encodedString()` / `encodeBatch(_:)` / `decodeMessages(from:)` / `isBatchPayload(_:)`
- `JSONRPCError` — `Error` + `LocalizedError`; factories `.parseError` / `.invalidRequest` / `.methodNotFound` / `.invalidParams` / `.internalError` / `.serverError`; range checks `isReservedCode` / `isServerError`

## JSON-RPC runtime

`import JSONRPC` (or the individual modules) adds a working peer and transports
on top of the envelope. `JSONRPCPeer` owns the semantics — request/response
correlation by id, concurrent request dispatch, in-order notifications — while
the transport owns the wire (framing + JSON coding):

```swift
import Foundation
import JSONRPC

// Two peers wired back-to-back in memory (embedding, or subprocess-free tests):
let (clientTransport, serverTransport) = LoopbackTransport.pair()
let client = JSONRPCPeer(transport: clientTransport)
let server = JSONRPCPeer(transport: serverTransport)
await server.setHandlers(request: { method, _ in .success(.string("pong:\(method)")) },
                         notification: nil)
await server.start()
await client.start()
let result = try await client.sendRequest(method: "ping", params: nil)
```

Swap the loopback for a real wire without touching the peer:

```swift
// Spawn a child process and speak newline-framed JSON-RPC over its stdio
// (an MCP/ACP client; use ContentLengthFraming() for LSP):
let transport = try ProcessTransport(
    launch: ProcessLaunch(executable: "my-server", arguments: ["--stdio"]),
    framing: LineFraming()
)

// Or connect over TCP:
let tcp = try TCPClientTransport(host: "localhost", port: 8123, framing: LineFraming())

// Or POST to an HTTP endpoint that answers with JSON or an SSE stream
// (MCP's "Streamable HTTP" shape):
let sse = SSEClientTransport(endpoint: URL(string: "https://example.com/rpc")!)
```

`JSONRPCSSEServer` is the server-side counterpart of the SSE client: a
transport-agnostic registry of Server-Sent-Event streams (`SSEStreamHub`) with
replay buffers and `Last-Event-ID` resume. `JSONRPCSubprocess` provides an
alternative stdio transport built on
[swift-subprocess](https://github.com/swiftlang/swift-subprocess) — lock-free and
fully `Sendable` — gated behind the `Subprocess` package trait (which also raises
the platform floor).

## Installation

```swift
.package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "2.5.0")
```

```swift
// The model only:
.product(name: "JSONFoundation", package: "JSONFoundation")

// Model + peer + codecs + stdio/TCP/SSE transports:
.product(name: "JSONRPC", package: "JSONFoundation")
```

Any product from the table above can be added individually. For the
swift-subprocess transport, depend on `JSONRPCSubprocess` and enable the trait:

```swift
.package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "2.5.0",
         traits: ["Subprocess"])
```

## License

BSD 2-Clause — see [LICENSE](LICENSE).
