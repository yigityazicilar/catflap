import CatflapCore
import Foundation
import Synchronization
import Testing

/// The waiting queue, driven by a test clock and a connector whose ping fails until the test
/// says the device is here. `runDueDeliveries` is one pass of the scheduler.
@Suite struct WaitingQueueTests {
    static let b = LoopbackPair.receiverID

    @Test func testSendToAnAwayDeviceWaitsAndDeliversWhenItAnswers() async throws {
        let p = try await LoopbackPair(here: false); defer { p.cleanup() }
        let batch = try await p.senderService.send(SendRequest(deviceIDs: [Self.b], payloads: [.text("for later")]))
        let id = try #require(batch.transfers.first?.id)
        #expect(try await waitUntil { try await p.row(id)?.status == "waiting" })
        let waiting = try #require(try await p.row(id))
        #expect(waiting.error?.contains("Cannot reach") == true && waiting.waiting != nil && waiting.canCancel)
        #expect(try await p.received().isEmpty)
        p.connector.setHere(true)
        p.clock.advance(400)
        await p.senderService.runDueDeliveries()
        #expect(try await waitUntil { try await p.row(id)?.status == "ok" })
        #expect(try await p.received().first?.text == "for later")
    }

    /// A device that is here but slow to dial on a loaded machine: the first dial ends past
    /// its limit, the send waits, and the next try after the first backoff delivers it, with
    /// no presence change in between.
    @Test func testSlowFirstDialIsDeliveredByTheNextTryWithoutAPresenceChange() async throws {
        let p = try await LoopbackPair(); defer { p.cleanup() }
        p.connector.slowDials(1)
        let id = try #require(try await p.senderService.send(SendRequest(deviceIDs: [Self.b], payloads: [.text("slow dial")])).transfers.first?.id)
        #expect(try await waitUntil { try await p.row(id)?.status == "waiting" })
        let next = try #require(try await p.row(id)?.waiting?.nextAttemptAt)
        // Due within the first backoff, 30 s ±10 %.
        #expect(next.timeIntervalSince(p.clock.now()) <= 33.5)
        p.clock.advance(next.timeIntervalSince(p.clock.now()) + 0.1)
        await p.senderService.runDueDeliveries()
        #expect(try await waitUntil { try await p.row(id)?.status == "ok" })
        #expect(try await p.received().first?.text == "slow dial")
    }

    @Test func testBackoffRunsFromThirtySecondsToFiveMinutes() {
        let steps = (1...7).map { TransferService.backoff(afterFailures: $0, jitter: 0) }
        #expect(steps == [30, 60, 120, 240, 300, 300, 300])
        #expect(TransferService.backoff(afterFailures: 1, jitter: 0.1) == 33)
        #expect(TransferService.backoff(afterFailures: 5, jitter: -0.1) == 270)
    }

