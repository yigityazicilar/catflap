import CatflapCore
import Foundation
import Testing

@Suite struct ReviewMKInbox {
    @Test func testLongCollisionStillHasAValidDestination() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("review-inbox-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox=try TransferInbox(directory:root)
        let long=String(repeating:"a",count:180)
        try Data("first".utf8).write(to:inbox.url(long))
        let chosen=inbox.availableName(long)
        let valid=(try? inbox.url(chosen)) != nil
        print("REVIEW long filename collision: bytes=\(chosen.utf8.count) destinationAccepted=\(valid)")
        #expect(valid,"A colliding cleaned filename must still be accepted by the inbox")
    }
}
