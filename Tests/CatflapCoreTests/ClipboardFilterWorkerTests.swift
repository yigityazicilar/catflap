import Foundation
import Synchronization
import Testing
@testable import CatflapCore

@Suite struct ClipboardFilterWorkerTests {
    @Test func enablingTheFilterBeforeCommitCannotStoreAnUncheckedCopy() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        try await f.history.setFiltersSecrets(false)
        await f.history.setBeforeCommit { try? await f.store.setSetting("clipboard.filter_secrets", value: "true") }
        let secret = "gh" + "p_" + String(repeating: "q", count: 36)
        _ = try await f.history.ingest(offeredTypes: []) { .text(secret) }
        #expect(try await f.store.query("SELECT * FROM clipboard").isEmpty)
    }
    @Test func generationIsCheckedInsideTheCommitAfterTheVerdict() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let entered = AsyncSignal(), release = AsyncSignal()
        await f.history.setBeforeCommit { await entered.fire(); await release.wait() }
        let job = Task { try await f.history.ingest(offeredTypes: []) { .text("stale after verdict") } }
        await entered.wait()
        await f.history.noteChange()
        await release.fire()
        _ = try await job.value
        #expect(try await f.store.query("SELECT * FROM clipboard").isEmpty)
    }
    @Test func filterSettingDefaultsOnAndNeverDisablesMarkers() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        #expect(try await f.history.filtersSecrets())
        let secret = "gh" + "p_" + String(repeating: "q", count: 36)
        #expect(try await f.history.ingest(offeredTypes: []) { .text(secret) }.status == "filtered")
        try await f.history.setFiltersSecrets(false)
        #expect(try await f.history.ingest(offeredTypes: []) { .text(secret) }.status == "stored")
        let read = Mutex(false)
        let result = try await f.history.ingest(offeredTypes: ["x-kde-passwordManagerHint"]) {
            read.withLock { $0 = true }; return .text(secret)
        }
        #expect(result.status == "marked" && !result.canKeep && result.id == nil)
        #expect(!read.withLock { $0 })
        let reopened = try await ClipboardHistory.open(store: f.store)
        #expect(try await !reopened.filtersSecrets())
        try await reopened.setFiltersSecrets(true)
        #expect(try await reopened.ingest(offeredTypes: []) { .text(secret) }.status == "filtered")
    }
    @Test func workerHoldsOneActiveAndOnlyTheNewestPending() async throws {
        let started = AsyncSignal(), release = DispatchSemaphore(value: 0)
        let seen = Mutex<[String]>([])
        let worker = ClipboardFilterWorker { text in
            seen.withLock { $0.append(text) }
            if text == "first" { Task { await started.fire() }; release.wait() }
            return false
        }
        let first = Task { await worker.rejects("first") }
        await started.wait()
        let second = Task { await worker.rejects("second") }
        await worker.waitForPending()
        let third = Task { await worker.rejects("third") }
        #expect(await second.value == nil)
        release.signal()
        #expect(await first.value == false)
        #expect(await third.value == false)
        #expect(seen.withLock { $0 } == ["first", "third"])
    }
    @Test func slowFilterDoesNotBlockHistoryAndPauseOrNewCopyWins() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let entered = AsyncSignal(), release = DispatchSemaphore(value: 0)
        let worker = ClipboardFilterWorker { _ in Task { await entered.fire() }; release.wait(); return true }
        let history = ClipboardHistory(store: f.store, filterWorker: worker)
        let job = Task { try await history.ingest(offeredTypes: []) { .text("old copy") } }
        await entered.wait()
        #expect(try await history.items().isEmpty)
        await #expect(throws: ClipboardFailure.latestReading) { try await history.latestItem(wait: .zero) }
        await history.noteChange()
        try await history.setPaused(true)
        release.signal()
        #expect(try await job.value.status == "superseded")
        #expect(try await history.items().isEmpty)
        await #expect(throws: ClipboardFailure.noPending) { try await history.keep(id: "anything") }
    }
}
