import Foundation
import JSONFoundation
import Testing

private func data(_ string: String) -> Data { Data(string.utf8) }

// MARK: - Decoding & round-trip

struct JSONRPCMessageTests {
    @Test func decodesEachShape() throws {
        let request = try JSONRPCMessage.decodeMessages(
            from: data(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":1}}"#)
        )
        #expect(request.first?.isRequest == true)
        #expect(request.first?.method == "ping")
        #expect(request.first?.id == .integer(1))
        #expect(request.first?.params?["x"]?.intValue == 1)

        let notification = try JSONRPCMessage.decodeMessages(
            from: data(#"{"jsonrpc":"2.0","method":"note"}"#)
        )
        #expect(notification.first?.isNotification == true)
        #expect(notification.first?.id == nil)

        let response = try JSONRPCMessage.decodeMessages(
            from: data(#"{"jsonrpc":"2.0","id":"abc","result":{"ok":true}}"#)
        )
        #expect(response.first?.isResponse == true)
        #expect(response.first?.id == .string("abc"))
        #expect(response.first?.result?["ok"]?.boolValue == true)

        let error = try JSONRPCMessage.decodeMessages(
            from: data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"nope"}}"#)
        )
        #expect(error.first?.isErrorResponse == true)
        #expect(error.first?.isReply == true)
        #expect(error.first?.error?.code == -32601)
    }

    @Test func roundTripsEachShapeWithEquality() throws {
        let messages: [JSONRPCMessage] = [
            .request(id: 1, method: "ping", params: ["x": .integer(1)]),
            .notification(method: "note", params: ["y": .string("z")]),
            .response(id: "abc", result: ["ok": .bool(true)]),
            .errorResponse(id: 2, error: .methodNotFound("frob"))
        ]
        for message in messages {
            let encoded = try message.encoded()
            let decoded = try JSONRPCMessage.decodeMessages(from: encoded)
            #expect(decoded.count == 1)
            #expect(decoded.first == message) // Equatable via synthesized Hashable
        }
    }

    @Test func handlesNonObjectParamsAndResults() throws {
        // A null result (e.g. a fs/write_text_file ack) round-trips — the object-only
        // model used to drop these.
        let nullResult = JSONRPCMessage.response(id: 1, result: .null)
        let decodedNull = try JSONRPCMessage.decodeMessages(from: nullResult.encoded())
        #expect(decodedNull.first?.isResponse == true)
        #expect(decodedNull.first?.result == JSONValue.null)

        // A primitive result decodes as such.
        let boolResult = try JSONRPCMessage.decodeMessages(
            from: data(#"{"jsonrpc":"2.0","id":1,"result":true}"#)
        )
        #expect(boolResult.first?.result?.boolValue == true)

        // Positional (array) params round-trip.
        let arrayParams = JSONRPCMessage.request(id: 1, method: "sum", params: .array([.integer(1), .integer(2)]))
        let decodedArray = try JSONRPCMessage.decodeMessages(from: arrayParams.encoded())
        #expect(decodedArray.first?.params?[0]?.intValue == 1)
        #expect(decodedArray.first?.params == JSONValue.array([.integer(1), .integer(2)]))
    }

    @Test func equatableAndHashable() {
        let first = JSONRPCMessage.request(id: 1, method: "ping")
        let same = JSONRPCMessage.request(id: 1, method: "ping")
        let other = JSONRPCMessage.request(id: 2, method: "ping")
        #expect(first == same)
        #expect(first != other)
        #expect(Set([first, same, other]).count == 2)
    }

    @Test func descriptionsAreCompactSummaries() {
        #expect(JSONRPCMessage.request(id: 1, method: "ping").description == "request(id: 1, method: ping)")
        #expect(JSONRPCMessage.notification(method: "note").description == "notification(method: note)")
        #expect(JSONRPCMessage.response(id: 1, result: nil).description == "response(id: 1)")
        #expect(JSONRPCMessage.errorResponse(id: 2, error: .parseError()).description == "error(id: 2, code: -32700)")
    }

    @Test func validateRejectsBadVersionAndEmptyMethod() {
        #expect(throws: JSONRPCError.self) {
            try JSONRPCMessage.request(jsonrpc: "1.0", id: 1, method: "ping").validate()
        }
        #expect(throws: JSONRPCError.self) {
            try JSONRPCMessage.request(id: 1, method: "").validate()
        }
        #expect((try? JSONRPCMessage.request(id: 1, method: "ping").validate()) != nil)
    }
}

// MARK: - Encoding / framing

