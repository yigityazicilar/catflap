import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Runs `catflap` with the test agent environment (platform off, no display), so a command
/// that turned out to start an agent could never watch the person's clipboard.
func runCatflap(_ executable: URL, _ arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 30) throws -> CommandResult {
    let child = Process(); let output = harnessPipe(); let error = harnessPipe()
    child.executableURL = executable
    child.arguments = arguments
    child.environment = agentEnvironment(overrides: environment)
    child.standardOutput = output; child.standardError = error
    try child.run()
    let readers = HarnessReaders(output: output, error: error)
    let end = waitForEnd(of: child, limit: timeout)
    if end == .stillRunning { kill(child.processIdentifier, SIGKILL); _ = waitForEnd(of: child, limit: 5) }
    let drained = readers.finish(limit: 30, command: arguments.first ?? "")
    guard case .ended(let status) = end else { throw HarnessError.commandTimedOut }
    guard let drained else { throw HarnessError.outputNotClosed }
    guard let status else { throw HarnessError.exitStatusLost }
    return CommandResult(code: status, output: drained.output, error: drained.error, command: arguments.first ?? "")
}

/// How the agent process ends when its control listener fails, and what a second launch of
/// the app does while an agent runs.
@Suite(.timeLimit(.minutes(5))) struct AgentLifecycleE2E {
    /// The listener's poll fails while the agent runs: the agent stops with status 1 and a
    /// fixed sentence, its socket is gone, and its lock is free for the next agent.
    @Test func testFailedControlListenerStopsTheAgentAndFreesItsFolder() async throws {
        let agent = try AgentHarness()
        let socket = agent.dataDirectory.appendingPathComponent("control.sock")
        let result = try await onThread { () -> CommandResult in
            // The first poll is real; once a request has been taken, the next one fails.
            let child = Process(); let output = harnessPipe(); let error = harnessPipe()
            child.executableURL = agent.executable
            child.arguments = ["agent", "--data-dir", agent.dataDirectory.path]
            child.environment = agentEnvironment(overrides: ["CATFLAP_TEST_CONTROL_FAULT": "poll"])
            child.standardOutput = output; child.standardError = error
            try child.run()
            let readers = HarnessReaders(output: output, error: error)
            // Requests until the agent ends; the limit only stops a hang.
            var ended = ChildEnd.stillRunning
            let start = ContinuousClock.now
            while case .stillRunning = ended, start.duration(to: .now) < .seconds(60) {
                _ = try? ControlClient.request(.init("status"), socket: socket)
                ended = waitForEnd(of: child, limit: 0.05)
            }
            if case .stillRunning = ended { kill(child.processIdentifier, SIGKILL); ended = waitForEnd(of: child, limit: 5) }
            let drained = readers.finish(limit: 30, command: "agent")
            guard case .ended(let status) = ended, let status, let drained else { throw HarnessError.exitStatusLost }
            return CommandResult(code: status, output: drained.output, error: drained.error, command: "agent")
        }
        #expect(result.code == 1, "the agent ended with status \(result.code)")
        #expect(String(decoding: result.error, as: UTF8.self).contains(ControlServer.listenerFailure), "standard error: \(result.error.count) bytes")
        #expect(!FileManager.default.fileExists(atPath: socket.path), "the failed agent left its socket")
        // The folder's lock is free: an ordinary agent starts there and answers.
        try await onThread { try agent.start() }
        #expect(try await onThread { try agent.command(["status"]) }.code == 0)
        agent.stop()
    }

    /// A launch that means "open Catflap" (the app started again) shows the running agent's
    /// panel focused and exits 0, and again leaves it focused; an explicit second
    /// `catflap agent` is still refused.
    @Test func testSecondAppLaunchShowsThePanelAndASecondAgentIsRefused() async throws {
        let agent = try AgentHarness(); defer { agent.stop() }
        try await onThread { try agent.start() }
        for round in 1...2 {
            let shown = try await onThread { try runCatflap(agent.executable, ["agent", "--show-if-running", "--data-dir", agent.dataDirectory.path]) }
            #expect(shown.code == 0, "launch \(round) ended with status \(shown.code)")
            let state = try await onThread { try agent.command(["ui", "state"]) }.decode(UIState.self)
            #expect(state.visible && state.hasFocus && state.mode == "focused",
                    "launch \(round) left the panel \(state.mode), focus \(state.hasFocus)")
        }
        let second = try await onThread { try runCatflap(agent.executable, ["agent", "--data-dir", agent.dataDirectory.path]) }
        #expect(second.code == 1)
        #expect(String(decoding: second.error, as: UTF8.self).contains(AgentError.alreadyRunning.rawValue))
        // The first agent is unaffected.
        #expect(try await onThread { try agent.command(["status"]) }.code == 0)
    }
}
