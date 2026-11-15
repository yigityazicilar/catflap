import CatflapCore
import Foundation
import Testing

/// The image kind and the intent fields that core-follow acts on later.
@Suite struct TransferKindTests {
    static let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(repeating: 0, count: 24)

    static func imageInput(id: String, keep: Bool, bytes: Data = png, mime: String = "image/png") throws -> Data {
        var input = try offerFrame(id: id, kind: "image", name: "Clipboard image", size: Int64(bytes.count), mime: mime, keep: keep, sha256: transferHash(bytes))
        input.append(bytes)
        input.append(try WireCodec.frame(TransferDone(sha256: transferHash(bytes))))
        return input
    }

    @Test func testKeptImageLandsWithTheExtensionFromItsMime() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let script = TransferScript(try Self.imageInput(id: "img", keep: true))
        await f.service.receive(deviceID: "peer", connection: WireConnection(script))
        #expect(try await script.frames().map(\.type) == ["accept", "ack"])
        let row = try #require(try await f.service.history.rows().first)
        #expect(row.kind == "image" && row.mime == "image/png" && row.status == "ok")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path) == ["Clipboard image.png"])
    }

    @Test func testDontKeepImageIsHeldInMemoryOnly() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(try Self.imageInput(id: "mem", keep: false))))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).isEmpty)
        let copy = try #require(try await f.service.copyImage(deviceID: "peer", id: "mem"))
        #expect(copy.data == Self.png && copy.mime == "image/png")
        #expect(try await f.service.copyImage(deviceID: "peer", id: "mem", now: Date().addingTimeInterval(11 * 60)) == nil)
        let restarted = TransferService(store: try Store(paths: AgentPaths(directory: f.directory)), inbox: f.inbox)
        #expect(try await restarted.copyImage(deviceID: "peer", id: "mem") == nil)
    }

    @Test func testImageWhoseBytesDoNotMatchItsMimeIsRefused() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let script = TransferScript(try Self.imageInput(id: "fake", keep: true, bytes: Data("not an image at all".utf8)))
        await f.service.receive(deviceID: "peer", connection: WireConnection(script))
        let frames = try await script.frames()
        #expect(frames.map(\.type) == ["accept", "reject"])
        #expect(try frames.last?.decode(TransferReject.self).reason == .invalid)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).isEmpty)
    }

    @Test func testIntentFieldsTravelAndAreRecordedWithoutBehaviour() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        for (id, intent, clip) in [("follow", "follow", Optional("url")), ("open", "open", nil)] {
            let body = Data("https://example.org/".utf8)
            var input = try WireCodec.frame(TransferOffer(id: id, kind: "text", name: "text", size: Int64(body.count), mime: "text/plain",
                                                         sha256: transferHash(body), intent: intent, clipKind: clip))
            input.append(body); input.append(try WireCodec.frame(TransferDone(sha256: transferHash(body))))
            await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(input)))
            let row = try #require(try await f.service.history.record(deviceID: "peer", id: id))
            #expect(row.intent == intent && row.clipKind == clip && row.status == "ok")
            let json = try String(decoding: JSONEncoder().encode(row), as: UTF8.self)
            #expect(json.contains("\"intent\":\"\(intent)\""))
        }
    }
}
