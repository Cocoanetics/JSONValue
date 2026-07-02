import Foundation
import JSONRPCWire
import Testing

private func text(_ data: Data) -> String { String(data: data, encoding: .utf8) ?? "" }

@Test func encodesSimpleDataEvent() {
    #expect(text(SSEEventEncoder().encode(data: "hello")) == "data: hello\n\n")
}

@Test func encodesEmptyDataAsBareLine() {
    // An empty payload is a single bare `data:` line (so the client dispatches an
    // event with empty data) — used for the resume-anchor priming event.
    #expect(text(SSEEventEncoder().encode(data: "")) == "data:\n\n")
}

@Test func foldsMultiLineDataToOneLineEach() {
    #expect(text(SSEEventEncoder().encode(data: "a\nb")) == "data: a\ndata: b\n\n")
}

@Test func prependsIdRetryEventInOrder() {
    let out = SSEEventEncoder().encode(data: "x", event: "e", id: "s:1", retry: 3000)
    #expect(text(out) == "id: s:1\nretry: 3000\nevent: e\ndata: x\n\n")
}

@Test func encodesIdAndDataOnly() {
    #expect(text(SSEEventEncoder().encode(data: "x", id: "abc:2")) == "id: abc:2\ndata: x\n\n")
}

@Test func encodesEventNameWithoutId() {
    #expect(text(SSEEventEncoder().encode(data: "u", event: "endpoint")) == "event: endpoint\ndata: u\n\n")
}

@Test func encodesComment() {
    #expect(text(SSEEventEncoder().comment("keep-alive")) == ": keep-alive\n")
}

@Test func encoderRoundTripsThroughDecoder() {
    // The data payload an event carries survives an encode → decode round trip.
    let encoded = SSEEventEncoder().encode(data: "{\"jsonrpc\":\"2.0\"}", id: "s:7")
    var decoder = SSEEventDecoder()
    let events = decoder.push(encoded)
    #expect(events.count == 1)
    #expect(text(events[0]) == "{\"jsonrpc\":\"2.0\"}")
}
