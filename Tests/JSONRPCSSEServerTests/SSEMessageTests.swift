import Foundation
@testable import JSONRPCSSEServer
import Testing

@Test func sseMessageDescriptionMatchesEncoder() {
    // SSEMessage delegates wire encoding to SSEEventEncoder; assert they agree.
    #expect(SSEMessage(data: "hi", id: "s:1").description == "id: s:1\ndata: hi\n\n")
    #expect(SSEMessage(data: "").description == "data:\n\n")
    #expect(SSEMessage(data: "a\nb").description == "data: a\ndata: b\n\n")
    #expect(SSEMessage(data: "u", eventName: "endpoint").description == "event: endpoint\ndata: u\n\n")
    #expect(SSEMessage(comment: "ka").description == ": ka\n")
}

@Test func parsePreservesDataWhitespace() {
    // Valid SSE strips only the single optional space after the colon; a payload
    // with intentional surrounding whitespace must survive description → init.
    func dataValue(_ message: SSEMessage?) -> String? {
        guard case .field(_, let value, _)? = message?.event else { return nil }
        return value
    }
    for payload in [" x ", "  leading", "trailing  ", "a\n b ", "mid  gap", "plain"] {
        let reparsed = SSEMessage(SSEMessage(data: payload).description)
        #expect(dataValue(reparsed) == payload, "payload \(payload.debugDescription)")
    }
}

@Test func parseRoundTripsEnvelopeFields() {
    // The id/retry/event envelope must parse back too, not just the data payload.
    let original = SSEMessage(data: "payload", eventName: "message", id: "s:9", retry: 1500)
    #expect(SSEMessage(original.description) == original)
}

@Test func commentRoundTripsThroughDescription() {
    // The LosslessStringConvertible round trip must hold for comments too.
    #expect(SSEMessage(": ka\n") == SSEMessage(comment: "ka"))
    #expect(SSEMessage(SSEMessage(comment: "keep-alive").description) == SSEMessage(comment: "keep-alive"))
    // Only the single optional space after the colon is stripped.
    #expect(SSEMessage(":  padded\n") == SSEMessage(comment: " padded"))
    // Neither data nor comment: not a message.
    #expect(SSEMessage("event: only\n\n") == nil)
    #expect(SSEMessage("") == nil)
}

@Test func nonDataFieldNameEncodesAsDataAndIsNotReplayable() {
    // The encoder speaks only `data:` lines: a field case with any other name is
    // rendered as a data event on the wire yet excluded from the replay buffer —
    // pinning the behavior documented on SSEEvent.field.
    let message = SSEMessage(event: .field(name: "foo", value: "x"))
    #expect(message.description == "data: x\n\n")
    #expect(message.isReplayableDataEvent == false)
    #expect(SSEMessage(data: "x").isReplayableDataEvent == true)
}
