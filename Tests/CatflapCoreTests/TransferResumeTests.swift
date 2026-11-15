import CatflapCore
import Crypto
import Foundation
import Testing

/// Resume (plan v4 feature 6): an interrupted file keeps a hidden part, and the same offer
/// from the same device continues from the bytes the receiver has on disk.
@Suite struct TransferResumeTests {
    static let b = LoopbackPair.receiverID
    static func payload(_ count: Int) -> Data { Data((0..<count).map { UInt8(($0 * 7 + 3) % 251) }) }

    /// Sends `bytes` cut after `cut` payload bytes; returns the transfer id.
    static func interrupted(_ p: LoopbackPair, bytes: Data, cut: Int64, name: String = "big.bin") async throws -> (id: String, file: URL) {
        let file = p.sender.directory.appendingPathComponent(name)
        try bytes.write(to: file)
        p.connector.failNext(.cutAfterPayload(cut))
        let id = try await p.senderService.start(deviceID: b, payload: .file(file)).id
        #expect(try await waitUntil { try await p.row(id)?.status == "failed" })
        #expect(try await waitUntil { try await p.received().first?.status == "interrupted" })
        return (id, file)
    }

    @Test func testInterruptedFileResumesFromTheReceiversOffset() async throws {
        let p = try await LoopbackPair(); defer { p.cleanup() }
        let bytes = Self.payload(3 * 1024 * 1024 + 4096)
        let (id, _) = try await Self.interrupted(p, bytes: bytes, cut: 3 * 1024 * 1024)
        let entries = try p.inboxEntries()
        #expect(entries.count == 1 && entries.allSatisfy(isRecoveryPart))
        #expect(try posixMode(p.receiver.inbox.directory.appendingPathComponent(entries[0])) == 0o600)
        _ = try await p.senderService.retry(deviceID: Self.b, id: id)
        #expect(try await waitUntil { try await p.row(id)?.status == "ok" })
        // Only the rest went the second time.
        let second = try #require(p.connector.links.last)
        #expect(second.payloadBytes == Int64(bytes.count) - 3 * 1024 * 1024)
        #expect(try p.inboxEntries() == ["big.bin"])
        #expect(try TransferInbox.hash(p.receiver.inbox.url("big.bin")) == transferHash(bytes))
        #expect(try await p.received().count == 1)
    }

    @Test func testPartIsNeverAppendedForAnotherSenderOrFile() async throws {
        let p = try await LoopbackPair(); defer { p.cleanup() }
        let bytes = Self.payload(64 * 1024)
        let (id, file) = try await Self.interrupted(p, bytes: bytes, cut: 16 * 1024)
        let part = try #require(try p.inboxEntries().first)
        let before = try Data(contentsOf: p.receiver.inbox.directory.appendingPathComponent(part))
        // The same id from another device starts from nothing, and leaves the first part alone.
        var other = try offerFrame(id: id, name: "big.bin", size: Int64(bytes.count), sha256: transferHash(bytes))
        other.append(bytes.prefix(10))
        let script = TransferScript(other)
        await p.receiver.service.receive(deviceID: "someone-else", connection: WireConnection(script))
        let accepted = try #require(try await script.frames().first)
        #expect(try accepted.decode(TransferAccept.self).offset == 0)
        #expect(try Data(contentsOf: p.receiver.inbox.directory.appendingPathComponent(part)) == before)
        // The same device and id with other content starts over, and the old part goes.
        var changed = bytes; changed[0] ^= 0xff
        try changed.write(to: file)
        _ = try await p.senderService.retry(deviceID: Self.b, id: id)
        #expect(try await waitUntil { try await p.row(id)?.status == "ok" })
        #expect(p.connector.links.last?.payloadBytes == Int64(bytes.count))
        #expect(try Data(contentsOf: p.receiver.inbox.url("big.bin")) == changed)
        #expect(!FileManager.default.fileExists(atPath: p.receiver.inbox.directory.appendingPathComponent(part).path))
    }

