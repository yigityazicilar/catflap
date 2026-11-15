import CatflapCore
import Foundation
import Tailcat
import Testing

/// An agent runtime with transfers installed and no tunnel: for the control commands.
struct ControlFixture: Sendable {
    let paths: AgentPaths
    let runtime: AgentRuntime
    let service: TransferService
    init() async throws {
        paths = try storeTestPaths()
        runtime = try AgentRuntime(paths: paths)
        service = TransferService(store: await runtime.store, inbox: try TransferInbox(directory: paths.directory.appendingPathComponent("inbox")))
        try await service.install(on: runtime)
    }
    func cleanup() { removeStoreTestPaths(paths) }
    func handle(_ command: String, _ arguments: [String: String] = [:]) async -> ControlResponse {
        await runtime.handle(.init(command, arguments: arguments))
    }
}

@Suite struct TransferControlTests {
    @Test func testStatusReportsTheStoresSchemaVersion() async throws {
        let f = try await ControlFixture(); defer { f.cleanup() }
        let status = try await f.handle("status").decode(AgentStatus.self)
        #expect(status.schemaVersion == (try await f.runtime.store.schemaVersion()))
        #expect(status.schemaVersion == 3)
    }

    @Test func testTransferListSendsPreviewsNotBodies() async throws {
        let f = try await ControlFixture(); defer { f.cleanup() }
        // 300 kept texts of 64 KiB each: about 19 MiB of bodies.
        let body = String(repeating: "é", count: 32 * 1024)
        for index in 0..<300 {
            var row = TransferRecord(id: String(format: "row-%03d", index), deviceID: "peer", direction: index % 2 == 0 ? "sent" : "received",
                                     kind: "text", size: Int64(body.utf8.count), status: "ok")
            row.text = "\(index) " + body
            row.timestamp = Date(timeIntervalSince1970: 1_000_000 + Double(index))
            try await f.service.history.save(row)
        }
        let list = await f.handle("transfers.list")
        #expect(list.ok, "\(list.error ?? "")")
        #expect(list.payload.count < 1024 * 1024, "the list is \(list.payload.count) bytes")
        let object = try #require(try JSONSerialization.jsonObject(with: list.payload) as? [String: Any])
        let items = try #require(object["items"] as? [[String: Any]])
        #expect(items.count == 200)
        #expect(object["next_before"] is String)
        for item in items {
            #expect(item["text"] == nil)
            let preview = try #require(item["preview"] as? String)
            #expect(preview.count <= 200)
        }
        // Newest first; the next page starts where this one stopped.
        #expect(items.first?["id"] as? String == "row-299")
        let next = await f.handle("transfers.list", ["before": try #require(object["next_before"] as? String)])
        let nextItems = try #require((try JSONSerialization.jsonObject(with: next.payload) as? [String: Any])?["items"] as? [[String: Any]])
        #expect(nextItems.count == 100 && nextItems.first?["id"] as? String == "row-099")
        // One row, whole, on request.
        let whole = try await f.handle("transfers.get", ["device_id": "peer", "id": "row-007"]).decode(TransferRecord.self)
        #expect(whole.text == "7 " + body)
    }

    @Test func testDevicesCarryPresenceAndConfirmationButNoAddress() async throws {
        let f = try await ControlFixture(); defer { f.cleanup() }
        let address = "device-address-sentinel"
        try await f.runtime.store.saveDevice(DeviceRecord(id: "peer", name: "Device B", clientPublicKey: "client-key-sentinel", address: address,
                                                          pairSecret: Data(repeating: 9, count: 32), build: "0.1.0-dev"))
        let store = await f.runtime.store
        let presence = PresenceService(devices: { try await store.devices() }, ping: { _, _ in TailcatPing(latency: 0.041, path: .relayed(regionID: 4, regionCode: "fra")) })
        await presence.install(on: f.runtime)
        _ = try await presence.presence(refresh: true)
        await presence.waitForChecks()
        let reply = await f.handle("devices")
        #expect(reply.ok)
        let rows = try #require(try JSONSerialization.jsonObject(with: reply.payload) as? [[String: Any]])
        let row = try #require(rows.first)
        #expect(row["id"] as? String == "peer" && row["name"] as? String == "Device B")
        #expect(row["peer_state"] as? String == "ok")
        #expect(row["confirmed"] as? Bool != nil)
        let shown = try #require(row["presence"] as? [String: Any])
        #expect(shown["state"] as? String == "here" && shown["path"] as? String == "relayed" && shown["relay_region_code"] as? String == "fra")
        let text = String(decoding: reply.payload, as: UTF8.self)
        #expect(!text.contains(address) && !text.contains("client-key-sentinel") && !text.contains("pair_secret"))
        // The panels' decoder still reads it.
        #expect(try reply.decode([DeviceSummary].self).map(\.id) == ["peer"])
        await presence.stop()
    }
}
