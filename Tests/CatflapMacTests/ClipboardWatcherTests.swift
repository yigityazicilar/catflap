#if os(macOS)
import AppKit
@testable import CatflapMac
import CatflapCore
import Foundation
import Testing

@MainActor
private final class ClipboardSpy: ClipboardSource {
    var changeCount = 0
    var types = ["public.utf8-plain-text"]
    var moveDuringTypes = false
    var offeredTypes: [String] {
        if moveDuringTypes { changeCount += 1 }
        return types
    }
    var passwordManagerFrontmost = false
    var access = "alwaysAllow"
    var reads = 0
    var unavailableReads = 0
    var value = ClipboardContent.text("a normal clipboard note")
    func content(type: String, kind: ClipboardKind, limit: Int) throws -> ClipboardContent {
        if unavailableReads > 0 { unavailableReads -= 1; throw ClipboardReadFailure.unavailable }
        reads += 1
        return value
    }
}

@MainActor
struct ClipboardWatcherTests {
    private func withWatcher(_ body: (ClipboardWatcher, ClipboardSpy, ClipboardHistory, AgentRuntime) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cw-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = try AgentPaths(directory: directory)
        defer {
            do { try IdentityStore(paths: paths).erase() }
            catch { Issue.record("Could not erase watcher test identity") }
        }
        let runtime = try AgentRuntime(paths: paths)
        let history = try await ClipboardHistory.open(store: runtime.store)
        let source = ClipboardSpy()
        let watcher = ClipboardWatcher(source: source, history: history, runtime: runtime)
        try await body(watcher, source, history, runtime)
    }
    @Test func testMarkersAndFrontmostManagerNeverRead() async throws {
        try await withWatcher { (watcher, source, history, _) async throws in
            for marker in SecretFilter.markers.union(["Pasteboard generator type"]) {
                source.types = ["public.utf8-plain-text", marker]
                source.changeCount += 1
                await watcher.poll()
            }
            source.types = ["public.utf8-plain-text"]
            source.passwordManagerFrontmost = true
            source.changeCount += 1
            await watcher.poll()
            #expect(source.reads == 0)
            #expect(try await history.items().isEmpty)
        }
    }
    @Test func testPausedCopyIsUnreadAndNotReplayed() async throws {
        try await withWatcher { (watcher, source, history, _) async throws in
            try await history.setPaused(true)
            source.changeCount += 1
            await watcher.poll()
            #expect(source.reads == 0)
            try await history.setPaused(false)
            await watcher.poll()
            #expect(source.reads == 0)
            source.changeCount += 1
            await watcher.poll()
            #expect(source.reads == 1)
            #expect(try await history.items().count == 1)
        }
    }
    /// A writer clears the pasteboard, which moves the change count, before it writes. A poll
    /// in between sees the new count with no types yet. On a CI runner that lost pbcopy's
    /// first copy for good: the change was marked as seen, and its types arrived later under
    /// the same count. It must be read once they arrive.
    @Test func testAChangeSeenBeforeItsTypesIsReadOnceTheyArrive() async throws {
        try await withWatcher { (watcher, source, history, _) async throws in
            source.types = []
            source.changeCount += 1
            await watcher.poll()
            #expect(source.reads == 0)
            source.types = ["public.utf8-plain-text"]
            await watcher.poll()
            #expect(source.reads == 1)
            #expect(try await history.items().count == 1)
        }
    }
    /// The same for a representation that is declared but not written yet.
    @Test func testARepresentationNotWrittenYetIsReadOnTheNextPoll() async throws {
        try await withWatcher { (watcher, source, history, _) async throws in
            source.unavailableReads = 1
            source.changeCount += 1
            await watcher.poll()
            #expect(source.reads == 0)
            await watcher.poll()
            #expect(source.reads == 1)
            #expect(try await history.items().count == 1)
        }
    }
    /// A copy is judged by the gates as they stood when its change was first seen, also when
    /// its types arrive later: one made while history was paused, or while a password manager
    /// was in front, is never read (found by a second reader).
    @Test func testAnEmptyChangeSeenWhilePausedIsNotReadAfterResume() async throws {
        try await withWatcher { (watcher, source, history, _) async throws in
            try await history.setPaused(true)
            source.types = []
            source.changeCount += 1
            await watcher.poll()
            try await history.setPaused(false)
            source.types = ["public.utf8-plain-text"]
            await watcher.poll()
            #expect(source.reads == 0)
            #expect(try await history.items().isEmpty)
        }
    }
    @Test func testAnEmptyChangeSeenWithAManagerInFrontIsNotReadAfterSwitching() async throws {
        try await withWatcher { (watcher, source, history, _) async throws in
            source.passwordManagerFrontmost = true
            source.types = []
            source.changeCount += 1
            await watcher.poll()
            source.passwordManagerFrontmost = false
            source.types = ["public.utf8-plain-text"]
            await watcher.poll()
            #expect(source.reads == 0)
            #expect(try await history.items().isEmpty)
        }
    }
    /// While a change waits for its types, `clip send --latest` must not send the copy before it.
    @Test func testLatestWaitsForAChangeStillWaitingForItsTypes() async throws {
        try await withWatcher { (watcher, source, history, _) async throws in
            source.changeCount += 1
            await watcher.poll()
            let first = try #require(try await history.items().first)
            source.types = []
            source.changeCount += 1
            await watcher.poll()
            await #expect(throws: ClipboardFailure.latestReading) { try await history.latestItem(wait: .milliseconds(50)) }
            source.types = ["public.utf8-plain-text"]
            source.value = .text("the copy whose types came late")
            await watcher.poll()
            let latest = try await history.latestItem()
            #expect(latest.id != first.id)
            #expect(latest.text == "the copy whose types came late")
        }
    }
    /// An app that only clears the pasteboard leaves a change that never gets types. It is
    /// let go after the settle window, and the next copy is read as usual.
    @Test func testAChangeThatStaysEmptyIsLetGo() async throws {
        try await withWatcher { (watcher, source, history, _) async throws in
            watcher.settleWindow = .zero
            source.types = []
            source.changeCount += 1
            await watcher.poll()
            await watcher.poll()
            await watcher.poll()
            #expect(source.reads == 0)
            source.types = ["public.utf8-plain-text"]
            source.changeCount += 1
            await watcher.poll()
            #expect(source.reads == 1)
            #expect(try await history.items().count == 1)
        }
    }
    @Test func testChangedTypeSnapshotIsNotRead() async throws {
        try await withWatcher { (watcher, source, history, _) async throws in
            source.moveDuringTypes = true
            source.changeCount += 1
            await watcher.poll()
            #expect(source.reads == 0)
            #expect(try await history.items().isEmpty)
        }
    }
    @Test func testDeniedAccessStatusAndAllowedKinds() async throws {
        try await withWatcher { (watcher, source, history, runtime) async throws in
            source.access = "alwaysDeny"
            await watcher.reportStatus()
            #expect(await runtime.platformStatus().pasteboardAccess == "alwaysDeny")
            #expect(await runtime.platformStatus().clipboardCapture == "failed")
            source.access = "alwaysAllow"
            for value in [
                ClipboardContent.text("a normal clipboard note"),
                ClipboardContent(kind: .url, data: Data("https://example.com/notes".utf8)),
                ClipboardContent(kind: .files, data: Data("file:///example/note.txt\nfile:///example/other.txt".utf8)),
                ClipboardContent(kind: .image, data: Data([137, 80, 78, 71]), mime: "image/png")
            ] {
                source.value = value
                source.types = [value.kind == .text ? "public.utf8-plain-text" : value.kind == .url ? "public.url" : value.kind == .files ? "public.file-url" : "public.png"]
                source.changeCount += 1
                await watcher.poll()
            }
            #expect(try await history.items().count == 4)
            #expect(await runtime.platformStatus().clipboardCapture == "active")
            source.value = .text(String(repeating: "x", count: ClipboardHistory.textLimit + 1))
            source.types = ["public.utf8-plain-text"]
            source.changeCount += 1
            await watcher.poll()
            #expect(try await history.items().count == 4)
        }
    }
    @Test func testSystemSourceBoundsRepresentationsAndFileReferences() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let source = SystemClipboardSource(board: board)
        board.setString(String(repeating: "x", count: 100), forType: .string)
        #expect(throws: ClipboardReadFailure.self) {
            try source.content(type: "public.utf8-plain-text", kind: .text, limit: 10)
        }
        board.clearContents()
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setString("file:///example/first.txt", forType: .fileURL)
        second.setString("file:///example/second.txt", forType: .fileURL)
        #expect(board.writeObjects([first, second]))
        let value = try source.content(type: "public.file-url", kind: .files, limit: ClipboardHistory.textLimit)
        #expect(String(data: value.data, encoding: .utf8) == "file:///example/first.txt\nfile:///example/second.txt")
    }
}
#endif
