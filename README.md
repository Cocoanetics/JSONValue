# JSONFoundation

A small, dependency-free Swift package for working with JSON. A single module —
`JSONFoundation` — covering three layers that compose:

- **`JSONValue`** — a `Codable`/`Sendable` representation of an arbitrary JSON value
- **`JSONSchema`** — a model of JSON Schema, for *describing* data (e.g. tool/function parameter schemas)
- **JSON-RPC 2.0** — `Codable` request / response / notification / error envelope types

Pure Foundation, zero third-party dependencies — it builds on every Swift
platform (macOS, iOS, tvOS, watchOS, Linux, Windows, Android). Extracted from
[SwiftMCP](https://github.com/Cocoanetics/SwiftMCP) and shared across SwiftMCP,
SwiftACP and SwiftAgents.

```swift
import JSONFoundation
```

## JSONValue

`JSONValue` is an `enum` over the JSON types — `null`, `bool`, `integer`,
`unsignedInteger`, `double`, `string`, `array`, `object` — that is `Codable`,
`Sendable`, `Hashable`, and ergonomic to build and inspect:

```swift
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

Typed accessors (`stringValue`, `intValue`, `doubleValue`, `boolValue`,
`arrayValue`, `dictionaryValue`) and the `JSONDictionary` / `JSONArray`
typealiases round it out.

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

`SchemaRepresentable`, `SchemaMetadata`, `SchemaPropertyInfo` and
`JSONSchemaTypeConvertible` derive schemas from Swift types.

## JSON-RPC 2.0

Foundation-only envelope types for JSON-RPC 2.0 — the wire model only, no
transport (bring your own). Ids accept integer/string literals, messages are
`Equatable`/`Hashable`, and encoding is the symmetric inverse of decoding:

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

## Installation

```swift
.package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "1.2.0")
```

```swift
.product(name: "JSONFoundation", package: "JSONFoundation")
```

## License

BSD 2-Clause — see [LICENSE](LICENSE).
