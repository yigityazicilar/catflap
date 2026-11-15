import CatflapCore
import Foundation
import Synchronization
import Testing

/// A scheduler sleeper that records every requested sleep. The first `immediate` ones return
/// at once; the rest last until the task is cancelled or the test releases them.
final class TestSleeper: TransferSleeper, @unchecked Sendable {
    private struct State {
        var requests: [Double] = []
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var cancelled: Set<Int> = []
    }
    private let state = Mutex(State())
    let immediate: Int
    init(immediate: Int = 1) { self.immediate = immediate }
    var requests: [Double] { state.withLock { $0.requests } }
    func sleep(seconds: Double) async {
        let n = state.withLock { s -> Int in s.requests.append(seconds); return s.requests.count - 1 }
        guard n >= immediate else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { s -> Bool in
                    if s.cancelled.contains(n) { return true }
                    s.waiters[n] = continuation; return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
                s.cancelled.insert(n); return s.waiters.removeValue(forKey: n)
            }
            waiter?.resume()
        }
    }
    func releaseAll() {
        let all = state.withLock { s -> [CheckedContinuation<Void, Never>] in defer { s.waiters = [:] }; return Array(s.waiters.values) }
        for waiter in all { waiter.resume() }
    }
}

/// The scheduler, with its sleeps and its clock under the test's control.
@Suite struct SchedulerWakeTests {
    @Test func testAFailedSendWakesAnIdleSchedulerForItsFirstBackoff() async throws {
        let sleeper = TestSleeper()
        let receiver = try TransferFixture(), sender = try TransferFixture()
        defer { sleeper.releaseAll(); receiver.cleanup(); sender.cleanup() }
        let connector = LoopbackConnector(receiver: receiver.service, as: "sender", here: false)
        let clock = TestClock()
        let service = TransferService(store: sender.store, inbox: sender.inbox, connector: connector, clock: clock, sleeper: sleeper)
        try await sender.store.saveDevice(DeviceRecord(id: "receiver", name: "Device B", clientPublicKey: "", address: "", pairSecret: Data(), build: "test"))
        await service.startScheduler()
        defer { Task { await service.stop() } }
        // Idle: after the start-up spread it sleeps the idle minute.
        #expect(try await waitUntil { sleeper.requests.count == 2 })
        #expect(sleeper.requests.dropFirst().first == 60)
        let id = try #require(try await service.send(SendRequest(deviceIDs: ["receiver"], payloads: [.text("wake")])).transfers.first?.id)
        #expect(try await waitUntil { try await service.status(deviceID: "receiver", id: id)?.status == "waiting" })
        let next = try #require(try await service.status(deviceID: "receiver", id: id)?.waiting?.nextAttemptAt)
        let due = next.timeIntervalSince(clock.now())
        #expect((27...33.000_1).contains(due), "first backoff \(due) s")
        // The failure wakes the scheduler, which then sleeps until the item is due instead of
        // the rest of the idle minute. The wait is a hang guard.
        let woke = try await waitUntil(timeout: .seconds(20)) { sleeper.requests.count >= 3 }
        #expect(woke, "the scheduler slept on through the failure: \(sleeper.requests)")
        if woke { #expect(abs(sleeper.requests[2] - due) < 0.01, "\(sleeper.requests)") }
    }
}
