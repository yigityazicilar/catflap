import CatflapCore
import Foundation
import Synchronization
import Testing

/// Runs blocking harness work off the cooperative pool.
func onThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

/// A test drives each harness from one task at a time; the threads `onThread` uses only hand
/// it on.
extension AgentHarness: @unchecked Sendable {}

/// Two started agents, paired with each other through the CLI, as a person would.
final class PairedAgents: @unchecked Sendable {
    let first: AgentHarness
    let second: AgentHarness
    init() throws { first = try AgentHarness(); second = try AgentHarness() }
    func stop() { first.stop(); second.stop() }

    func startAndPair() async throws {
        for agent in [first, second] {
            let store = try Store(paths: AgentPaths(directory: agent.dataDirectory))
            try await store.setSetting("inbox", value: agent.dataDirectory.appendingPathComponent("inbox").path)
        }
        try await onThread { [self] in try first.start(); try second.start() }
        var pairing = try await onThread { [self] in try first.command(["pair", "start"]) }.decode(PairingStatus.self)
        while pairing.state == .starting {
            try await Task.sleep(for: .milliseconds(200))
            pairing = try await onThread { [self] in try first.command(["pair", "status"]) }.decode(PairingStatus.self)
        }
        let code = try #require(pairing.code)
        let joiner = second
        let joined: CommandResult = try await onThread { try joiner.command(["pair", "join", code]) }
        #expect(joined.code == 0)
        for agent in [first, second] {
            var state = try await onThread { try agent.command(["pair", "status"]) }.decode(PairingStatus.self)
            while state.state != .confirm && state.isActive {
                try await Task.sleep(for: .milliseconds(200))
                state = try await onThread { try agent.command(["pair", "status"]) }.decode(PairingStatus.self)
            }
            try #require(state.state == .confirm)
            #expect(try await onThread { try agent.command(["pair", "confirm"]) }.code == 0)
        }
        for agent in [first, second] {
            var state = try await onThread { try agent.command(["pair", "status"]) }.decode(PairingStatus.self)
            while state.isActive {
                try await Task.sleep(for: .milliseconds(200))
                state = try await onThread { try agent.command(["pair", "status"]) }.decode(PairingStatus.self)
            }
            try #require(state.state == .paired)
        }
    }
}

/// A stand-in agent on a real control socket in a harness's data folder: every request gets
/// a successful envelope whose payload is the given bytes. The CLI is run against it with the
/// harness's `command`, so no real agent is involved.
final class AgentDouble: @unchecked Sendable {
    let harness: AgentHarness
    private let server: ControlServer
    private let task: Task<Void, Never>
    init(payload: Data) throws {
        harness = try AgentHarness()
        let paths = try AgentPaths(directory: harness.dataDirectory)
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        self.server = server
        task = Task { [server] in
            await server.run { _ in
                var response = ControlResponse(failure: "")
                response.ok = true; response.error = nil; response.exitCode = 0; response.payload = payload
                return response
            }
        }
    }
    func stop() async { server.stop(); await task.value }
}

/// What a `--json` command printed: exactly one JSON object, or nil.
func jsonObject(_ output: Data) -> [String: Any]? {
    let trimmed = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
}
