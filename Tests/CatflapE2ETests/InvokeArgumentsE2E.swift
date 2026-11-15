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
}
