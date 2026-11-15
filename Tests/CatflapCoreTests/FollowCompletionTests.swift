import Foundation
import Synchronization
import Testing
@testable import CatflapCore

private struct FollowPlatformError: LocalizedError {
    var errorDescription: String? { "synthetic content must stay private" }
}
private struct FailingFollowPlatform: FollowPlatform {
    func writeClipboard(_ content: ClipboardContent, origin: ClipboardOrigin) async throws { throw FollowPlatformError() }
    func requestPermission(_ prompt: FollowPrompt) async {}
    func openURL(_ url: URL) async throws { throw FollowPlatformError() }
}

@Suite struct FollowCompletionTests {
    @Test func platformFailureInAnAnswerReturnsOnlyAFixedMessage() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let runtime = try AgentRuntime(paths: AgentPaths(directory: f.directory))
        let clipboard = ClipboardService(history: ClipboardHistory(store: f.store), transfers: f.service, store: f.store, directory: f.directory)
        let service = FollowService(store: f.store, transfers: f.service)
        await service.install(on: runtime, clipboard: clipboard)
        await service.setPlatform(FailingFollowPlatform())
        try await service.received(deviceID: "peer", id: "link", content: .text("https://example.org/"), keep: false, intent: "open")
        let prompt = try #require(await service.prompts().first)
        let response = await runtime.handle(.init("follow.answer", arguments: ["id": prompt.id, "allow": "true"]))
        #expect(!response.ok)
        #expect(response.error == "The desktop action could not be completed.")
        #expect(!String(decoding: response.payload, as: UTF8.self).contains("synthetic content"))
        await service.stop()
    }
    @Test func resettingPermissionToUnsetAsksAgainForALaterCopy() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let platform = FollowPlatformDouble()
        let service = FollowService(store: f.store, transfers: f.service)
        await service.setPlatform(platform)
        try await service.received(deviceID: "peer", id: "first", content: .text("first note"), keep: false, intent: "follow")
        let first = try #require(await service.prompts().first)
        try await service.answer(id: first.id, allow: false)
        try await service.setPermission(.unset, deviceID: "peer")
        try await service.received(deviceID: "peer", id: "later", content: .text("later note"), keep: false, intent: "follow")
        #expect(await platform.prompts.count == 2)
        #expect(await platform.prompts.last?.id != first.id)
        #expect(await platform.writes.isEmpty)
        await service.stop()
    }

    @Test func replacedOpenQuestionShowsCurrentNormalizedURLAndRejectsOldAnswer() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let platform = FollowPlatformDouble(), clock = TestClock()
        let service = FollowService(store: f.store, transfers: f.service, clock: clock)
        await service.setPlatform(platform)
        try await service.received(deviceID: "peer", id: "first", content: .text("HTTPS://EXAMPLE.ORG:443/old\n"), keep: false, intent: "open")
        let old = try #require(await service.prompts().first)
        try await service.received(deviceID: "peer", id: "new", content: .text("HTTP://EXAMPLE.ORG:80/current\n"), keep: false, intent: "open")
        let current = try #require(await service.prompts().first)
        #expect(current.id != old.id)
        #expect(current.url == "http://example.org/current")
        #expect(await platform.prompts.last?.url == current.url)
        await #expect(throws: ClipboardFailure.missing) { try await service.answer(id: old.id, allow: true) }
        #expect(await platform.opens.isEmpty)
        try await service.answer(id: current.id, allow: true)
        #expect(await platform.opens.map(\.absoluteString) == ["http://example.org/current"])
        try await service.received(deviceID: "peer", id: "expired", content: .text("https://example.org/expired"), keep: false, intent: "open")
        let expired = try #require(await service.prompts().first)
        clock.advance(601)
        await #expect(throws: ClipboardFailure.missing) { try await service.answer(id: expired.id, allow: true) }
        #expect(await platform.opens.count == 1)
        await service.stop()
    }

    @Test func originKeepRoundTripsThroughEncodingStoragePreviewsAndExplicitKeep() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let forwarded = Mutex(0)
        await f.history.setRecordedHandler { _, _, _ in forwarded.withLock { $0 += 1 } }
        let encoded = try JSONEncoder().encode(ClipboardOrigin(deviceID: "peer", keep: true))
        let origin = try JSONDecoder().decode(ClipboardOrigin.self, from: encoded)
        #expect(origin.deviceID == "peer" && origin.keep)
        let captured = try await f.history.ingest(offeredTypes: [ClipboardOrigin.macType], origin: origin) { .text("ordinary followed note") }
        let id = try #require(captured.id)
        #expect(captured.followedFrom == "peer")
        let reopened = try await ClipboardHistory.open(store: f.store)
        #expect(try await reopened.item(id: id).followedFrom == "peer")
        #expect(try await reopened.previews().first?.followedFrom == "peer")
        let secret = "gh" + "p_" + String(repeating: "q", count: 36)
        let filtered = try await f.history.ingest(offeredTypes: [ClipboardOrigin.linuxType], origin: origin) { .text(secret) }
        #expect(filtered.status == "filtered" && filtered.canKeep)
        let kept = try await f.history.keep(id: #require(filtered.id))
        #expect(kept.followedFrom == "peer")
        let item = try await f.history.item(id: #require(kept.id))
        #expect(item.kept && item.followedFrom == "peer")
        #expect(forwarded.withLock { $0 } == 0)
    }

    @Test func dontKeepOriginRoundTripNeverStoresOrOffersKeepOrForwards() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let forwarded = Mutex(0)
        await f.history.setRecordedHandler { _, _, _ in forwarded.withLock { $0 += 1 } }
        let encoded = try JSONEncoder().encode(ClipboardOrigin(deviceID: "peer", keep: false))
        let origin = try JSONDecoder().decode(ClipboardOrigin.self, from: encoded)
        #expect(origin.deviceID == "peer" && !origin.keep)
        let result = try await f.history.ingest(offeredTypes: [ClipboardOrigin.linuxType], origin: origin) { .text("memory only followed note") }
        #expect(result.status == "followed" && result.followedFrom == "peer" && result.id == nil && !result.canKeep)
        #expect(try await f.history.items().isEmpty)
        #expect(try await f.store.query("SELECT * FROM clipboard_origins").isEmpty)
        await #expect(throws: ClipboardFailure.latestFollowedNotKept) { try await f.history.latestItem(wait: .zero) }
        await #expect(throws: ClipboardFailure.noPending) { try await f.history.keep(id: "missing") }
        // An undecodable origin still suppresses forwarding, including explicit Keep.
        let filtered = try await f.history.ingest(offeredTypes: [ClipboardOrigin.macType]) { .text("gh" + "p_" + String(repeating: "q", count: 36)) }
        _ = try await f.history.keep(id: #require(filtered.id))
        #expect(forwarded.withLock { $0 } == 0)
    }
}
