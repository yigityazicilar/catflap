import CatflapCore
import Foundation
import Synchronization
import Testing

/// The `done` write that fails, through the transport-double seam (no fault hook in the
/// shipped binary). A failure before `done` left is certain; from `done` on only the
/// acknowledgement tells, so the row is `unconfirmed` and a retry never makes a second copy.
@Suite struct TransferSeamTests {
    /// An authenticated session that offers nothing, as a confirming Open is, takes no receive
    /// slot: a send to the same device while `receivesPerDevice` such sessions are open is
    /// delivered before either of them ends.
    @Test func testSessionsWithoutAnOfferHoldNoReceiveSlot() async throws {
        let p = try await LoopbackPair(); defer { p.cleanup() }
        let limit = TransferLimits().receivesPerDevice
        var idle: [PeerLink] = []
        for _ in 0..<limit { idle.append(try await p.connector.link(deviceID: LoopbackPair.receiverID, timeout: .seconds(5))) }
        let ended = SharedFlag()
        for link in idle {
            let connection = link.connection
            Task { _ = try? await connection.readFrame(timeout: .seconds(120)); ended.set() }
        }
        let id = try await p.senderService.start(deviceID: LoopbackPair.receiverID, payload: .text("past the idle sessions")).id
        #expect(try await waitUntil { try await p.row(id)?.status == "ok" })
        #expect(!ended.value, "the send was delivered only after a session without an offer ended")
        for link in idle { await link.close() }
    }

    @Test(arguments: [true, false])
    func testFailedDoneWriteLeavesUnconfirmedAndRetryMakesOneCopy(delivered: Bool) async throws {
        let p = try await LoopbackPair(); defer { p.cleanup() }
        let file = p.sender.directory.appendingPathComponent("report.bin")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        p.connector.failNext(.failWrite(frame: "done", delivered: delivered))
        let id = try await p.senderService.start(deviceID: LoopbackPair.receiverID, payload: .file(file)).id
        #expect(try await waitUntil { try await p.row(id)?.status == "unconfirmed" })
        #expect(try await p.row(id)?.canRetry == true)
        if delivered {
            // The frame arrived: the receiver stored the item.
            #expect(try await waitUntil { try await p.received().first?.status == "ok" })
        } else {
            // It never left: every byte is in a complete part, waiting for the sender.
            #expect(try await waitUntil { try await p.received().first?.status == "interrupted" })
            #expect(try p.inboxEntries().allSatisfy(isRecoveryPart))
        }
        _ = try await p.senderService.retry(deviceID: LoopbackPair.receiverID, id: id)
        #expect(try await waitUntil { try await p.row(id)?.status == "ok" })
        #expect(try await p.received().count == 1)
        #expect(try p.inboxEntries() == ["report.bin"])
        #expect(try Data(contentsOf: p.receiver.inbox.url("report.bin")) == bytes)
        // The second attempt sends no payload again: a duplicate, or the rest from the end.
        let second = try #require(p.connector.links.last)
        #expect(second.written == (delivered ? ["offer"] : ["offer", "done"]), "\(second.written)")
        #expect(second.payloadBytes == 0)
    }

    @Test func testFailedDoneWriteOfAWaitingSendIsRetriedWithoutASecondCopy() async throws {
        let p = try await LoopbackPair(); defer { p.cleanup() }
        p.connector.failNext(.failWrite(frame: "done", delivered: true))
        let batch = try await p.senderService.send(SendRequest(deviceIDs: [LoopbackPair.receiverID], payloads: [.text("waiting note")]))
        let id = try #require(batch.transfers.first?.id)
        // It waits instead of failing, and says it may have arrived.
        #expect(try await waitUntil { try await p.row(id)?.status == "waiting" })
        #expect(try await p.row(id)?.waiting?.unconfirmed == true)
        p.clock.advance(400)
        await p.senderService.runDueDeliveries()
        #expect(try await waitUntil { try await p.row(id)?.status == "ok" })
        let received = try await p.received()
        #expect(received.count == 1 && received.first?.text == "waiting note")
    }
}

final class SharedFlag: Sendable {
    private let state = Mutex(false)
    func set() { state.withLock { $0 = true } }
    var value: Bool { state.withLock { $0 } }
}
