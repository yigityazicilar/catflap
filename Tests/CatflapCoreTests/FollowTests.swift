import Foundation
import Synchronization
import Testing
@testable import CatflapCore

actor FollowPlatformDouble: FollowPlatform {
    var writes: [ClipboardOrigin] = []
    var prompts: [FollowPrompt] = []
    var opens: [URL] = []
    func writeClipboard(_ content: ClipboardContent, origin: ClipboardOrigin) async throws { writes.append(origin) }
    func requestPermission(_ prompt: FollowPrompt) async { prompts.append(prompt) }
    func openURL(_ url: URL) async throws { opens.append(url) }
}
@Suite struct FollowTests {
    @Test func unsetHoldsNewestOnceAllowedWritesAndRefusedNeverWrites() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let clock = TestClock(), platform = FollowPlatformDouble()
        let service = FollowService(store: f.store, transfers: f.service, clock: clock)
        await service.setPlatform(platform)
        try await service.received(deviceID: "peer", id: "one", content: .text("first note"), keep: false, intent: "follow")
        try await service.received(deviceID: "peer", id: "two", content: .text("new note"), keep: false, intent: "follow")
        #expect(await platform.prompts.count == 1)
        #expect(await platform.writes.isEmpty)
        #expect(try await f.store.query("SELECT * FROM clipboard").isEmpty)
        try await service.setPermission(.allowed, deviceID: "peer")
        #expect(await platform.writes.count == 1)
        #expect(await platform.writes.first?.keep == false)
        try await service.setPermission(.refused, deviceID: "peer")
        try await service.received(deviceID: "peer", id: "three", content: .text("refused note"), keep: true, intent: "follow")
        #expect(await platform.writes.count == 1)
    }
    @Test func expiredPendingAndRefusedURLNeverReachHooks() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let clock = TestClock(), platform = FollowPlatformDouble()
        let service = FollowService(store: f.store, transfers: f.service, clock: clock)
        await service.setPlatform(platform)
        try await service.received(deviceID: "peer", id: "old", content: .text("expired note"), keep: false, intent: "follow")
        clock.advance(601)
        try await service.setPermission(.allowed, deviceID: "peer")
        #expect(await platform.writes.isEmpty)
        try await service.received(deviceID: "peer", id: "link", content: .text("https://example.org/"), keep: false, intent: "open")
        #expect(await platform.opens.isEmpty)
        let prompt = try #require(await platform.prompts.last)
        try await service.answer(id: prompt.id, allow: false)
        #expect(await platform.opens.isEmpty)
        await #expect(throws: (any Error).self) {
            try await service.received(deviceID: "peer", id: "bad", content: .text("file:///etc/passwd"), keep: true, intent: "open")
        }
        #expect(await platform.opens.isEmpty)
        try await service.setOpenPolicy(.always, deviceID: "peer")
        try await service.received(deviceID: "peer", id: "good", content: .text("HTTPS://EXAMPLE.ORG/path"), keep: false, intent: "open")
        #expect(await platform.opens.first?.absoluteString == "https://example.org/path")
    }
    @Test func originMarkedCopyIsRecordedButNeverForwardedEvenToThirdDevice() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let count = Mutex(0)
        await f.history.setRecordedHandler { _, _, _ in count.withLock { $0 += 1 } }
        let marker = ClipboardOrigin(deviceID: "peer", keep: true)
        let result = try await f.history.ingest(offeredTypes: [ClipboardOrigin.linuxType], origin: marker) { .text("followed note") }
        #expect(result.status == "stored")
        #expect(result.followedFrom == "peer")
        #expect(count.withLock { $0 } == 0)
        _ = try await f.history.ingest(offeredTypes: []) { .text("local note") }
        #expect(count.withLock { $0 } == 1)
        // A forged/unknown origin still blocks forwarding. It is not a security permission.
        _ = try await f.history.ingest(offeredTypes: [ClipboardOrigin.macType]) { .text("unknown origin") }
        #expect(count.withLock { $0 } == 1)
    }
    @Test func unsetTransferBodyIsMemoryOnlyUntilPermissionAnswer() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let runtime = try AgentRuntime(paths: AgentPaths(directory: f.directory))
        let history = ClipboardHistory(store: f.store)
        let clipboard = ClipboardService(history: history, transfers: f.service, store: f.store, directory: f.directory)
        let service = FollowService(store: f.store, transfers: f.service)
        await service.install(on: runtime, clipboard: clipboard)
        let body = Data("unique held follow note".utf8)
        var input = try WireCodec.frame(TransferOffer(id: "held", kind: "text", name: "text", size: Int64(body.count), mime: "text/plain", keep: true, sha256: transferHash(body), intent: "follow", clipKind: "text"))
        input.append(body); input.append(try WireCodec.frame(TransferDone(sha256: transferHash(body))))
        await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(input)))
        #expect(try await f.service.history.record(deviceID: "peer", id: "held")?.text == nil)
        for name in ["store.sqlite", "store.sqlite-wal"] {
            let bytes = try Data(contentsOf: f.directory.appendingPathComponent(name))
            #expect(bytes.range(of: body) == nil)
        }
        try await service.setPermission(.refused, deviceID: "peer")
        #expect(try await f.service.history.record(deviceID: "peer", id: "held")?.text == String(decoding: body, as: UTF8.self))
        await service.stop()
    }
    @Test func oneTrailingNewlineIsNormalizedButEmbeddedWhitespaceIsNot() {
        #expect(LinkNormalizer.normalize("https://example.org/\n")?.absoluteString == "https://example.org/")
        #expect(LinkNormalizer.normalize("https://example.org/\n\n") == nil)
    }
    @Test func onlySingleHTTPURLsAreOpenable() {
        for text in ["file:///etc/passwd", "javascript:alert(1)", "https://a.org https://b.org", "https://a.org/\n\n", "https://a.org/\u{0}", "https://a.org/%0a", "https:///path", "https://a.org/" + String(repeating: "a", count: 8192)] {
            #expect(LinkNormalizer.normalize(text) == nil)
        }
        #expect(LinkNormalizer.normalize("HTTPS://EXAMPLE.ORG:443/a")?.absoluteString == "https://example.org/a")
    }
    @Test func syntheticUserinfoURLFixtureIsNeverOpenable() throws {
        // This hostile synthetic URL resembles an email address. Keep it with ordinary
        // fixture data rather than teaching the publication scanner an exception.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/secret-filter/hostile-url-userinfo.txt"), encoding: .utf8)
        #expect(LinkNormalizer.normalize(text) == nil)
    }
}
