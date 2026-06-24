import Foundation
import JSONFoundation
import Testing

struct JSONValueTests {
    @Test func accessorsReflectCases() {
        #expect(JSONValue.string("hi").stringValue == "hi")
        #expect(JSONValue.bool(true).boolValue == true)
        #expect(JSONValue.integer(7).intValue == 7)
        #expect(JSONValue.double(2.5).doubleValue == 2.5)
        #expect(JSONValue.array([.integer(1), .string("x")]).arrayValue?.count == 2)
        #expect(JSONValue.object(["k": .bool(false)]).dictionaryValue?["k"]?.boolValue == false)
        #expect(JSONValue.null.stringValue == nil)
    }

    @Test func codableRoundTrip() throws {
        let original: JSONValue = .object([
            "name": .string("acp"),
            "count": .integer(3),
            "ratio": .double(0.5),
            "tags": .array([.string("a"), .string("b")]),
            "nested": .object(["ok": .bool(true)]),
            "missing": .null
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded.dictionaryValue?["name"]?.stringValue == "acp")
        #expect(decoded.dictionaryValue?["count"]?.intValue == 3)
        #expect(decoded.dictionaryValue?["ratio"]?.doubleValue == 0.5)
        #expect(decoded.dictionaryValue?["tags"]?.arrayValue?.count == 2)
        #expect(decoded.dictionaryValue?["nested"]?.dictionaryValue?["ok"]?.boolValue == true)
    }

    @Test func encodesAnyEncodableValue() throws {
        struct Payload: Encodable { let id: Int; let label: String }
        let json = try JSONValue(encoding: Payload(id: 1, label: "x"))
        #expect(json.dictionaryValue?["id"]?.intValue == 1)
        #expect(json.dictionaryValue?["label"]?.stringValue == "x")
    }
}
