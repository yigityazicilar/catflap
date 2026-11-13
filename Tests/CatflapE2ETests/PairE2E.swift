import CatflapCore
import Foundation
import Testing

/// Runs a blocking harness call on a thread of its own, so a waiting test does not hold one of
/// Swift's cooperative threads, of which macOS keeps only as many as there are cores.
private func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

/// Two real agents pair through the `catflap` command, restart, and still reach each other.
/// The pairing code is a secret: it is passed from one command to the other, never printed.
@Suite(.timeLimit(.minutes(5)))
struct PairE2E {
    @Test func testPairRestartBothStillPaired() async throws {
        let first = try AgentHarness()
        let second = try AgentHarness()
        let agents = HarnessPair(first: first, second: second)
        defer { agents.stop() }
        try await offPool { try agents.first.start(); try agents.second.start() }

        // Pairing needs a direction.
        #expect(try await offPool { try agents.first.command(["pair"]) }.code == 64)

        var started = try await offPool { try agents.first.command(["pair", "start"], timeout: 60) }.decode(PairingStatus.self)
        let deadline = ContinuousClock.now + .seconds(60)
        while started.state == .starting && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            started = try await offPool { try agents.first.command(["pair", "status"]) }.decode(PairingStatus.self)
        }
        #expect(started.state == .waiting)
        let code = try #require(started.code)
        let joined = try await offPool { try agents.second.command(["pair", "join", code]) }
        #expect(joined.code == 0)

        let one = try await waitFor(first) { $0.state == .confirm || !$0.isActive }
        let two = try await waitFor(second) { $0.state == .confirm || !$0.isActive }
        #expect(one.state == .confirm)
        #expect(two.state == .confirm)
        let sameDigits = one.digits != nil && one.digits == two.digits
        #expect(sameDigits)
        #expect(try await offPool { try agents.first.command(["pair", "confirm"]) }.code == 0)
        #expect(try await offPool { try agents.second.command(["pair", "confirm"]) }.code == 0)
        let firstDone = try await waitFor(first) { !$0.isActive }
        let secondDone = try await waitFor(second) { !$0.isActive }
        #expect(firstDone.state == .paired)
        #expect(secondDone.state == .paired)

        let firstID = try await offPool { try agents.first.command(["status"]) }.decode(AgentStatus.self).deviceID
        let secondID = try await offPool { try agents.second.command(["status"]) }.decode(AgentStatus.self).deviceID
        #expect(firstDone.deviceID == secondID)
        #expect(secondDone.deviceID == firstID)

        try await offPool { try agents.first.restart(); try agents.second.restart() }
        #expect(try await offPool { try agents.first.command(["devices"]) }.decode([DeviceSummary].self).map(\.id) == [secondID])
        #expect(try await offPool { try agents.second.command(["devices"]) }.decode([DeviceSummary].self).map(\.id) == [firstID])
        let firstStatus = try await offPool { try agents.first.command(["status"]) }.decode(AgentStatus.self)
        let secondStatus = try await offPool { try agents.second.command(["status"]) }.decode(AgentStatus.self)
        #expect(firstStatus.deviceID == firstID && firstStatus.pairedDevices == 1 && firstStatus.serverRunning)
        #expect(secondStatus.deviceID == secondID && secondStatus.pairedDevices == 1 && secondStatus.serverRunning)

        // A server object existing is not proof of reachability: each side runs the Open step
        // against the other, with the addresses and secret stored before the restart.
        let forward = try await offPool { try agents.second.command(["pair", "check", firstID], timeout: 90) }
        #expect(forward.code == 0)
        #expect(try forward.decode(PairingService.CheckStatus.self).state == "ok")
        let backward = try await offPool { try agents.first.command(["pair", "check", secondID], timeout: 90) }
        #expect(backward.code == 0)
        #expect(try backward.decode(PairingService.CheckStatus.self).state == "ok")
    }

    private func waitFor(_ agent: AgentHarness, _ condition: (PairingStatus) -> Bool) async throws -> PairingStatus {
        let holder = HarnessPair(first: agent, second: agent)
        let deadline = ContinuousClock.now + .seconds(90)
        while true {
            let status = try await offPool { try holder.first.command(["pair", "status"]) }.decode(PairingStatus.self)
            if condition(status) || ContinuousClock.now >= deadline { return status }
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}

/// The harness is used from one test at a time, one call at a time.
private final class HarnessPair: @unchecked Sendable {
    let first: AgentHarness
    let second: AgentHarness
    init(first: AgentHarness, second: AgentHarness) { self.first = first; self.second = second }
    func stop() { first.stop(); second.stop() }
}
