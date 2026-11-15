import ArgumentParser
import CatflapCore
import Foundation

/// Requests to the agent for a command that makes several of them. A refusal, or an agent
/// that cannot be reached, ends the command with the reason: JSON on standard output with
/// `--json`, a line on standard error without.
struct AgentCall {
    let options: ClientOptions

    func request(_ command: String, _ arguments: [String: String] = [:]) async throws -> ControlResponse {
        let response: ControlResponse
        do { response = try await ControlClient.requestAsync(.init(command, arguments: arguments), socket: options.socket) }
        catch { let failure = AgentError.unanswered(error); try fail(failure.message, code: failure.code) }
        guard response.ok else { try fail(response.error ?? "Control request failed.", code: response.exitCode) }
        return response
    }
    func fail(_ message: String, code: Int32) throws -> Never {
        if options.json { print(try ControlJSON.text(ClientErrorOutput(error: message))) }
        else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        throw ExitCode(code)
    }
    /// Paired devices, as the agent lists them.
    func devices() async throws -> [DeviceSummary] {
        try await request("devices").expect([DeviceSummary].self)
    }
    /// The device a person named: its id, or its name compared case-insensitively.
    func resolve(_ name: String, in devices: [DeviceSummary]) throws -> DeviceSummary {
        if let exact = devices.first(where: { $0.id == name }) { return exact }
        let named = devices.filter { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
        if named.count > 1 { try fail("More than one paired device has that name: use its id.", code: 64) }
        guard let device = named.first else { try fail("No paired device has that name or id.", code: 1) }
        return device
    }
}

/// Paths given as arguments, as a file manager passes them: each must be absolute, since the
/// agent does not share this command's working directory.
func absolutePaths(_ arguments: [String], call: AgentCall) throws -> [String] {
    for path in arguments where !path.hasPrefix("/") { try call.fail("Paths given as arguments must be absolute.", code: 64) }
    return arguments.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
}
