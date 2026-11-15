import ArgumentParser
import CatflapCore
import Foundation

/// The one place a `catflap` command ends. With `--json`, every failure ends as one JSON
/// error object on standard output: a command line the parser refuses with status 64, and a
/// reply from the agent that cannot be read with status 1. Without `--json`, the parser's own
/// usage message goes to standard error as before. Neither sentence repeats an argument or
/// anything the agent sent, which can be a pairing code or a clipboard item.
enum CommandBoundary {
    static let usage = "That command line is not valid. Run `catflap help` to see how to use it."
    static let unreadable = "The agent's reply could not be read."

    static func run(_ arguments: [String]) async -> Never {
        let json = wantsJSON(arguments)
        var command: ParsableCommand
        do { command = try await Catflap.asyncParseAsRoot(arguments) }
        catch {
            let code = Catflap.exitCode(for: error)
            // A help request is not a failure, and its text is the answer.
            guard json, code != .success else { Catflap.exit(withError: error) }
            fail(usage, json: true, code: code)
        }
        do {
            if var asyncCommand = command as? AsyncParsableCommand { try await asyncCommand.run() }
            else { try command.run() }
        } catch let code as ExitCode {
            // The command has said what it had to say.
            Catflap.exit(withError: code)
        } catch {
            let code = Catflap.exitCode(for: error)
            if code == .success { Catflap.exit(withError: error) }
            if code == .validationFailure { fail(usage, json: json, code: code) }
            fail(unreadable, json: json, code: .failure)
        }
        Catflap.exit()
    }

    /// `--json` among the options, before any `--` that ends them.
    static func wantsJSON(_ arguments: [String]) -> Bool {
        arguments.prefix { $0 != "--" }.contains("--json")
    }

    private static func fail(_ message: String, json: Bool, code: ExitCode) -> Never {
        if json, let text = try? ControlJSON.text(ClientErrorOutput(error: message)) { print(text) }
        else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        Catflap.exit(withError: code)
    }
}

/// A successful reply whose payload is not what the command expects.
struct UnreadableReply: Error {}

extension AgentError {
    /// What a command says when its request to the agent failed: that the agent did not
    /// answer in time, with status 69 (`EX_UNAVAILABLE`), or else that it cannot be reached,
    /// with status 1. 75 is kept for a send that is waiting for a device that is away.
    static func unanswered(_ error: any Error) -> (message: String, code: Int32) {
        if error as? AgentError == .noAnswer { return (AgentError.noAnswer.rawValue, 69) }
        return (AgentError.control.rawValue, 1)
    }
}

extension ControlResponse {
    /// Decodes the payload, or throws `UnreadableReply`.
    func expect<T: Decodable>(_ type: T.Type) throws -> T {
        do { return try decode(type) } catch { throw UnreadableReply() }
    }
    /// Checks that the payload is a JSON object, for replies whose shape belongs to the
    /// platform module.
    func expectObject() throws {
        guard (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else { throw UnreadableReply() }
    }
}
