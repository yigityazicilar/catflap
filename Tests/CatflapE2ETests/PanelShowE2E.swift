import CatflapCore
import Foundation
import Synchronization
import Testing

/// The commands a stand-in agent was sent, in order.
private final class ReceivedCommands: Sendable {
    private let list = Mutex<[String]>([])
    func add(_ command: String) { list.withLock { $0.append(command) } }
    var all: [String] { list.withLock { $0 } }
}

/// A stand-in agent on a real control socket whose panel is hidden: `ui.state` always says
/// so. It keeps every command it is sent. One that does not know `panel.show` refuses it as
/// an agent from before that command does.
private final class PanelDouble: @unchecked Sendable {
    let harness: AgentHarness
    let received: ReceivedCommands
    private let server: ControlServer
    private let task: Task<Void, Never>
    init(knowsPanelShow: Bool) throws {
        harness = try AgentHarness()
        let paths = try AgentPaths(directory: harness.dataDirectory)
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        self.server = server
        let commands = ReceivedCommands()
        received = commands
        task = Task { [server] in
            await server.run { request in
                commands.add(request.command)
                var focused = UIState()
                focused.visible = true; focused.mode = "focused"; focused.hasFocus = true
                switch request.command {
                case "ui.state": return (try? ControlResponse(value: UIState())) ?? ControlResponse(error: .storage)
                case "toggle": return (try? ControlResponse(value: focused)) ?? ControlResponse(error: .storage)
                case "panel.show" where knowsPanelShow: return (try? ControlResponse(value: focused)) ?? ControlResponse(error: .storage)
                default: return ControlResponse(error: .invalidRequest, exitCode: 64)
                }
            }
        }
    }
    func stop() async { server.stop(); await task.value }
    /// Starts the app again while this agent runs.
    func launchAgain() async throws -> CommandResult {
        let executable = harness.executable, folder = harness.dataDirectory.path
        return try await onThread { try runCatflap(executable, ["agent", "--show-if-running", "--data-dir", folder]) }
    }
}

/// What a second launch of the app asks of the agent that already runs.
@Suite(.timeLimit(.minutes(5))) struct PanelShowE2E {
    /// It asks for `panel.show` alone, which never hides the panel. Asking for `ui.state` and
    /// then sending `toggle` would hide a panel that opened between the two requests.
    @Test func testSecondLaunchSendsPanelShowAndNeverToggle() async throws {
        let agent = try PanelDouble(knowsPanelShow: true)
        let launched = try await agent.launchAgain()
        await agent.stop()
        #expect(launched.code == 0, "the launch ended with status \(launched.code)")
        #expect(agent.received.all == ["panel.show"], "the launch sent \(agent.received.all)")
        #expect(!agent.received.all.contains("toggle"), "the launch sent toggle")
    }

    /// An agent from before `panel.show` refuses it as an invalid request; the launch then
    /// asks for the panel's state and opens the hidden panel with `toggle`, as it used to.
    @Test func testSecondLaunchFallsBackForAnAgentWithoutPanelShow() async throws {
        let agent = try PanelDouble(knowsPanelShow: false)
        let launched = try await agent.launchAgain()
        await agent.stop()
        #expect(launched.code == 0, "the launch ended with status \(launched.code)")
        #expect(agent.received.all == ["panel.show", "ui.state", "toggle"], "the launch sent \(agent.received.all)")
    }
}
