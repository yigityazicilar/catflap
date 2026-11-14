import CatflapCore
import Foundation
import Synchronization
import Testing

struct ClipboardFixture {
    let directory: URL
    let store: Store
    let history: ClipboardHistory
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-" + UUID().uuidString)
        store = try Store(paths: AgentPaths(directory: directory))
        history = ClipboardHistory(store: store)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
@Suite struct ClipboardHistoryTests {
    @Test func testMarkedItemNeverReachesTheStore() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let reads = Mutex(0)
        for marker in SecretFilter.markers {
            let result = try await f.history.ingest(offeredTypes: ["text/plain", marker]) {
                reads.withLock { $0 += 1 }; return .text("must not read")
            }
            #expect(result.status == "marked")
        }
        let frontmost = try await f.history.ingest(offeredTypes: ["text/plain"], passwordManagerFrontmost: true) {
            reads.withLock { $0 += 1 }; return .text("must not read")
        }
        #expect(frontmost.status == "marked")
        #expect(reads.withLock { $0 } == 0)
        #expect(try await f.store.query("SELECT * FROM clipboard").isEmpty)
    }
    @Test func testMarkedItemOffersNoKeep() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let filtered = try await f.history.ingest(offeredTypes: []) { .text("ghp_" + String(repeating: "a", count: 36)) }
        let marked = try await f.history.ingest(offeredTypes: ["x-kde-passwordManagerHint"]) { .text("unread") }
        #expect(!marked.canKeep && marked.id == nil)
        await #expect(throws: ClipboardFailure.noPending) { try await f.history.keep(id: filtered.id!) }
        await #expect(throws: ClipboardFailure.noPending) { try await f.history.keep(id: "marked") }
        #expect(try await f.history.items().isEmpty)
    }
    @Test func testKeepSavesExactlyThatItem() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let firstSecret = "ghp_" + String(repeating: "a", count: 36)
        let secondSecret = "ghp_" + String(repeating: "b", count: 36)
        let first = try await f.history.ingest(offeredTypes: []) { .text(firstSecret) }
        let second = try await f.history.ingest(offeredTypes: []) { .text(secondSecret) }
        #expect(second.canKeep && second.message == "Skipped, looks like a secret")
        #expect(try await f.history.items().isEmpty)
        for suffix in ["store.sqlite", "store.sqlite-wal"] {
            let bytes = try Data(contentsOf: f.directory.appendingPathComponent(suffix))
            #expect(bytes.range(of: Data(firstSecret.utf8)) == nil && bytes.range(of: Data(secondSecret.utf8)) == nil)
        }
        await #expect(throws: ClipboardFailure.noPending) { try await f.history.keep(id: first.id!) }
        let saved = try await f.history.keep(id: second.id!)
        #expect(saved.status == "stored")
        let items = try await f.history.items()
        #expect(items.count == 1 && items.first?.text == secondSecret && items.first?.kept == true)
        await #expect(throws: ClipboardFailure.noPending) { try await f.history.keep(id: second.id!) }
        let reopened = try await ClipboardHistory.open(store: f.store)
        #expect(try await reopened.items().count == 1)
    }
    @Test func testDuplicateBumpsTimestamp() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let old = Date().addingTimeInterval(-10)
        let first = try await f.history.ingest(offeredTypes: [], now: old) { .text("ordinary copy") }
        let second = try await f.history.ingest(offeredTypes: []) { .text("ordinary copy") }
        let items = try await f.history.items()
        #expect(first.id == second.id && items.count == 1)
        #expect(items[0].timestamp > old)
    }
    @Test func testRetentionCapsAtFiveHundred() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let now = Date()
        for i in 0..<505 {
            _ = try await f.history.ingest(offeredTypes: [], now: now.addingTimeInterval(Double(i))) { .text("ordinary item number \(i)") }
        }
        let items = try await f.history.items(now: now.addingTimeInterval(505))
        #expect(items.count == 500 && items.first?.text == "ordinary item number 504" && items.last?.text == "ordinary item number 5")
        #expect(try await f.history.items(now: now.addingTimeInterval(ClipboardHistory.lifetime + 506)).isEmpty)
    }
    @Test func testPausedIngestStoresNothing() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        try await f.history.setPaused(true)
        let reopened = try await ClipboardHistory.open(store: f.store)
        let reads = Mutex(0)
        let result = try await reopened.ingest(offeredTypes: []) { reads.withLock { $0 += 1 }; return .text("paused copy") }
        #expect(result.status == "paused" && reads.withLock { $0 } == 0)
        #expect(try await reopened.items().isEmpty)
        try await reopened.setPaused(false)
        #expect(try await reopened.ingest(offeredTypes: []) { .text("resumed copy") }.status == "stored")
    }
    /// `setPaused` writes the setting, then sets its flag. A copy that passed the flag check in
    /// between is still on its way to the store, and must not be written once the pause is.
    /// The setting is written here directly, while the copy is being read, which is that window.
    @Test func testACopyInFlightWhenThePauseIsWrittenIsNotStored() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let store = f.store
        let result = try await f.history.ingest(offeredTypes: []) {
            try await store.setSetting("clipboard_paused", value: "true")
            return .text("copied as the pause was written")
        }
        #expect(result.status == "paused")
        #expect(result.id == nil)
        #expect(try await f.history.items().isEmpty)
    }
    /// The same window for Keep: a pause written while Keep is on its way to the store wins.
    @Test func testKeepInFlightWhenThePauseIsWrittenIsNotStored() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#%")
        let filtered = try await f.history.ingest(offeredTypes: []) {
            .text(String((0..<40).map { _ in alphabet.randomElement()! }))
        }
        let id = try #require(filtered.id)
        try await f.store.setSetting("clipboard_paused", value: "true")
        let kept = try await f.history.keep(id: id)
        #expect(kept.status == "paused")
        #expect(try await f.history.items().isEmpty)
    }
    @Test func testOversizeItemIsSkipped() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let reads = Mutex(0)
        let declared = try await f.history.ingest(offeredTypes: ["image/png"], declaredSize: 500_000_000, kind: .image) {
            reads.withLock { $0 += 1 }; return .text("unread")
        }
        #expect(declared.status == "oversize" && reads.withLock { $0 } == 0)
        let image = ClipboardContent(kind: .image, data: Data(repeating: 0, count: ClipboardHistory.imageLimit + 1), mime: "image/png")
        #expect(try await f.history.ingest(offeredTypes: []) { image }.status == "oversize")
        let text = ClipboardContent.text(String(repeating: "a", count: ClipboardHistory.textLimit + 1))
        #expect(try await f.history.ingest(offeredTypes: []) { text }.status == "oversize")
        #expect(try await f.history.items().isEmpty)
    }
    @Test func testKindsSearchDeleteAndRestart() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        for content in [ClipboardContent.text("ordinary note"),
                        .init(kind: .url, data: Data("https://example.invalid/report".utf8), mime: "text/uri-list"),
                        .init(kind: .files, data: Data("file:///report.txt\nfile:///photo.png".utf8), mime: "text/uri-list"),
                        .init(kind: .image, data: Data([137,80,78,71]), mime: "image/png")] {
            #expect(try await f.history.ingest(offeredTypes: []) { content }.status == "stored")
        }
        let reopened = try await ClipboardHistory.open(store: f.store)
        #expect(Set(try await reopened.items().map(\.kind.rawValue)) == Set(["text", "url", "files", "image"]))
        let found = try await reopened.items(search: "NOTE")
        #expect(found.count == 1)
        try await reopened.delete(id: found[0].id)
        #expect(try await reopened.items().count == 3)
    }
}
