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
        let secondError = Pipe()
        secondAgent.standardOutput = FileHandle.nullDevice; secondAgent.standardError = secondError
        try secondAgent.run()
        let deadline = Date().addingTimeInterval(5)
        while secondAgent.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if secondAgent.isRunning { secondAgent.terminate() }
        secondAgent.waitUntilExit()
        #expect(secondAgent.terminationStatus == 1)
        let message = String(decoding: secondError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(message == "An agent is already running for this data directory.\n")
        #expect(!message.contains("Usage:"))
        for command in ["pair", "send", "clip"] { #expect(try agent.command([command]).code == 64) }
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
}