struct JSONRPCEncodingTests {
    @Test func singleEncodesAsObject() throws {
        let message = JSONRPCMessage.request(id: 1, method: "ping")
        let encoded = try message.encoded()
        #expect(JSONRPCMessage.isBatchPayload(encoded) == false)
        #expect(try JSONRPCMessage.decodeMessages(from: encoded).count == 1)

        let string = try message.encodedString()
        #expect(string.hasPrefix("{"))
        #expect(!string.contains("\n"))
    }

    @Test func batchEncodesAsArrayEvenForOneElement() throws {
        let batch = try JSONRPCMessage.encodeBatch([
            .request(id: 1, method: "ping"),
            .request(id: 2, method: "ping")
        ])
        #expect(JSONRPCMessage.isBatchPayload(batch) == true)
        #expect(try JSONRPCMessage.decodeMessages(from: batch).count == 2)

        let single = try JSONRPCMessage.encodeBatch([.request(id: 1, method: "ping")])
        #expect(JSONRPCMessage.isBatchPayload(single) == true) // still an array
        #expect(try JSONRPCMessage.decodeMessages(from: single).count == 1)
    }

    @Test func encoderIsDeterministicAndKeepsSlashes() throws {
        let message = JSONRPCMessage.request(
            id: 1, method: "open", params: ["uri": .string("https://a/b")]
        )
        #expect(try message.encodedString().contains("https://a/b")) // not escaped to a\/b
    }
}

// MARK: - Accessors

struct JSONRPCAccessorTests {
    @Test func fieldsAreNilOffShape() {
        let request = JSONRPCMessage.request(id: 1, method: "ping", params: ["a": .integer(1)])
        #expect(request.method == "ping")
        #expect(request.params?["a"]?.intValue == 1)
        #expect(request.result == nil)
        #expect(request.error == nil)
        #expect(request.isReply == false)

        let response = JSONRPCMessage.response(id: 1, result: ["ok": .bool(true)])
        #expect(response.method == nil)
        #expect(response.result?["ok"]?.boolValue == true)
    }

    @Test func replyOutcomeCollapsesRepliesOnly() {
        let success = JSONRPCMessage.response(id: 1, result: ["ok": .bool(true)])
        guard case .success(let result)? = success.replyOutcome else {
            Issue.record("expected .success outcome")
            return
        }
        #expect(result?["ok"]?.boolValue == true)

        let failure = JSONRPCMessage.errorResponse(id: 1, error: .invalidParams("bad"))
        guard case .failure(let error)? = failure.replyOutcome else {
            Issue.record("expected .failure outcome")
            return
        }
        #expect(error.code == -32602)

        #expect(JSONRPCMessage.request(id: 1, method: "ping").replyOutcome == nil)
        #expect(JSONRPCMessage.notification(method: "n").replyOutcome == nil)
    }
}

// MARK: - JSONRPCID

struct JSONRPCIDTests {
    @Test func literalsAndAccessors() {
        let intID: JSONRPCID = 7
        let stringID: JSONRPCID = "abc"
        #expect(intID == .integer(7))
        #expect(stringID == .string("abc"))
        #expect(intID.intValue == 7)
        #expect(intID.stringValue == nil)
        #expect(stringID.stringValue == "abc")
        #expect(intID.description == "7")
        #expect(stringID.description == "abc")
    }
}

// MARK: - Errors

struct JSONRPCErrorTests {
    @Test func reservedFactoriesCarryTheRightCodes() {
        #expect(JSONRPCError.parseError().code == -32700)
        #expect(JSONRPCError.invalidRequest().code == -32600)
        #expect(JSONRPCError.methodNotFound("x").code == -32601)
        #expect(JSONRPCError.invalidParams("x").code == -32602)
        #expect(JSONRPCError.internalError("x").code == -32603)
    }

    @Test func serverErrorAndClassification() {
        let server = JSONRPCError.serverError(code: -32050, message: "busy", data: .object(["kind": .string("rate")]))
        #expect(server.code == -32050)
        #expect(server.isServerError)
        #expect(server.isReservedCode)

        #expect(JSONRPCError.parseError().isReservedCode)
        #expect(JSONRPCError.parseError().isServerError == false)
        #expect(JSONRPCError(code: 42, message: "app").isReservedCode == false)
    }

    @Test func localizedDescriptionSurfacesData() {
        let plain = JSONRPCError.internalError("boom")
        #expect(plain.localizedDescription.contains("boom"))

        let withData = JSONRPCError.serverError(code: -32000, message: "x", data: .object(["kind": .string("rate")]))
        #expect(withData.localizedDescription.contains("rate"))
    }

    @Test func isThrowable() {
        #expect(throws: JSONRPCError.self) {
            throw JSONRPCError.methodNotFound("frobnicate")
        }
    }
}
