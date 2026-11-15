import CatflapCore
import Foundation
import Testing

/// With `--json`, every way a command can fail ends in one JSON error object on standard
/// output: a usage error with status 64, a reply the command cannot read with a nonzero one.
@Suite(.timeLimit(.minutes(10))) struct CLIBoundaryE2E {
    /// Each client subcommand with arguments its parser or its own checks refuse. The harness
    /// adds `--data-dir` and `--json`.
    static let badArguments: [[String]] = [
        ["status", "extra"], ["status", "--no-such-option"],
        ["devices", "extra"], ["history", "--search"], ["history", "one", "two"],
        ["toggle", "extra"],
        ["ui", "state", "extra"], ["ui", "invoke"], ["ui", "invoke", "toggle", "extra"], ["ui", "invoke", "attach", "--file"],
        ["pair"], ["pair", "extra"],
        ["pair", "start", "extra"], ["pair", "join"], ["pair", "join", "one", "two"], ["pair", "status", "--no-such-option"],
        ["pair", "confirm", "extra"], ["pair", "decline", "extra"], ["pair", "check"],
        ["unpair"], ["unpair", "one", "two"],
        ["send"], ["send", "--text"], ["send", "--text", "a", "--file", "b"], ["send", "--no-such-option"],
        ["clip"], ["clip", "no-such-action"], ["clip", "list", "one", "two"], ["clip", "add", "--text"], ["clip", "add"],
        ["clip", "keep"], ["clip", "delete"], ["clip", "get"], ["clip", "pause", "maybe"], ["clip", "send", "--latest", "id"],
        ["clip", "list", "--latest"],
        ["audit", "--also"], ["audit", "extra"],
        ["transfers", "no-such-action"], ["transfers", "list", "--waiting", "--active"], ["transfers", "list", "--limit", "0"],
        ["transfers", "show"], ["transfers", "cancel"], ["transfers", "cancel", "id", "--send", "sid"], ["transfers", "retry"],
        ["inbox", "extra"], ["inbox", "--set"], ["send", "--to", "device", "relative/path"], ["ui", "invoke", "attach", "relative"],
        ["version", "extra"], ["agent", "--no-such-option"], ["erase-identity", "--no-such-option"],
        ["no-such-command"],
    ]
    /// Each client subcommand with good arguments, so it reaches the agent.
    static let requests: [[String]] = [
        ["status"], ["devices"], ["history"], ["history", "--search", "word"], ["toggle"], ["ui", "state"], ["ui", "invoke", "toggle"],
        ["pair", "start", "--no-wait"], ["pair", "join", "code"], ["pair", "status"], ["pair", "confirm"], ["pair", "decline"],
        ["pair", "check", "device"], ["unpair", "device"],
        ["send", "--text", "hello", "--to", "device"], ["send", "--text", "hello"], ["send", "--retry", "id", "--to", "device"],
        ["clip", "list"], ["clip", "list", "--search", "word"], ["clip", "get", "id"], ["clip", "add", "--text", "hello"],
        ["clip", "keep", "id"], ["clip", "delete", "id"], ["clip", "pause"], ["clip", "pause", "on"],
        ["clip", "send", "id", "--to", "device"], ["clip", "send", "id"], ["clip", "send", "--latest"],
        ["audit"],
        ["transfers", "list"], ["transfers", "list", "--waiting"], ["transfers", "show", "id", "--to", "device"], ["transfers", "show", "id"],
        ["transfers", "cancel", "id", "--to", "device"], ["transfers", "cancel", "--send", "sid"], ["transfers", "retry", "id", "--to", "device"],
        ["inbox"], ["inbox", "--set", "/nonexistent/inbox"],
    ]
    /// Successful envelopes whose payload is null, the wrong type, or cut short.
    static let payloads = ["null", "\"wrong type\"", "{\"id\":\"cut"]

    private func describe(_ arguments: [String], _ result: CommandResult) -> String {
        "`\(arguments.prefix(3).joined(separator: " "))`: status \(result.code), \(result.output.count) bytes on standard output"
    }

    @Test func testUsageErrorsAreJSONWithStatus64() async throws {
        // Nothing listens here: a command that got past its arguments would fail differently.
        let harness = try AgentHarness()
        for arguments in Self.badArguments {
            let result = try await onThread { try harness.command(arguments) }
            #expect(result.code == 64, "\(describe(arguments, result))")
            let object = jsonObject(result.output)
            #expect(object?["ok"] as? Bool == false, "\(describe(arguments, result)) is not one JSON error")
            #expect((object?["error"] as? String)?.isEmpty == false, "\(describe(arguments, result))")
        }
    }

    @Test(arguments: payloads) func testUnreadableRepliesAreJSONErrors(_ payload: String) async throws {
        let double = try AgentDouble(payload: Data(payload.utf8))
        for arguments in Self.requests {
            let result = try await onThread { try double.harness.command(arguments) }
            #expect(result.code != 0, "\(describe(arguments, result)) for payload \(Self.payloads.firstIndex(of: payload)!)")
            let object = jsonObject(result.output)
            #expect(object?["ok"] as? Bool == false, "\(describe(arguments, result)) is not one JSON error, payload \(Self.payloads.firstIndex(of: payload)!)")
            #expect((object?["error"] as? String)?.isEmpty == false)
        }
        await double.stop()
    }
}
