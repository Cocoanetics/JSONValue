import Foundation
@testable import JSONRPCSSEServer
import Testing

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
    #expect(SSEEventID("\(UUID().uuidString):0") == nil) // sequence must be >= 1
    #expect(SSEEventID("\(UUID().uuidString):abc") == nil)
    #expect(SSEEventID(UUID().uuidString) == nil) // no colon at all
}
