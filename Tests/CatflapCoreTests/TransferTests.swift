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
/// An offer frame as a sender writes it. `sha256` is the content digest the offer commits to.
func offerFrame(id: String, kind: String = "file", name: String, size: Int64, mime: String = "application/octet-stream",
                keep: Bool = true, sha256: String = String(repeating: "0", count: 64)) throws -> Data {
    try WireCodec.frame(TransferOffer(id: id, kind: kind, name: name, size: size, mime: mime, keep: keep, sha256: sha256))
}
func transferInput(id: String = "sample", name: String = "sample.bin", kind: String = "file", keep: Bool = true, payload: Data = Data("payload".utf8), complete: Bool = true) throws -> Data {
    var input = try offerFrame(id: id, kind: kind, name: name, size: Int64(payload.count), keep: keep, sha256: transferHash(payload))
    input.append(payload)
    if complete { input.append(try WireCodec.frame(TransferDone(sha256: transferHash(payload)))) }
    return input
}
/// A part file's hidden name: `.catflap-` and 32 hex digits of its recovery id.
func isRecoveryPart(_ name: String) -> Bool {
    guard name.hasPrefix(".catflap-"), name.hasSuffix(".part") else { return false }
    let id = name.dropFirst(".catflap-".count).dropLast(".part".count)
    return id.count == 32 && id.allSatisfy { $0.isHexDigit }
}
func posixMode(_ url: URL) throws -> Int {
    try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
}

