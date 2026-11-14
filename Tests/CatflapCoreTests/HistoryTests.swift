import CatflapCore
import Foundation
import Testing

@Suite struct HistoryTests {
    @Test func testDontKeepStoresNoContentOnEitherSide() async throws {
        try await withTestDevices { devices in
            let a = try await devices.make("first"), b = try await devices.make("second")
            try await linkDevices(a, b)
            let sender = TransferService(store: await a.runtime.store, inbox: try TransferInbox(directory: a.paths.directory.appendingPathComponent("inbox")), peers: a.peers)
            let receiverInbox = try TransferInbox(directory: b.paths.directory.appendingPathComponent("inbox"))
            let receiver = TransferService(store: await b.runtime.store, inbox: receiverInbox, peers: b.peers)
            try await sender.install(on: a.runtime); try await receiver.install(on: b.runtime)
            let content = "ephemeral-" + UUID().uuidString
            let id = try await sender.start(deviceID: b.id, payload: .text(content), keep: false).id
            #expect(try await waitUntil { try await sender.status(deviceID: b.id, id: id)?.status == "ok" })
            for history in [sender.history, receiver.history] {
                let row = try #require(try await history.rows().first)
                #expect(!row.keep && row.text == nil && row.path == nil)
                // A hash of a short text would let it be guessed, so that is not kept either.
                #expect(row.sha256 == nil && row.targetName == nil)
                let bytes = try ControlJSON.encoder.encode(row)
                #expect(!String(decoding: bytes, as: UTF8.self).contains(content))
            }
            #expect(try await receiver.copyText(deviceID: a.id, id: id) == content)
            #expect(try await receiver.copyText(deviceID: a.id, id: id, now: Date().addingTimeInterval(601)) == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: receiverInbox.directory.path).isEmpty)
            let restarted = TransferService(store: await b.runtime.store, inbox: receiverInbox)
            #expect(try await restarted.copyText(deviceID: a.id, id: id) == nil)
            // A file sent the same way still lands in the inbox; neither row names or describes it.
            let source = a.paths.directory.appendingPathComponent("private-notes.txt")
            try Data("file body".utf8).write(to: source)
            let fileID = try await sender.start(deviceID: b.id, payload: .file(source), keep: false).id
            #expect(try await waitUntil { try await sender.status(deviceID: b.id, id: fileID)?.status == "ok" })
            let sides = [(sender.history, await b.id), (receiver.history, await a.id)]
            for (history, device) in sides {
                let row = try #require(try await history.record(deviceID: device, id: fileID))
                #expect(row.status == "ok" && !row.keep && row.path == nil && row.sha256 == nil && row.targetName == nil)
                #expect(try await history.rows(search: "private-notes").isEmpty)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: receiverInbox.directory.path) == ["private-notes.txt"])
            #expect(try Data(contentsOf: receiverInbox.directory.appendingPathComponent("private-notes.txt")) == Data("file body".utf8))
            for device in [a, b] {
                for suffix in ["", "-wal"] {
                    let url = URL(fileURLWithPath: device.paths.database.path + suffix)
                    if FileManager.default.fileExists(atPath: url.path) { #expect(try Data(contentsOf: url).range(of: Data(content.utf8)) == nil) }
                }
            }
        }
    }
    @Test func testHistorySearchFindsSentAndReceived() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        for direction in ["sent", "received"] {
            var row = TransferRecord(id: direction, deviceID: "peer", direction: direction, kind: "text", size: 7, status: "ok")
            row.text = "Find this Needle"
            try await f.service.history.save(row)
        }
        let reopened = TransferHistory(store: try Store(paths: AgentPaths(directory: f.directory)))
        #expect(try await reopened.rows(search: "needle").map(\.direction).sorted() == ["received", "sent"])
        #expect(try await reopened.rows(search: "missing").isEmpty)
        let rows = try await reopened.rows()
        try checkTransferJSON(ControlJSON.encoder.encode(rows))
    }
    @Test func testTransferControlJSONUsesSnakeCaseAndISO8601() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let runtime = try AgentRuntime(paths: AgentPaths(directory: f.directory))
        defer { try? IdentityStore(paths: AgentPaths(directory: f.directory)).erase() }
        try await f.service.install(on: runtime)
        try await f.store.saveDevice(DeviceRecord(id: "peer", name: "peer", clientPublicKey: "", address: "", pairSecret: Data(), build: "test"))
        let row = try await f.service.start(deviceID: "peer", payload: .text("sample"))
        try checkTransferJSON(ControlJSON.encoder.encode(row))
        let reply = await runtime.handle(.init("history"))
        #expect(reply.ok)
        try checkTransferJSON(reply.payload)
    }
}
func checkTransferJSON(_ data: Data) throws {
    func walk(_ value: Any) {
        if let object = value as? [String: Any] {
            for (key, item) in object {
                #expect(key.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil)
                if key == "timestamp", let text = item as? String { #expect(text.range(of: "^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ$", options: .regularExpression) != nil) }
                walk(item)
            }
        } else if let array = value as? [Any] { array.forEach(walk) }
    }
    walk(try JSONSerialization.jsonObject(with: data))
}
