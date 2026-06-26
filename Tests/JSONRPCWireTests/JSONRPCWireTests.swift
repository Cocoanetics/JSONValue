import Foundation
import Testing
import JSONRPCWire

private func body(_ string: String) -> Data { Data(string.utf8) }
private func text(_ data: Data) -> String? { String(data: data, encoding: .utf8) }

// MARK: - ContentLengthFraming

@Test func contentLengthRoundTripsOneMessage() {
    var framing = ContentLengthFraming()
    let out = framing.push(framing.frame(body(#"{"jsonrpc":"2.0","id":1}"#)))
    #expect(out.count == 1)
    #expect(text(out[0]) == #"{"jsonrpc":"2.0","id":1}"#)
}

@Test func contentLengthSplitsTwoMessagesInOneChunk() {
    var framing = ContentLengthFraming()
    let chunk = framing.frame(body(#"{"a":1}"#)) + framing.frame(body(#"{"b":2}"#))
    let out = framing.push(chunk)
    #expect(out.count == 2)
    #expect(text(out[1]) == #"{"b":2}"#)
}

@Test func contentLengthReassemblesAcrossChunks() {
    var framing = ContentLengthFraming()
    var emitted: [Data] = []
    for byte in framing.frame(body(#"{"hello":"world"}"#)) { emitted += framing.push(Data([byte])) }
    #expect(emitted.count == 1)
    #expect(text(emitted[0]) == #"{"hello":"world"}"#)
}

@Test func contentLengthCountsBytesNotCharacters() {
    var framing = ContentLengthFraming()
    let out = framing.push(framing.frame(body(#"{"v":"café"}"#))) // 5 UTF-8 bytes, 4 chars
    #expect(out.count == 1)
    #expect(text(out[0]) == #"{"v":"café"}"#)
}

// MARK: - LineFraming

@Test func lineFramingAppendsNewline() {
    #expect(LineFraming().frame(body(#"{"id":1}"#)).last == 0x0A)
}

@Test func lineFramingSplitsMultipleLines() {
    var framing = LineFraming()
    let chunk = framing.frame(body(#"{"a":1}"#)) + framing.frame(body(#"{"b":2}"#))
    let out = framing.push(chunk)
    #expect(out.count == 2)
    #expect(text(out[0]) == #"{"a":1}"#)
}

@Test func lineFramingReassemblesAcrossChunks() {
    var framing = LineFraming()
    var emitted: [Data] = []
    for byte in framing.frame(body(#"{"x":42}"#)) { emitted += framing.push(Data([byte])) }
    #expect(emitted.count == 1)
    #expect(text(emitted[0]) == #"{"x":42}"#)
}

// MARK: - SSEEventDecoder

@Test func sseDecodesOneEvent() {
    var decoder = SSEEventDecoder()
    let out = decoder.push(body("data: {\"id\":1}\n\n"))
    #expect(out.count == 1)
    #expect(text(out[0]) == "{\"id\":1}")
}

@Test func sseIgnoresCommentsAndNonDataFields() {
    var decoder = SSEEventDecoder()
    let out = decoder.push(body(": keep-alive\nevent: message\nid: 7\ndata: {\"x\":1}\n\n"))
    #expect(out.count == 1)
    #expect(text(out[0]) == "{\"x\":1}")
}

@Test func sseDecodesTwoEventsInOneChunk() {
    var decoder = SSEEventDecoder()
    let out = decoder.push(body("data: {\"a\":1}\n\ndata: {\"b\":2}\n\n"))
    #expect(out.count == 2)
    #expect(text(out[1]) == "{\"b\":2}")
}

@Test func sseToleratesCRLF() {
    var decoder = SSEEventDecoder()
    let out = decoder.push(body("data: {\"id\":5}\r\n\r\n"))
    #expect(out.count == 1)
    #expect(text(out[0]) == "{\"id\":5}")
}