    @Test func testResumedFileWithAChangedPrefixFailsTheWholeFileCheck() async throws {
        let p = try await LoopbackPair(); defer { p.cleanup() }
        let bytes = Self.payload(64 * 1024)
        let (id, _) = try await Self.interrupted(p, bytes: bytes, cut: 32 * 1024)
        let part = p.receiver.inbox.directory.appendingPathComponent(try #require(try p.inboxEntries().first))
        var damaged = try Data(contentsOf: part); damaged[5] ^= 0x01
        try damaged.write(to: part)
        _ = try await p.senderService.retry(deviceID: Self.b, id: id)
        #expect(try await waitUntil { try await p.row(id)?.status == "failed" })
        #expect(try await p.row(id)?.error == TransferFailure.rejected(.corrupt).errorDescription)
        #expect(try p.inboxEntries().isEmpty)
    }

    /// A reject means the receiver has cleaned up: the part is gone before the reject is sent,
    /// so a sender that sees `failed` sees an inbox without it. The receiver is held right
    /// after it wrote the reject, and the inbox is read while it is held.
    @Test func testARejectIsSentOnlyAfterThePartIsRemoved() async throws {
        let p = try await LoopbackPair(); defer { p.cleanup() }
        let bytes = Self.payload(64 * 1024)
        let (id, _) = try await Self.interrupted(p, bytes: bytes, cut: 32 * 1024)
        let part = p.receiver.inbox.directory.appendingPathComponent(try #require(try p.inboxEntries().first))
        var damaged = try Data(contentsOf: part); damaged[5] ^= 0x01
        try damaged.write(to: part)
        let reached = TestSignal(), release = TestSignal()
        defer { release.fire() }
        p.connector.holdReceiver(after: TransferReject.type) { reached.fire(); await release.wait() }
        _ = try await p.senderService.retry(deviceID: Self.b, id: id)
        await reached.wait()
        #expect(try p.inboxEntries().isEmpty, "the receiver sent its reject before it removed the part")
        release.fire()
        #expect(try await waitUntil { try await p.row(id)?.status == "failed" })
    }

    @Test func testInterruptedPartExpiresAfterSevenDays() async throws {
        let clock = TestClock()
        let receiver = try TransferFixture(); defer { receiver.cleanup() }
        let service = TransferService(store: receiver.store, inbox: receiver.inbox, clock: clock)
        var input = try offerFrame(id: "old", name: "old.bin", size: 100, sha256: transferHash(Self.payload(100)))
        input.append(Self.payload(40))
        await service.receive(deviceID: "peer", connection: WireConnection(TransferScript(input)))
        #expect(try await service.history.rows().first?.status == "interrupted")
        try await service.sweepParts()
        #expect(try FileManager.default.contentsOfDirectory(atPath: receiver.inbox.directory.path).count == 1)
        clock.advance(7 * 24 * 3600 + 1)
        try await service.sweepParts()
        #expect(try await service.history.rows().first?.status == "expired")
        #expect(try FileManager.default.contentsOfDirectory(atPath: receiver.inbox.directory.path).isEmpty)
        #expect(try await receiver.store.query("SELECT 1 FROM parts").isEmpty)
    }

    @Test func testForgetFromTheSenderRemovesOnlyItsParts() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        for device in ["first", "second"] {
            var input = try offerFrame(id: "same", name: "\(device).bin", size: 100, sha256: transferHash(Self.payload(100)))
            input.append(Self.payload(40))
            await f.service.receive(deviceID: device, connection: WireConnection(TransferScript(input)))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).count == 2)
        let forget = TransferScript(try WireCodec.frame(TransferForget(ids: ["same"])))
        await f.service.receive(deviceID: "first", connection: WireConnection(forget))
        #expect(try await forget.frames().first?.decode(TransferForgotten.self).count == 1)
        let rows = try await f.service.history.rows()
        #expect(rows.first(where: { $0.deviceID == "first" })?.status == "cancelled")
        #expect(rows.first(where: { $0.deviceID == "second" })?.status == "interrupted")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.inbox.directory.path).count == 1)
    }
}