@Suite struct TransferTests {
    @Test func testDropMidTransferLeavesNoPartialFile() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        var input = try offerFrame(id: "drop", name: "drop.bin", size: 100)
        input.append(Data([1, 2, 3]))
        await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(input)))
        // Nothing appears under the item's name. What arrived waits in a hidden, private part
        // file, so the sender can resume it.
        let entries = try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path)
        #expect(!entries.contains("drop.bin"))
        #expect(entries.count == 1 && entries.allSatisfy(isRecoveryPart), "inbox holds \(entries.count) entries")
        if let part = entries.first { #expect(try posixMode(f.inbox.directory.appendingPathComponent(part)) == 0o600) }
        #expect(try await f.service.history.rows().first?.status == "interrupted")
    }
    @Test func testCrashAtEachCommitPointReconcilesAtStartup() async throws {
        for point in TransferCommitPoint.allCases {
            let f = try TransferFixture(); defer { f.cleanup() }
            await f.service.configure(crashAt: point)
            await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(try transferInput())))
            let restarted = TransferService(store: try Store(paths: AgentPaths(directory: f.directory)), inbox: f.inbox)
            try await restarted.reconcile()
            let row = try #require(try await restarted.history.rows().first)
            let entries = try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path)
            switch point {
            case .recorded:
                // Nothing was written: nothing to resume.
                #expect(row.status == "failed", "\(point)")
                #expect(entries.isEmpty, "\(point): \(entries.count) entries")
            case .written, .hashed:
                // Every byte is on disk but not published: kept for the sender to finish.
                #expect(row.status == "interrupted", "\(point)")
                #expect(entries.count == 1 && entries.allSatisfy(isRecoveryPart), "\(point): \(entries.count) entries")
            case .renamed, .committed:
                #expect(row.status == "ok", "\(point)")
                #expect(entries == ["sample.bin"], "\(point): \(entries.count) entries")
                #expect(try TransferInbox.hash(f.inbox.url("sample.bin")) == transferHash(Data("payload".utf8)))
            }
        }
    }
    @Test func testDontKeepReceivedFileNameNeverReachesTheDatabase() async throws {
        let name = "unrepeatable-" + UUID().uuidString.lowercased() + ".bin"
        let stem = Data(name.dropLast(4).utf8)
        func databaseHoldsName(_ directory: URL) throws -> Bool {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let file = directory.appendingPathComponent("store.sqlite" + suffix)
                guard let bytes = try? Data(contentsOf: file) else { continue }
                if bytes.range(of: stem) != nil { return true }
            }
            return false
        }
        for point in [nil] + TransferCommitPoint.allCases.map(Optional.some) {
            let f = try TransferFixture(); defer { f.cleanup() }
            await f.service.configure(crashAt: point)
            await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(try transferInput(name: name, keep: false))))
            #expect(try !databaseHoldsName(f.directory), "the name is in the database after \(point.map(\.rawValue) ?? "a whole transfer")")
            let restarted = TransferService(store: try Store(paths: AgentPaths(directory: f.directory)), inbox: f.inbox)
            try await restarted.reconcile()
            #expect(try !databaseHoldsName(f.directory), "the name is in the database after reconciling \(point.map(\.rawValue) ?? "a whole transfer")")
            // Reconciling still works it out from the part file alone.
            let row = try #require(try await restarted.history.rows().first)
            let published = point == nil || point == .renamed || point == .committed
            #expect(row.status == (published ? "ok" : point == .recorded ? "failed" : "interrupted"), "\(point.map(\.rawValue) ?? "whole")")
            if published { #expect(try Data(contentsOf: f.inbox.url(name)) == Data("payload".utf8)) }
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
            let script = TransferScript(try offerFrame(id: kind, kind: kind, name: "large", size: size, mime: "data"))
            await f.service.receive(deviceID: "peer", connection: WireConnection(script))
            #expect(try await script.frames().first?.decode(TransferReject.self).reason == .tooLarge)
        }
        await f.service.configure(freeBytes: 1024 * 1024 * 1024)
        let script = TransferScript(try offerFrame(id: "space", name: "space", size: 1, mime: "data"))
        await f.service.receive(deviceID: "peer", connection: WireConnection(script))
        #expect(try await script.frames().first?.decode(TransferReject.self).reason == .noSpace)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).isEmpty)
    }
    @Test func testStalledStreamIsDropped() async throws {
        #expect(TransferLimits().idle == .seconds(30))
        var limits = TransferLimits(); limits.idle = .milliseconds(80)
        let f = try TransferFixture(limits: limits); defer { f.cleanup() }
        let script = TransferScript(try offerFrame(id: "stall", name: "stall", size: 1, mime: "data"), stall: true)
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
        func script(_ id: String) throws -> TransferScript { TransferScript(try offerFrame(id: id, name: id, size: 1, mime: "data"), stall: true) }
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
    @Test func testSendCutShortByARestartIsUnconfirmed() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        // What a restart finds when the agent stopped during a send: the row as `start` saved it.
        var cut = TransferRecord(id: "cut", deviceID: "peer", direction: "sent", kind: "text", size: 4, status: "sending")
        cut.text = "text"
        try await f.service.history.save(cut)
        try await f.service.reconcile()
        // This device no longer knows how far the send got, so it does not claim it failed.
        let row = try #require(try await f.service.history.record(deviceID: "peer", id: "cut"))
        #expect(row.status == "unconfirmed" && row.canRetry && row.text == "text")
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
    /// The offline phase ends in `failed` with "Cannot reach" (its dial bound is
    /// `DialBoundTests`' business, not a wall clock here). The retry waits for the event that
    /// makes it possible, b's restarted server answering a's ping, and then dials with the
    /// default limit. Waits are hang guards only.
    @Test func testUnreachablePeerFailsWithinTimeoutAndCanRetry() async throws {
        try await withTestDevices { devices in
            let a = try await devices.make("first"), b = try await devices.make("second")
            try await linkDevices(a, b)
            await b.runtime.stop()
            var limits = TransferLimits(); limits.dial = .seconds(3)
            let sender = TransferService(store: await a.runtime.store, inbox: try TransferInbox(directory: a.paths.directory.appendingPathComponent("inbox")), peers: a.peers, limits: limits)
            TestProgress.mark("offline send")
            let id = try await sender.start(deviceID: b.id, payload: .text("offline")).id
            #expect(try await waitUntil(timeout: .seconds(120)) { try await sender.status(deviceID: b.id, id: id)?.status == "failed" })
            let row = try #require(try await sender.status(deviceID: b.id, id: id))
            #expect(row.canRetry && row.error?.contains("Cannot reach") == true)
            TestProgress.mark("restart b")
            try await b.runtime.start()
            let receiver = TransferService(store: await b.runtime.store, inbox: try TransferInbox(directory: b.paths.directory.appendingPathComponent("inbox")), peers: b.peers)
            try await receiver.install(on: b.runtime)
            TestProgress.mark("ping barrier")
            var answered = false
            for _ in 0..<4 where !answered { answered = (try? await a.peers.ping(deviceID: b.id, timeout: .seconds(30))) != nil }
            #expect(answered, "b's restarted server never answered a's ping")
            TestProgress.mark("retry")
            await sender.configure(limits: TransferLimits())
            _ = try await sender.retry(deviceID: b.id, id: id)
            #expect(try await waitUntil(timeout: .seconds(120)) { try await sender.status(deviceID: b.id, id: id)?.status == "ok" })
        }
    }
}
