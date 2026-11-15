import CatflapCore
import Foundation
import Synchronization
import Testing

/// Routes each device id to its own loopback receiver.
final class RoutingConnector: PeerConnector, @unchecked Sendable {
    let routes: [String: LoopbackConnector]
    init(_ routes: [String: LoopbackConnector]) { self.routes = routes }
    func link(deviceID: String, timeout: Duration) async throws -> PeerLink {
        guard let route = routes[deviceID] else { throw PeerError.refused(device: deviceID) }
        return try await route.link(deviceID: deviceID, timeout: timeout)
    }
    func ping(deviceID: String, timeout: Duration) async throws -> PeerPing {
        guard let route = routes[deviceID] else { throw PeerError.refused(device: deviceID) }
        return try await route.ping(deviceID: deviceID, timeout: timeout)
    }
}

/// Several targets (plan v4 feature 5): one send, one transfer per device, each with its own
/// outcome.
@Suite struct MultiTargetTests {
    struct Three: Sendable {
        let sender: TransferFixture, one: TransferFixture, two: TransferFixture
        let toOne: LoopbackConnector, toTwo: LoopbackConnector
        let service: TransferService
        let clock = TestClock()
        init() async throws {
            sender = try TransferFixture(); one = try TransferFixture(); two = try TransferFixture()
            toOne = LoopbackConnector(receiver: one.service, as: "sender")
            toTwo = LoopbackConnector(receiver: two.service, as: "sender", here: false)
            service = TransferService(store: sender.store, inbox: sender.inbox, connector: RoutingConnector(["one": toOne, "two": toTwo]), clock: clock)
            for (id, name) in [("one", "Device B"), ("two", "Device C")] {
                try await sender.store.saveDevice(DeviceRecord(id: id, name: name, clientPublicKey: "", address: "", pairSecret: Data(), build: "test"))
            }
        }
        func cleanup() { sender.cleanup(); one.cleanup(); two.cleanup() }
    }

    @Test func testOneSendToTwoDevicesGivesEachItsOwnTransferAndOutcome() async throws {
        let t = try await Three(); defer { t.cleanup() }
        let batch = try await t.service.send(SendRequest(deviceIDs: ["one", "two"], payloads: [.text("to both")]))
        #expect(batch.transfers.count == 2 && batch.refused.isEmpty)
        #expect(Set(batch.transfers.map(\.sendID)) == [batch.sendID])
        #expect(Set(batch.transfers.map(\.id)).count == 2)
        let byDevice = Dictionary(uniqueKeysWithValues: batch.transfers.map { ($0.deviceID, $0.id) })
        let one = try #require(byDevice["one"]), two = try #require(byDevice["two"])
        #expect(try await waitUntil { try await t.service.status(deviceID: "one", id: one)?.status == "ok" })
        #expect(try await waitUntil { try await t.service.status(deviceID: "two", id: two)?.status == "waiting" })
        #expect(try await t.one.service.history.rows().first?.text == "to both")
        t.toTwo.setHere(true); t.clock.advance(400)
        await t.service.runDueDeliveries()
        #expect(try await waitUntil { try await t.service.status(deviceID: "two", id: two)?.status == "ok" })
        #expect(try await t.two.service.history.rows().first?.text == "to both")
    }

    @Test func testAnUnknownDeviceInABatchIsRefusedAlone() async throws {
        let t = try await Three(); defer { t.cleanup() }
        let batch = try await t.service.send(SendRequest(deviceIDs: ["one", "nobody"], payloads: [.text("x")]))
        #expect(batch.transfers.map(\.deviceID) == ["one"])
        #expect(batch.refused.map(\.deviceID) == ["nobody"])
    }

    @Test func testCancellingASendCancelsEveryWaitingTransferOfIt() async throws {
        let t = try await Three(); defer { t.cleanup() }
        t.toOne.setHere(false)
        let batch = try await t.service.send(SendRequest(deviceIDs: ["one", "two"], payloads: [.text("never mind")]))
        for row in batch.transfers { #expect(try await waitUntil { try await t.service.status(deviceID: row.deviceID, id: row.id)?.status == "waiting" }) }
        let (cancelled, refused) = try await t.service.cancel(sendID: batch.sendID)
        #expect(cancelled.count == 2 && refused.isEmpty)
        #expect(try await t.sender.store.query("SELECT 1 FROM queue").isEmpty)
    }
}
