import CatflapCore
import Foundation
import Testing

@Suite struct FollowWireTests {
    @Test func followUsesClipboardLimitRatherThanTheLargerTransferLimit() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let script = TransferScript(try WireCodec.frame(TransferOffer(id: "big", kind: "image", name: "image", size: Int64(ClipboardHistory.imageLimit + 1), mime: "image/png", sha256: transferHash(Data()), intent: "follow", clipKind: "image")))
        await f.service.receive(deviceID: "peer", connection: WireConnection(script))
        let frames = try await script.frames()
        #expect(frames.first?.type == "reject")
        #expect((try? frames.first?.decode(TransferReject.self).reason) == .tooLarge)
    }
    @Test func invalidFollowKindsAndOpenSchemesNeverReachTheDesktop() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let runtime = try AgentRuntime(paths: AgentPaths(directory: f.directory))
        let clipboard = ClipboardService(history: ClipboardHistory(store: f.store), transfers: f.service, store: f.store, directory: f.directory)
        let follow = FollowService(store: f.store, transfers: f.service)
        let platform = FollowPlatformDouble()
        await follow.setPlatform(platform)
        await follow.install(on: runtime, clipboard: clipboard)
        try await follow.setOpenPolicy(.always, deviceID: "peer")
        for (id, kind, clip, intent, text) in [("file", "file", Optional("text"), "follow", ""), ("wrong", "text", Optional("image"), "follow", ""), ("open", "text", nil, "open", "file:///not-opened")] {
            let body = Data(text.utf8)
            var bytes = try WireCodec.frame(TransferOffer(id: id, kind: kind, name: "item", size: Int64(body.count), mime: "text/plain", sha256: transferHash(body), intent: intent, clipKind: clip))
            bytes.append(body); bytes.append(try WireCodec.frame(TransferDone(sha256: transferHash(body))))
            let script = TransferScript(bytes)
            await f.service.receive(deviceID: "peer", connection: WireConnection(script))
            #expect(try await script.frames().last?.type == "reject")
        }
        #expect(await platform.writes.isEmpty)
        #expect(await platform.opens.isEmpty)
        await follow.stop()
    }
    @Test func receivedURLsHaveOpenableListsWithoutBodiesIncludingDontKeep() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let body = Data(("https://example.org/" + String(repeating: "path", count: 100)).utf8)
        for keep in [true, false] {
            let id = keep ? "kept" : "memory"
            var input = try WireCodec.frame(TransferOffer(id: id, kind: "text", name: "text", size: Int64(body.count), mime: "text/plain", keep: keep, sha256: transferHash(body)))
            input.append(body); input.append(try WireCodec.frame(TransferDone(sha256: transferHash(body))))
            await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(input)))
            let row = try #require(try await f.service.status(deviceID: "peer", id: id))
            #expect(row.openable)
        }
        let items = try await f.service.list(.init()).items
        #expect(items.count == 2 && items.allSatisfy { $0.openable && $0.text == nil })
    }
}
