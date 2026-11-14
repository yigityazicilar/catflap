import CatflapCore
import Crypto
import Foundation
import Testing

actor TransferScript: WireTransport {
    var input: Data
    var output = Data()
    let stall: Bool
    init(_ input: Data, stall: Bool = false) { self.input = input; self.stall = stall }
    func read(upTo maxLength: Int, timeout: Duration?) async throws -> Data? {
        if !input.isEmpty { let chunk = Data(input.prefix(maxLength)); input.removeFirst(chunk.count); return chunk }
        if stall { try await Task.sleep(for: timeout ?? .seconds(1)); throw WireError.timedOut }
        return nil
    }
    func write(_ data: Data, timeout: Duration?) { output.append(data) }
    func closeWrite(timeout: Duration?) {}
    func close() {}
    func frames() throws -> [WireFrame] {
        var decoder = FrameDecoder(); decoder.append(output); var frames: [WireFrame] = []
        while let frame = try decoder.next() { frames.append(frame) }
        return frames
    }
}

struct TransferFixture: Sendable {
    let directory: URL
    let store: Store
    let inbox: TransferInbox
    let service: TransferService
    init(limits: TransferLimits = .init()) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-" + UUID().uuidString)
        store = try Store(paths: AgentPaths(directory: directory))
        inbox = try TransferInbox(directory: directory.appendingPathComponent("inbox"))
        service = TransferService(store: store, inbox: inbox, limits: limits)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
func transferHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func transferInput(id: String = "sample", name: String = "sample.bin", kind: String = "file", keep: Bool = true, payload: Data = Data("payload".utf8), complete: Bool = true) throws -> Data {
    var input = try WireCodec.frame(TransferOffer(id: id, kind: kind, name: name, size: Int64(payload.count), mime: "application/octet-stream", keep: keep))
    input.append(payload)
    if complete { input.append(try WireCodec.frame(TransferDone(sha256: transferHash(payload)))) }
    return input
}

@Suite struct TransferTests {
    @Test func testDropMidTransferLeavesNoPartialFile() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        var input = try WireCodec.frame(TransferOffer(id: "drop", kind: "file", name: "drop.bin", size: 100, mime: "application/octet-stream"))
        input.append(Data([1, 2, 3]))
        await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(input)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).isEmpty)
        #expect(try await f.service.history.rows().first?.status == "failed")
    }
    @Test func testCrashAtEachCommitPointReconcilesAtStartup() async throws {
        for point in TransferCommitPoint.allCases {
            let f = try TransferFixture(); defer { f.cleanup() }
            await f.service.configure(crashAt: point)
            await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(try transferInput())))
            let restarted = TransferService(store: try Store(paths: AgentPaths(directory: f.directory)), inbox: f.inbox)
            try await restarted.reconcile()
            let row = try #require(try await restarted.history.rows().first)
            let published = point == .renamed || point == .committed
            #expect(row.status == (published ? "ok" : "failed"))
            #expect(!FileManager.default.fileExists(atPath: try f.inbox.part(row.targetName!).path))
            if published { #expect(try TransferInbox.hash(f.inbox.url(row.targetName!)) == transferHash(Data("payload".utf8))) }
        }
    }
    @Test func testDuplicateDuringAckDrainIsStillDuplicate() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let first = TransferScript(try transferInput(), stall: true)
        let draining = Task { await f.service.receive(deviceID: "peer", connection: WireConnection(first)) }
        #expect(try await waitUntil { try await f.service.history.rows().first?.status == "ok" })
        let duplicate = TransferScript(try transferInput())
        await f.service.receive(deviceID: "peer", connection: WireConnection(duplicate))
        #expect(try await duplicate.frames().first?.decode(TransferReject.self).reason == .duplicate)
        await draining.value
        #expect(try await f.service.history.rows().count == 1)
    }
    @Test func testSameIdFromAnotherDeviceIsNotADuplicate() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        for peer in ["first", "second"] {
            let script = TransferScript(try transferInput())
            await f.service.receive(deviceID: peer, connection: WireConnection(script))
            #expect(try await script.frames().map(\.type) == ["accept", "ack"])
        }
        #expect(try await f.service.history.rows().count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).count == 2)
    }
    @Test func testOversizeOrNoSpaceOfferIsRejectedBeforePayload() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        for (kind, size) in [("text", Int64(4 * 1024 * 1024 + 1)), ("file", Int64(20 * 1024 * 1024 * 1024 + 1))] {
            let script = TransferScript(try WireCodec.frame(TransferOffer(id: kind, kind: kind, name: "large", size: size, mime: "data")))
            await f.service.receive(deviceID: "peer", connection: WireConnection(script))
            #expect(try await script.frames().first?.decode(TransferReject.self).reason == .tooLarge)
        }
        await f.service.configure(freeBytes: 1024 * 1024 * 1024)
        let script = TransferScript(try WireCodec.frame(TransferOffer(id: "space", kind: "file", name: "space", size: 1, mime: "data")))
        await f.service.receive(deviceID: "peer", connection: WireConnection(script))
        #expect(try await script.frames().first?.decode(TransferReject.self).reason == .noSpace)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).isEmpty)
    }
    @Test func testStalledStreamIsDropped() async throws {
        #expect(TransferLimits().idle == .seconds(30))
        var limits = TransferLimits(); limits.idle = .milliseconds(80)
        let f = try TransferFixture(limits: limits); defer { f.cleanup() }
        let script = TransferScript(try WireCodec.frame(TransferOffer(id: "stall", kind: "file", name: "stall", size: 1, mime: "data")), stall: true)
        let start = ContinuousClock.now
        await f.service.receive(deviceID: "peer", connection: WireConnection(script))
        // Far below the 30 s default, with room for a busy test machine.
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(try await f.service.history.rows().first?.status == "failed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).isEmpty)
    }
    @Test func testThirdConcurrentReceiveIsRefused() async throws {
        var limits = TransferLimits(); limits.idle = .milliseconds(500)
        let f = try TransferFixture(limits: limits); defer { f.cleanup() }
        func script(_ id: String) throws -> TransferScript { TransferScript(try WireCodec.frame(TransferOffer(id: id, kind: "file", name: id, size: 1, mime: "data")), stall: true) }
        let a = try script("a"), b = try script("b"), c = try script("c")
        let first = Task { await f.service.receive(deviceID: "peer", connection: WireConnection(a)) }
        let second = Task { await f.service.receive(deviceID: "peer", connection: WireConnection(b)) }
        let ready = try await waitUntil(timeout: .seconds(2)) {
            let firstCount = try await a.frames().count
            let secondCount = try await b.frames().count
            return firstCount == 1 && secondCount == 1
        }
        #expect(ready)
        await f.service.receive(deviceID: "peer", connection: WireConnection(c))
        #expect(try await c.frames().first?.decode(TransferReject.self).reason == .busy)
        await first.value; await second.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).isEmpty)
    }
    @Test func testIncompleteOfferRecordsNothing() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        for bytes in [Data(), Data([0, 0, 0, 30, 123])] {
            await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(bytes)))
        }
        #expect(try await f.service.history.rows().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).isEmpty)
    }
    @Test func testReceivedTextLeavesNoFileInTheInbox() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        let script = TransferScript(try transferInput(id: "note", name: "text", kind: "text", payload: Data("a short note".utf8)))
        await f.service.receive(deviceID: "peer", connection: WireConnection(script))
        #expect(try await script.frames().map(\.type) == ["accept", "ack"])
        let row = try #require(try await f.service.history.rows().first)
        #expect(row.status == "ok" && row.text == "a short note" && row.targetName == nil && row.path == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).isEmpty)
    }
    @Test func testOfferCannotChangeARowThisDeviceSent() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        var sent = TransferRecord(id: "mine", deviceID: "peer", direction: "sent", kind: "text", size: 4, status: "unconfirmed")
        sent.text = "mine"
        try await f.service.history.save(sent)
        let script = TransferScript(try transferInput(id: "mine", name: "text", kind: "text", payload: Data("theirs".utf8)))
        await f.service.receive(deviceID: "peer", connection: WireConnection(script))
        #expect(try await script.frames().isEmpty)
        let rows = try await f.service.history.rows()
        #expect(rows.count == 1 && rows.first?.direction == "sent" && rows.first?.status == "unconfirmed" && rows.first?.text == "mine")
    }
    @Test func testUnknownDeviceIsRefusedWithoutAHistoryRow() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        await #expect(throws: TransferFailure.self) { _ = try await f.service.start(deviceID: "nobody", payload: .text("x")) }
        #expect(try await f.service.history.rows().isEmpty)
    }
    @Test func testRefusedSendIsFailedNotUnconfirmed() async throws {
        try await withTestDevices { devices in
            let a = try await devices.make("first"), b = try await devices.make("second")
            try await linkDevices(a, b)
            var small = TransferLimits(); small.textBytes = 4
            let sender = TransferService(store: await a.runtime.store, inbox: try TransferInbox(directory: a.paths.directory.appendingPathComponent("inbox")), peers: a.peers)
            let receiver = TransferService(store: await b.runtime.store, inbox: try TransferInbox(directory: b.paths.directory.appendingPathComponent("inbox")), peers: b.peers, limits: small)
            try await sender.install(on: a.runtime); try await receiver.install(on: b.runtime)
            let id = try await sender.start(deviceID: b.id, payload: .text("more than four bytes")).id
            #expect(try await waitUntil { try await sender.status(deviceID: b.id, id: id)?.status == "failed" })
            let row = try #require(try await sender.status(deviceID: b.id, id: id))
            #expect(row.canRetry && row.error == "The other device refused it: too large.")
        }
    }
    @Test func testRetryAfterLostAckIsRecognisedAsDuplicate() async throws {
        try await withTestDevices { devices in
            let a = try await devices.make("first"), b = try await devices.make("second")
            try await linkDevices(a, b)
            let sender = TransferService(store: await a.runtime.store, inbox: try TransferInbox(directory: a.paths.directory.appendingPathComponent("inbox")), peers: a.peers)
            let receiver = TransferService(store: await b.runtime.store, inbox: try TransferInbox(directory: b.paths.directory.appendingPathComponent("inbox")), peers: b.peers)
            try await sender.install(on: a.runtime); try await receiver.install(on: b.runtime)
            await receiver.configure(dropAck: true)
            let id = try await sender.start(deviceID: b.id, payload: .text("lost acknowledgement")).id
            #expect(try await waitUntil { try await sender.status(deviceID: b.id, id: id)?.status == "unconfirmed" })
            #expect(try await sender.status(deviceID: b.id, id: id)?.canRetry == true)
            await receiver.configure()
            _ = try await sender.retry(deviceID: b.id, id: id)
            #expect(try await waitUntil { try await sender.status(deviceID: b.id, id: id)?.status == "ok" })
            #expect(try await receiver.history.rows().count == 1)
            #expect(try await a.runtime.store.devices().first?.lastSentAt != nil)
        }
    }
    @Test func testUnreachablePeerFailsWithinTimeoutAndCanRetry() async throws {
        try await withTestDevices { devices in
            let a = try await devices.make("first"), b = try await devices.make("second")
            try await linkDevices(a, b)
            await b.runtime.stop()
            var limits = TransferLimits(); limits.dial = .seconds(2)
            let sender = TransferService(store: await a.runtime.store, inbox: try TransferInbox(directory: a.paths.directory.appendingPathComponent("inbox")), peers: a.peers, limits: limits)
            let start = ContinuousClock.now
            let id = try await sender.start(deviceID: b.id, payload: .text("offline")).id
            #expect(try await waitUntil(timeout: .seconds(6)) { try await sender.status(deviceID: b.id, id: id)?.status == "failed" })
            #expect(ContinuousClock.now - start < .seconds(6))
            let row = try #require(try await sender.status(deviceID: b.id, id: id))
            #expect(row.canRetry && row.error?.contains("Cannot reach") == true)
            try await b.runtime.start()
            let receiver = TransferService(store: await b.runtime.store, inbox: try TransferInbox(directory: b.paths.directory.appendingPathComponent("inbox")), peers: b.peers)
            try await receiver.install(on: b.runtime)
            _ = try await sender.retry(deviceID: b.id, id: id)
            #expect(try await waitUntil { try await sender.status(deviceID: b.id, id: id)?.status == "ok" })
        }
    }
}
