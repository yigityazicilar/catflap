import CatflapCore
import Foundation
import Testing

struct AgentE2E {
    @Test func testStatusAndEmptyHistory() throws {
        let agent = try AgentHarness()
        try agent.start()
        defer { agent.stop() }
        let status = try agent.command(["status"])
        #expect(status.code == 0)
        let first = try status.decode(AgentStatus.self)
        #expect(first.running && !first.serverRunning && first.pairedDevices == 0)
        #expect(first.schemaVersion == 1)
        // A test agent runs without its platform module, so it never watches a real clipboard.
        #expect(first.clipboardCapture == "off")
        let refusedErase = try agent.eraseIdentity()
        #expect(refusedErase.code == 1)
        #expect(String(decoding: refusedErase.error, as: UTF8.self) == "An agent is already running for this data directory.\n")
        let history = try agent.command(["history"])
        #expect(history.code == 0)
        #expect(try history.decode([HistoryRecord].self).isEmpty)
        let devices = try agent.command(["devices"])
        #expect(devices.code == 0)
        #expect(try devices.decode([DeviceSummary].self).isEmpty)
        let secondAgent = Process()
        secondAgent.executableURL = agent.executable
        secondAgent.arguments = ["agent", "--data-dir", agent.dataDirectory.path]
        secondAgent.environment = agentEnvironment(overrides: [:])
        let secondError = Pipe()
        secondAgent.standardOutput = FileHandle.nullDevice; secondAgent.standardError = secondError
        try secondAgent.run()
        var end = waitForEnd(of: secondAgent, limit: 5)
        if end == .stillRunning { secondAgent.terminate(); end = waitForEnd(of: secondAgent, limit: 5) }
        if end == .stillRunning { kill(secondAgent.processIdentifier, SIGKILL); end = waitForEnd(of: secondAgent, limit: 5) }
        #expect(end == .ended(status: 1))
        let message = String(decoding: secondError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(message == "An agent is already running for this data directory.\n")
        #expect(!message.contains("Usage:"))
        for command in ["send", "clip"] { #expect(try agent.command([command]).code == 64) }
        let barePair = try agent.command(["pair"])
        #expect(barePair.code == 64)
        let pairUsage = try JSONSerialization.jsonObject(with: barePair.output) as? [String: Any]
        #expect(pairUsage?["ok"] as? Bool == false)
        #expect(pairUsage?["error"] as? String == #"Use "catflap pair start" on one device and "catflap pair join <code>" on the other."#)
        #expect(try agent.command(["toggle"]).decode(UIState.self).visible)
        #expect(try agent.command(["ui", "state"]).decode(UIState.self).mode == "focused")
        #expect(try agent.command(["ui", "invoke", "hide"]).decode(UIState.self).visible == false)
        try agent.restart()
        let restarted = try agent.command(["status"]).decode(AgentStatus.self)
        #expect(restarted.deviceID == first.deviceID)
        #expect(!restarted.serverRunning)
        #expect(try agent.command(["history"]).decode([HistoryRecord].self).isEmpty)
        agent.stop()
        let erased = try agent.eraseIdentity()
        #expect(erased.code == 0)
        #expect(FileManager.default.fileExists(atPath: agent.dataDirectory.appendingPathComponent("identity.json").path) == false)
        try agent.start()
        #expect(try agent.command(["status"]).decode(AgentStatus.self).deviceID != first.deviceID)
        agent.stop()
        let help = try runHarnessProcess(agent.executable, arguments: ["--help"])
        #expect(help.code == 0)
        #expect(!String(decoding: help.output, as: UTF8.self).contains("erase-identity"))
        print("binary identity cleanup: erased; next start created a different device id")
    }
    /// With its platform module on, the agent starts it, reports what it says, and stops it on
    /// SIGTERM within the harness's limit. Run only on Linux, with no display: capture has no
    /// compositor to watch and must say "unsupported" without failing the agent. On macOS the
    /// module would watch the real pasteboard, which a test must not do.
    #if os(Linux)
    @Test func testPlatformModuleStartsAndStopsWithTheAgent() throws {
        let agent = try AgentHarness(environment: ["CATFLAP_PLATFORM": "on"])
        try agent.start()
        defer { agent.stop() }
        let status = try agent.command(["status"])
        #expect(status.code == 0)
        let decoded = try status.decode(AgentStatus.self)
        #expect(decoded.clipboardCapture == "unsupported")
        #expect(decoded.pasteboardAccess == nil)
        let keys = try JSONSerialization.jsonObject(with: status.output) as? [String: Any]
        #expect(keys?["clipboard_capture"] as? String == "unsupported")
        #expect(keys?["pasteboard_access"] == nil)
    }
    #endif
}