    @Test func testBackoffIsPerDeviceAndResetsOnAnAnswer() async throws {
        let p = try await LoopbackPair(here: false); defer { p.cleanup() }
        let id = try #require(try await p.senderService.send(SendRequest(deviceIDs: [Self.b], payloads: [.text("x")])).transfers.first?.id)
        #expect(try await waitUntil { try await p.row(id)?.status == "waiting" })
        func next() async throws -> TimeInterval {
            let row = try #require(try await p.row(id))
            return try #require(row.waiting?.nextAttemptAt).timeIntervalSince(p.clock.now())
        }
        var gaps: [TimeInterval] = []
        for _ in 0..<5 {
            gaps.append(try await next())
            p.clock.advance(try await next() + 1)
            await p.senderService.runDueDeliveries()
        }
        // Each failed ping doubles the wait, within ±10 %, up to five minutes.
        for (gap, base) in zip(gaps, [30.0, 60, 120, 240, 300]) { #expect(abs(gap - base) <= base * 0.1 + 1, "\(gaps)") }
        await p.senderService.peerSeen(deviceID: Self.b)
        #expect(try await next() <= 0)
    }

    @Test func testWaitingItemExpiresAfterSevenDaysWithANotification() async throws {
        let p = try await LoopbackPair(here: false); defer { p.cleanup() }
        let events = Mutex<[String]>([])
        await p.senderService.setEventHandler { event in
            if case .expired(let row) = event { events.withLock { $0.append(row.id) } }
        }
        let id = try #require(try await p.senderService.send(SendRequest(deviceIDs: [Self.b], payloads: [.text("old")])).transfers.first?.id)
        #expect(try await waitUntil { try await p.row(id)?.status == "waiting" })
        p.clock.advance(7 * 24 * 3600 + 1)
        await p.senderService.runDueDeliveries()
        await p.senderService.runDueDeliveries()
        let row = try #require(try await p.row(id))
        #expect(row.status == "expired" && row.error == "Not delivered: Device B stayed away for 7 days." && row.canRetry)
        #expect(events.withLock { $0 } == [id])
        #expect(p.connector.links.isEmpty)
    }

    @Test func testWaitingFileThatChangedOrVanishedFailsWithThatReason() async throws {
        enum Change: CaseIterable { case size, mtime, inode, deleted, symlink }
        for change in Change.allCases {
            let p = try await LoopbackPair(here: false); defer { p.cleanup() }
            let file = p.sender.directory.appendingPathComponent("queued.txt")
            try Data("first version".utf8).write(to: file)
            let id = try #require(try await p.senderService.send(SendRequest(deviceIDs: [Self.b], payloads: [.file(file)])).transfers.first?.id)
            #expect(try await waitUntil { try await p.row(id)?.status == "waiting" })
            switch change {
            case .size: try Data("a longer second version".utf8).write(to: file)
            case .mtime: try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: file.path)
            case .inode:
                let other = p.sender.directory.appendingPathComponent("other.txt")
                try Data("first versiom".utf8).write(to: other)
                try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: other, to: file)
            case .deleted: try FileManager.default.removeItem(at: file)
            case .symlink:
                let other = p.sender.directory.appendingPathComponent("elsewhere.txt")
                try Data("first version".utf8).write(to: other)
                try FileManager.default.removeItem(at: file); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            }
            p.connector.setHere(true); p.clock.advance(400)
            await p.senderService.runDueDeliveries()
            #expect(try await waitUntil { try await p.row(id)?.status == "failed" }, "\(change)")
            let reason = try await p.row(id)?.error
            let expected = change == .deleted ? TransferFailure.sourceGone.errorDescription : TransferFailure.sourceChanged.errorDescription
            #expect(reason == expected, "\(change): \(reason ?? "none")")
            #expect(try await p.received().isEmpty, "\(change)")
        }
    }

    @Test func testDontKeepItemNeverWaits() async throws {
        let p = try await LoopbackPair(here: false); defer { p.cleanup() }
        let id = try #require(try await p.senderService.send(SendRequest(deviceIDs: [Self.b], payloads: [.text("now or never")], keep: false)).transfers.first?.id)
        #expect(try await waitUntil { try await p.row(id)?.status == "failed" })
        let queue = try await p.sender.store.query("SELECT 1 FROM queue")
        #expect(queue.isEmpty)
    }

    @Test func testWaitingItemsSurviveARestartAndCanBeCancelled() async throws {
        let p = try await LoopbackPair(here: false); defer { p.cleanup() }
        let file = p.sender.directory.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 2048).write(to: file)
        let ids = try await p.senderService.send(SendRequest(deviceIDs: [Self.b], payloads: [.text("first"), .file(file)])).transfers.map(\.id)
        #expect(ids.count == 2)
        for id in ids { #expect(try await waitUntil { try await p.row(id)?.status == "waiting" }) }
        await p.senderService.stop()
        // A new agent on the same data finds both still waiting.
        let restarted = TransferService(store: try Store(paths: AgentPaths(directory: p.sender.directory)), inbox: p.sender.inbox,
                                        connector: p.connector, clock: p.clock)
        try await restarted.reconcile()
        for id in ids { #expect(try await restarted.status(deviceID: Self.b, id: id)?.status == "waiting") }
        let cancelled = try await restarted.cancel(deviceID: Self.b, id: ids[1])
        #expect(cancelled.status == "cancelled" && cancelled.canRetry)
        #expect(try await restarted.history.store.query("SELECT 1 FROM queue WHERE id=?", bindings: [.text(ids[1])]).isEmpty)
        // The other is delivered when the device answers; the cancelled one never is, and the
        // receiver is told to forget any part of it.
        p.connector.setHere(true); p.clock.advance(400)
        await restarted.runDueDeliveries()
        #expect(try await waitUntil { try await restarted.status(deviceID: Self.b, id: ids[0])?.status == "ok" })
        #expect(try await restarted.status(deviceID: Self.b, id: ids[1])?.status == "cancelled")
        #expect(try await p.received().map(\.text) == ["first"])
        #expect(p.connector.links.first?.written.first == "forget")
    }

    @Test func testInboundSessionFromADeviceDeliversItsWaitingItemsNow() async throws {
        let p = try await LoopbackPair(here: false); defer { p.cleanup() }
        let id = try #require(try await p.senderService.send(SendRequest(deviceIDs: [Self.b], payloads: [.text("soon")])).transfers.first?.id)
        #expect(try await waitUntil { try await p.row(id)?.status == "waiting" })
        p.connector.setHere(true)
        // No clock change: the contact alone makes it due.
        await p.senderService.peerSeen(deviceID: Self.b)
        await p.senderService.runDueDeliveries()
        #expect(try await waitUntil { try await p.row(id)?.status == "ok" })
    }

    @Test func testAtMostOnePingInFlightPerDevice() async throws {
        let p = try await LoopbackPair(here: false); defer { p.cleanup() }
        let id = try #require(try await p.senderService.send(SendRequest(deviceIDs: [Self.b], payloads: [.text("x")])).transfers.first?.id)
        #expect(try await waitUntil { try await p.row(id)?.status == "waiting" })
        // Hold every ping until all 50 passes have started.
        let gate = TestSignal()
        p.connector.setPingGate { await gate.wait() }
        let before = p.connector.pings
        p.clock.advance(400)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 { group.addTask { await p.senderService.runDueDeliveries() } }
            group.addTask {
                _ = try? await waitUntil { p.connector.pings > before }
                gate.fire()
            }
        }
        #expect(p.connector.maxInFlight == 1)
    }

    @Test func testRefusalsThatWillNotChangeFailInsteadOfWaiting() async throws {
        // Too large on the other side: the same item will always be refused.
        var small = TransferLimits(); small.textBytes = 4
        let p = try await LoopbackPair(receiverLimits: small); defer { p.cleanup() }
        let large = try #require(try await p.senderService.send(SendRequest(deviceIDs: [Self.b], payloads: [.text("more than four")])).transfers.first?.id)
        #expect(try await waitUntil { try await p.row(large)?.status == "failed" })
        #expect(try await p.row(large)?.error == "The other device refused it: too large.")
        // Busy: it waits, with the reason.
        await p.receiver.service.configure(freeBytes: 1)
        let file = p.sender.directory.appendingPathComponent("f.bin"); try Data([1]).write(to: file)
        let full = try #require(try await p.senderService.send(SendRequest(deviceIDs: [Self.b], payloads: [.file(file)])).transfers.first?.id)
        #expect(try await waitUntil { try await p.row(full)?.status == "waiting" })
        #expect(try await p.row(full)?.error == "The other device refused it: not enough free space there.")
    }
}
