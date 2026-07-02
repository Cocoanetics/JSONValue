import Foundation
@testable import JSONFoundation
import Testing

@Suite("JSONRPCMessage codec edge cases")
struct JSONRPCMessageCodecTests {
    /// Regression: a response with a nil result used to omit the `result` key —
    /// spec-invalid, and rejected by this library's own decoder.
    @Test func nilResultResponseEncodesAsNullAndRoundTrips() throws {
        let message = JSONRPCMessage.response(id: 7)
        let data = try message.encoded()
        let text = String(bytes: data, encoding: .utf8) ?? ""
        #expect(text.contains("\"result\":null"))

        let decoded = try JSONRPCMessage.decodeMessages(from: data)
        #expect(decoded == [.response(id: 7, result: .null)])
    }

    /// A UTF-8 BOM is tolerated by JSONDecoder, so the shape sniff (and thus
    /// the batch-error rethrow path) must tolerate it too.
    @Test func bomPrefixedBatchIsRecognizedAndDecodes() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(#"[{"jsonrpc":"2.0","id":1,"result":"ok"}]"#.utf8))
        #expect(JSONRPCMessage.isBatchPayload(data))
        let decoded = try JSONRPCMessage.decodeMessages(from: data)
        #expect(decoded == [.response(id: 1, result: .string("ok"))])
    }

    /// Regression: a batch with a malformed element used to fall through to the
    /// single-object decode, replacing the real per-element error with a
    /// misleading type mismatch about the array shape.
    @Test func malformedBatchElementSurfacesItsOwnError() {
        let data = Data(#"[{"jsonrpc":"2.0","id":1,"result":"ok"},{"bogus":true}]"#.utf8)
        do {
            _ = try JSONRPCMessage.decodeMessages(from: data)
            Issue.record("expected decodeMessages to throw")
        } catch let error as DecodingError {
            let path: [CodingKey]
            switch error {
            case .keyNotFound(_, let context), .dataCorrupted(let context),
                 .typeMismatch(_, let context), .valueNotFound(_, let context):
                path = context.codingPath
            @unknown default:
                path = []
            }
            // The failing element's index is preserved in the coding path.
            #expect(path.first?.intValue == 1)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Malformed single messages

    /// Decodes a payload expected to be malformed and returns the
    /// `DecodingError` it threw, recording an issue (and returning `nil`) if it
    /// decoded or threw something else.
    private func decodingFailure(of json: String) -> DecodingError? {
        do {
            _ = try JSONRPCMessage.decodeMessages(from: Data(json.utf8))
            Issue.record("expected decodeMessages to throw for \(json)")
        } catch let error as DecodingError {
            return error
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        return nil
    }

    /// An object with no keys fails on the one field every message shape
    /// requires.
    @Test func emptyObjectFailsOnMissingJSONRPCKey() {
        guard let error = decodingFailure(of: "{}") else { return }
        guard case .keyNotFound(let key, _) = error else {
            Issue.record("expected keyNotFound, got \(error)")
            return
        }
        #expect(key.stringValue == "jsonrpc")
    }

    /// A `result` shape without an `id` is spec-invalid: the codec's dedicated
    /// missing-id path must fire rather than misclassifying the message.
    @Test func responseWithoutIDIsRejected() {
        guard let error = decodingFailure(of: #"{"jsonrpc":"2.0","result":1}"#) else { return }
        guard case .dataCorrupted(let context) = error else {
            Issue.record("expected dataCorrupted, got \(error)")
            return
        }
        #expect(context.debugDescription.contains("id"))
    }

    /// With none of `method`/`result`/`error` present, the key sniff cannot
    /// classify the message and must say so.
    @Test func objectWithoutDiscriminatorKeyIsRejected() {
        guard let error = decodingFailure(of: #"{"jsonrpc":"2.0"}"#) else { return }
        guard case .dataCorrupted(let context) = error else {
            Issue.record("expected dataCorrupted, got \(error)")
            return
        }
        #expect(context.debugDescription.contains("message type"))
    }

    /// A boolean id matches neither wire form `JSONRPCID` accepts.
    @Test func booleanIDIsRejectedAsTypeMismatch() {
        guard let error = decodingFailure(of: #"{"jsonrpc":"2.0","id":true,"method":"m"}"#) else { return }
        guard case .typeMismatch(let type, _) = error else {
            Issue.record("expected typeMismatch, got \(error)")
            return
        }
        #expect(type is JSONRPCID.Type)
    }
}
