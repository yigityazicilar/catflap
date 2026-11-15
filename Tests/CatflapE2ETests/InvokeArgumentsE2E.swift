import CatflapCore
import Foundation
import Testing

/// `ui invoke` passes files to the agent: Dolphin's "Choose in Catflap…" menu entry runs
/// `catflap ui invoke attach --file %f`. A test agent has no panel, so it refuses the action
/// itself, with its own sentence in the JSON output. A command line that did not accept
/// `--file` would stop before asking the agent and print nothing on standard output.
struct InvokeArgumentsE2E {
    @Test func testInvokeAcceptsFilesAndAsksTheAgent() throws {
        let agent = try AgentHarness()
        try agent.start()
        defer { agent.stop() }
        let file = agent.dataDirectory.appendingPathComponent("a note.txt")
        try Data("a note".utf8).write(to: file)
        let result = try agent.command(["ui", "invoke", "attach", "--file", file.path, "--file", file.path])
        let reply = try JSONSerialization.jsonObject(with: result.output) as? [String: Any]
        #expect(reply?["error"] as? String == AgentError.unsupported.rawValue)
        #expect(!String(decoding: result.error, as: UTF8.self).contains("--file"))
    }

    /// A file manager's `%F` gives several absolute paths as separate arguments, folders
    /// included. They reach the agent in one request, in order, spaces kept.
    @Test func testInvokeTakesSeveralPathsAsArguments() async throws {
        let double = try RecordingAgentDouble { _ in answering(UIState()) }
        let base = double.harness.dataDirectory
        let paths = ["first note.txt", "second  note.txt", "third note .txt", "a folder"].map { base.appendingPathComponent($0).path }
        try FileManager.default.createDirectory(atPath: paths[3], withIntermediateDirectories: true)
        for path in paths.prefix(3) { try Data("x".utf8).write(to: URL(fileURLWithPath: path)) }
        let result = try await onThread { try double.harness.command(["ui", "invoke", "attach"] + paths) }
        await double.stop()
        #expect(result.code == 0, "status \(result.code)")
        let sent = double.requests.filter { $0.command == "ui.invoke" }
        #expect(sent.count == 1)
        #expect(sent.first?.arguments["action"] == "attach")
        #expect(sent.first?.arguments["files"] == paths.joined(separator: "\n"))
    }

    /// Paths given as arguments must be absolute: the agent does not share this command's
    /// working directory, and a file manager always gives absolute ones.
    @Test func testRelativePathArgumentIsAUsageError() throws {
        let harness = try AgentHarness()
        let result = try harness.command(["ui", "invoke", "attach", "relative note.txt"])
        #expect(result.code == 64)
    }
}
