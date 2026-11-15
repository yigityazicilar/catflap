import CatflapCore
import Foundation
import Testing

/// When a command's output is not what a test expected, the failure says the agent's reason
/// from a JSON error reply: only its `error` field, never the rest (a transfer record carries
/// device ids).
@Suite struct CommandOutputErrorTests {
    @Test func testAJSONErrorReplyShowsItsErrorFieldOnly() throws {
        let reply = CommandResult(code: 1, output: Data((#"{"error":"Cannot access clipboard history.","ok":false}"# + "\n").utf8), error: Data(), command: "clip send")
        do { _ = try reply.decode(TransferRecord.self); Issue.record("an error reply decoded as a transfer") }
        catch { #expect(String(describing: error).contains("Cannot access clipboard history."), "\(error)") }
        let withRow = CommandResult(code: 1, output: Data(#"{"error":"Not sent.","ok":false,"transfer":{"device_id":"secret-device-id"}}"#.utf8), error: Data(), command: "clip send")
        do { _ = try withRow.decode([TransferRecord].self); Issue.record("decoded") }
        catch {
            #expect(String(describing: error).contains("Not sent."), "\(error)")
            #expect(!String(describing: error).contains("secret-device-id"), "\(error)")
        }
    }
}
