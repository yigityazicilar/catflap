@testable import CatflapCore
import Synchronization
import Testing

/// Headroom for selected dial/handshake/read phases, not a universal send-duration bound.
struct WaitGuardTests {
    @Test func testTheWaitGuardOutlastsSelectedSendPhases() {
        let limits = TransferLimits()
        let selected = limits.dial + PeerOpen.handshakeTimeout * 2 + limits.idle * 2
        #expect(testWaitGuard > selected, "the wait guard is \(testWaitGuard), selected phases allow \(selected)")
    }

    @Test func testOmittedTimeoutActuallyWaitsBeyondOldGuard() async throws {
        let time = ManualConditionClock()
        // Deliberately omit timeout: checking the constant alone misses a default-argument regression.
        let ready = try await waitUntil(clock: time.clock) { time.elapsed >= .seconds(31) }
        #expect(ready, "the omitted timeout must allow a condition after the old 30 s guard")
        #expect(time.elapsed == .seconds(31))
    }

    @Test func testDefaultTimeoutUsesTheChosenGuardAndFinalConditionCheck() async throws {
        let time = ManualConditionClock()
        var checks = 0
        let ready = try await waitUntil(clock: time.clock) { checks += 1; return false }
        #expect(!ready)
        #expect(time.elapsed == testWaitGuard)
        #expect(checks == time.sleeps + 1)
    }

    @Test func testExplicitShortTimeoutStillWins() async throws {
        let time = ManualConditionClock()
        var checks = 0
        let ready = try await waitUntil(timeout: .milliseconds(200), clock: time.clock) {
            checks += 1
            return false
        }
        #expect(!ready)
        #expect(time.elapsed == .milliseconds(200))
        #expect(time.sleeps == 2)
        #expect(checks == 3)
    }

    private enum ConditionFailure: Error { case sentinel }

    @Test func testConditionErrorPropagatesWithoutSleeping() async throws {
        let time = ManualConditionClock()
        do {
            _ = try await waitUntil(clock: time.clock) { throw ConditionFailure.sentinel }
            Issue.record("condition error was swallowed")
        } catch ConditionFailure.sentinel {}
        #expect(time.sleeps == 0)
    }

    @Test func testCancellationFromSleeperPropagates() async throws {
        let time = ManualConditionClock()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await waitUntil(clock: time.clock) { false }
        }
        do {
            _ = try await task.value
            Issue.record("cancellation was swallowed")
        } catch is CancellationError {}
        #expect(time.sleeps == 0)
    }

    @Test func testImmediateConditionDoesNotSleep() async throws {
        let time = ManualConditionClock()
        let ready = try await waitUntil(clock: time.clock) { true }
        #expect(ready)
        #expect(time.sleeps == 0)
    }
}

private final class ManualConditionClock: Sendable {
    private struct State { var elapsed: Duration = .zero; var sleeps = 0 }
    private let state = Mutex(State())
    var elapsed: Duration { state.withLock { $0.elapsed } }
    var sleeps: Int { state.withLock { $0.sleeps } }
    var clock: ConditionWaitClock {
        ConditionWaitClock(now: { self.elapsed }, sleep: { duration in
            try Task.checkCancellation()
            self.state.withLock { $0.elapsed += duration; $0.sleeps += 1 }
        })
    }
}
