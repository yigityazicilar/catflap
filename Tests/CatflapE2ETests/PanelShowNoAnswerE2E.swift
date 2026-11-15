import CatflapCore
import Foundation
import Synchronization
import Testing

/// A stand-in agent that takes `panel.show` and never answers it, until released.
private final class SilentPanelDouble: @unchecked Sendable {
    let harness: AgentHarness
    private let server: ControlServer
    private let task: Task<Void, Never>
    private let released = SharedValue(false)
    init() throws {
        harness = try AgentHarness()
        let paths = try AgentPaths(directory: harness.dataDirectory)
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        self.server = server
        let released = self.released
        task = Task { [server] in
            await server.run { _ in
                while !released.get() { try? await Task.sleep(for: .milliseconds(100)) }
                return ControlResponse(error: .invalidRequest, exitCode: 64)
            }
        }
    }
    func stop() async { released.update { $0 = true }; server.stop(); await task.value }
}

/// A second launch whose `panel.show` gets no answer says that the agent did not answer, with
/// the status every other command gives for it, not that an agent is already running.
@Suite(.timeLimit(.minutes(5))) struct PanelShowNoAnswerE2E {
    @Test func testSecondLaunchThatGetsNoAnswerSaysSo() async throws {
        let agent = try SilentPanelDouble()
        let executable = agent.harness.executable, folder = agent.harness.dataDirectory.path
        // The client's own reply wait (60 s) ends it; the limit here is only a hang guard.
        let launched = try await onThread { try runHarnessProcess(executable, arguments: ["agent", "--show-if-running", "--data-dir", folder], timeout: 150) }
        await agent.stop()
        #expect(launched.code == 69, "the launch ended with status \(launched.code)")
        #expect(String(decoding: launched.error, as: UTF8.self) == AgentError.noAnswer.rawValue + "\n")
    }
}
