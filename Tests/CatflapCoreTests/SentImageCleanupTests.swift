import CatflapCore
import Foundation
import Testing

/// The private copy kept for an image sent with Keep lasts as long as a sent row names it,
/// and no longer than the clipboard's lifetime.
@Suite struct SentImageCleanupTests {
    @Test func testKeptCopiesGoWithTheirRowsAndExpire() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let service = ClipboardService(history: ClipboardHistory(store: f.store), transfers: f.service, store: f.store, directory: f.directory)
        _ = try AgentPaths(directory: service.sentImages)
        let named = service.sentImages.appendingPathComponent("named.png")
        let orphan = service.sentImages.appendingPathComponent("orphan.png")
        for file in [named, orphan] { try AgentPaths.writePrivate(Data([137, 80, 78, 71]), to: file) }
        var row = TransferRecord(id: "named", deviceID: "peer", direction: "sent", kind: "file", size: 4, status: "ok")
        row.path = named.path
        try await f.service.history.save(row)
        try await service.cleanOutbox()
        #expect(FileManager.default.fileExists(atPath: named.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path), "a copy no row names was kept")
        // Past the clipboard's lifetime the copy goes, and its row no longer names it.
        try await service.cleanOutbox(now: Date().addingTimeInterval(ClipboardHistory.lifetime + 60))
        #expect(!FileManager.default.fileExists(atPath: named.path))
        #expect(try await f.service.history.record(deviceID: "peer", id: "named")?.path == nil)
    }
}
