# JSONValue

A small, dependency-free Swift representation of an arbitrary JSON value.

`JSONValue` is an `enum` over the JSON types — `null`, `bool`, `integer`,
`unsignedInteger`, `double`, `string`, `array`, `object` — that is `Codable`,
`Sendable`, and ergonomic to build and inspect:

```swift
import JSONValue

let payload: JSONValue = .object([
    "name": .string("acp"),
    "tags": .array([.string("a"), .string("b")]),
    "count": .integer(3)
])

let data = try JSONEncoder().encode(payload)
let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
decoded.dictionaryValue?["name"]?.stringValue   // "acp"

// Wrap any Encodable as a JSONValue:
let json = try JSONValue(encoding: someCodableStruct)
```

Pure Foundation, zero third-party dependencies — it builds on every Swift
platform (macOS, iOS, tvOS, watchOS, Linux, Windows, Android). Extracted from
[SwiftMCP](https://github.com/Cocoanetics/SwiftMCP) so it can be shared on its
own without pulling the rest of the package.

## Installation

```swift
.package(url: "https://github.com/Cocoanetics/JSONValue.git", from: "1.0.0")
```

## License

BSD 2-Clause — see [LICENSE](LICENSE).
