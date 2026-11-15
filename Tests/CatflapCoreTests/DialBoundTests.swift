import CatflapCore
import Foundation
import Synchronization
import Testing

/// A one-shot event a test can wait for, in any order with its firing.
final class TestSignal: Sendable {
    private struct State { var fired = false; var waiters: [CheckedContinuation<Void, Never>] = [] }
    private let state = Mutex(State())
    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fired = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    var fired: Bool { state.withLock { $0.fired } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                if state.fired { return true }
                state.waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }
}

/// Waits for `task` and gives up after `guardLimit`, which is only a hang guard: nil means the
/// task had not ended by then. The task itself is left running.
func result<T: Sendable>(of task: Task<T, any Error>, hangGuard guardLimit: Duration = .seconds(60)) async -> Result<T, any Error>? {
    let once = ClaimOnce()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, any Error>?, Never>) in
        Task { let value = await task.result; if once.claim() { continuation.resume(returning: value) } }
        Task { try? await Task.sleep(for: guardLimit); if once.claim() { continuation.resume(returning: nil) } }
    }
}
final class ClaimOnce: Sendable {
    private let claimed = Mutex(false)
    func claim() -> Bool { claimed.withLock { value in defer { value = true }; return !value } }
}

/// A dial client whose dial fails at once, as one cut off by its deadline does, and whose
/// teardown does not end until the test releases it. tailcat's `tc_close` of a started client
/// has no deadline, so it can take this long on a loaded machine.
final class StallingTeardownClient: PeerDialClient {
    let dialBudgets = Mutex<[Duration?]>([])
    let teardownStarted = TestSignal()
    let releaseTeardown = TestSignal()
    let teardownEnded = TestSignal()
    func dialTransport(port: UInt16, timeout: Duration?) async throws -> any WireTransport {
        dialBudgets.withLock { $0.append(timeout) }
        throw WireError.timedOut
    }
    func close() async {
        teardownStarted.fire()
        await releaseTeardown.wait()
        teardownEnded.fire()
    }
}

/// Every step between a send and its row turning `failed` for an unreachable device must be
/// bounded by the dial limit, or not stand in the way of reporting the failure.
@Suite struct DialBoundTests {
    @Test func testDialFailureIsReportedWithoutWaitingForTheClientTeardown() async throws {
        let paths = try storeTestPaths(); defer { removeStoreTestPaths(paths) }
        let runtime = try AgentRuntime(paths: paths)
        let identity = await runtime.identityServer.identity
        let device = DeviceRecord(id: "peer", name: "Device B", clientPublicKey: "unused", address: "unused",
                                  pairSecret: Data(repeating: 7, count: 32), build: "0.0.7")
        let client = StallingTeardownClient()
        let opening = Task {
            try await PeerOpen.dial(device, identity: identity, build: "test", timeout: .seconds(3), client: client)
        }
        await client.teardownStarted.wait()
        // The order that matters: the failure reaches the caller while the teardown still runs.
        let outcome = await result(of: opening)
        #expect(outcome != nil, "the dial failure waited for the client's teardown, which has no deadline")
        #expect(!client.teardownEnded.fired)
        client.releaseTeardown.fire()
        let ended: Result<PeerSession, any Error>
        if let outcome { ended = outcome } else { ended = await opening.result }
        #expect(throws: PeerError.unreachable(device: "Device B", lastSeenBuild: "0.0.7")) { _ = try ended.get() }
        // One dial attempt, bounded by the limit.
        let budgets = client.dialBudgets.withLock { $0 }
        #expect(budgets.count == 1 && budgets.allSatisfy { ($0 ?? .seconds(3600)) <= .seconds(3) })
        // The client is still torn down, only not in the caller's way.
        await client.teardownEnded.wait()
    }
}
