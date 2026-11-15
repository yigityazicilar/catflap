import CatflapCore
import Foundation
import Testing

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
}
