import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite struct InboxTests {
    @Test func testTraversalFilenameStaysInsideInbox() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let names = ["../../.ssh/authorized_keys", "/absolute/file", "..\\..\\escape", String(repeating: "x", count: 300), ".", "..", "a\u{0}b"]
        for (index, name) in names.enumerated() {
            await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(try transferInput(id: String(index), name: name))))
        }
        let rows = try await f.service.history.rows()
        #expect(rows.count == names.count)
        for row in rows {
            #expect(row.status == "ok")
            let path = URL(fileURLWithPath: try #require(row.path))
            #expect(path.deletingLastPathComponent().path == f.inbox.directory.path)
            #expect(path.lastPathComponent.utf8.count <= 200)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).contains("escape") == false)
    }
    @Test func testNameCollisionGetsANumberedSuffix() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        try Data("original".utf8).write(to: f.inbox.url("sample.bin"))
        await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(try transferInput())))
        #expect(try String(contentsOf: f.inbox.url("sample.bin"), encoding: .utf8) == "original")
        #expect(try await f.service.history.rows().first?.targetName == "sample (1).bin")
        #expect(try Data(contentsOf: f.inbox.url("sample (1).bin")) == Data("payload".utf8))
        let name = "symlink.bin"
        try FileManager.default.createSymbolicLink(at: f.inbox.url(name), withDestinationURL: f.inbox.url("sample.bin"))
        #expect(f.inbox.availableName(name) == "symlink (1).bin")
    }
    @Test func testNewInboxAppliesToTheNextTransferWithoutRestart() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let chosen = f.directory.appendingPathComponent("chosen")
        // What a panel does when the person picks another folder: it writes the setting.
        try await f.store.setSetting("inbox", value: chosen.path)
        await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(try transferInput(id: "next", name: "next.bin"))))
        let row = try #require(try await f.service.history.rows().first)
        #expect(row.status == "ok")
        let landed = URL(fileURLWithPath: try #require(row.path))
        #expect(landed.deletingLastPathComponent().resolvingSymlinksInPath().path == chosen.resolvingSymlinksInPath().path)
        #expect(try Data(contentsOf: chosen.appendingPathComponent("next.bin")) == Data("payload".utf8))
        #expect(try !FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).contains("next.bin"))
    }
    @Test func testTransferUnderWayFinishesInTheInboxItStarted() async throws {
        let p = try await LoopbackPair(); defer { p.cleanup() }
        let file = p.sender.directory.appendingPathComponent("long.bin")
        let bytes = Data((0..<65536).map { UInt8($0 % 239) })
        try bytes.write(to: file)
        p.connector.failNext(.cutAfterPayload(20000))
        let id = try await p.senderService.start(deviceID: LoopbackPair.receiverID, payload: .file(file)).id
        #expect(try await waitUntil { try await p.received().first?.status == "interrupted" })
        #expect(try await waitUntil { try await p.row(id)?.status == "failed" })
        // The person picks another inbox while the part waits.
        let chosen = p.receiver.directory.appendingPathComponent("chosen")
        try await p.receiver.store.setSetting("inbox", value: chosen.path)
        _ = try await p.senderService.retry(deviceID: LoopbackPair.receiverID, id: id)
        #expect(try await waitUntil { try await p.row(id)?.status == "ok" })
        #expect(p.connector.links.last?.payloadBytes == Int64(bytes.count) - 20000)
        #expect(try Data(contentsOf: p.receiver.inbox.url("long.bin")) == bytes)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: chosen.path))?.contains("long.bin") != true)
    }
    @Test func testExistingInboxKeepsItsModeAndAnUnsafeOneIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-mode-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // A folder the person already has, such as Downloads, keeps the mode it has.
        let shared = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        #expect(chmod(shared.path, 0o755) == 0)
        _ = try TransferInbox(directory: shared)
        #expect(try posixMode(shared) == 0o755)
        // One others can write into is refused, and left as it is.
        let open = root.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        #expect(chmod(open.path, 0o777) == 0)
        #expect(throws: (any Error).self) { _ = try TransferInbox(directory: open) }
        #expect(try posixMode(open) == 0o777)
        // A folder Catflap makes itself is private.
        let made = root.appendingPathComponent("made")
        _ = try TransferInbox(directory: made)
        #expect(try posixMode(made) == 0o700)
    }
}
