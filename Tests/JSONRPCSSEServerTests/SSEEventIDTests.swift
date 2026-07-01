import Foundation
import Testing
@testable import JSONRPCSSEServer

@Test func eventIDRoundTrips() {
    let uuid = UUID()
    let parsed = SSEEventID("\(uuid.uuidString):7")
    #expect(parsed?.streamID == uuid)
    #expect(parsed?.sequence == 7)
    #expect(parsed?.description == "\(uuid.uuidString):7")
}

@Test func eventIDSplitsOnLastColon() {
    // The UUID form has no colon, but the split must be the LAST colon regardless.
    let uuid = UUID()
    #expect(SSEEventID("\(uuid.uuidString):42")?.sequence == 42)
}

@Test func eventIDRejectsMalformed() {
    #expect(SSEEventID("not-a-uuid:1") == nil)
    #expect(SSEEventID("\(UUID().uuidString):0") == nil)      // sequence must be >= 1
    #expect(SSEEventID("\(UUID().uuidString):abc") == nil)
    #expect(SSEEventID(UUID().uuidString) == nil)             // no colon at all
}

@Test func sseMessageDescriptionMatchesEncoder() {
    // SSEMessage delegates wire encoding to SSEEventEncoder; assert they agree.
    #expect(SSEMessage(data: "hi", id: "s:1").description == "id: s:1\ndata: hi\n\n")
    #expect(SSEMessage(data: "").description == "data:\n\n")
    #expect(SSEMessage(data: "a\nb").description == "data: a\ndata: b\n\n")
    #expect(SSEMessage(data: "u", eventName: "endpoint").description == "event: endpoint\ndata: u\n\n")
    #expect(SSEMessage(comment: "ka").description == ": ka\n")
}
