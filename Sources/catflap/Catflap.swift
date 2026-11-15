import ArgumentParser
import CatflapCore
import CTailcat
import Foundation
#if os(Linux)
import CatflapLinux
#elseif os(macOS)
import CatflapMac
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct Catflap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catflap", abstract: "Local Catflap agent and control client.",
        subcommands: [Agent.self, Status.self, Devices.self, History.self, Toggle.self, UI.self,
                      Pair.self, Unpair.self, Send.self, Clip.self, Audit.self, Version.self, EraseIdentity.self])

    static func main() async {
        #if os(macOS)
        // Finder, `open` and a double click start Catflap.app with no arguments: that is the
        // agent. A bare `catflap` with no arguments still prints its help.
        if CommandLine.arguments.count == 1, Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" {
            // Started again while an agent runs, it shows that agent's panel instead.
            await CommandBoundary.run(["agent", "--show-if-running"])
        }
        #endif
        await CommandBoundary.run(Array(CommandLine.arguments.dropFirst()))
    }
}

struct ClientErrorOutput: Encodable {
    let ok = false
    let error: String
}

struct ClientOptions: ParsableArguments {
    @Option(name: .long, help: "Agent data directory.") var dataDir: String?
    @Flag(name: .long, help: "Print JSON.") var json = false
    var socket: URL { URL(fileURLWithPath: dataDir ?? AgentPaths.defaultDirectory.path).appendingPathComponent("control.sock") }
    /// One request, printed as the agent's JSON once it has the shape `expect` checks for.
    func call(_ command: String, arguments: [String: String] = [:], expect: (ControlResponse) throws -> Void) throws {
        let response: ControlResponse
        do { response = try ControlClient.request(.init(command, arguments: arguments), socket: socket) }
        catch {
            let failure = AgentError.unanswered(error)
            if json { print(try ControlJSON.text(ClientErrorOutput(error: failure.message))) }
            else { FileHandle.standardError.write(Data((failure.message + "\n").utf8)) }
            throw ExitCode(failure.code)
        }
        guard response.ok else {
            if json {
                print(try ControlJSON.text(ClientErrorOutput(error: response.error ?? "Control request failed.")))
            } else { FileHandle.standardError.write(Data(((response.error ?? "Control request failed.") + "\n").utf8)) }
            throw ExitCode(response.exitCode)
        }
        try expect(response)
        // JSON is also the stable text representation until platform presentation lands.
        print(String(decoding: response.payload, as: UTF8.self))
    }
    func unavailable() throws {
        if json { print(try ControlJSON.text(ClientErrorOutput(error: AgentError.unsupported.rawValue))) }
        else { FileHandle.standardError.write(Data("This command is not available yet.\n".utf8)) }
        throw ExitCode(64)
    }
}

struct Agent: AsyncParsableCommand {
    @Option(name: .long) var dataDir: String?
    /// What opening the app means: when an agent already runs for this folder, show its panel
    /// and end with status 0. Without it a second agent is refused.
    @Flag(name: .long, help: .hidden) var showIfRunning = false
    mutating func run() async throws {
        // New sockets, database sidecars and any platform-created files are private from creation.
        umask(0o077)
        var listenerFailed = false
        do {
            let paths = try AgentPaths(directory: URL(fileURLWithPath: dataDir ?? AgentPaths.defaultDirectory.path))
            let lock: AgentLock
            do { lock = try AgentLock(paths: paths) }
            catch AgentError.alreadyRunning where showIfRunning {
                guard await Self.showPanel(of: paths) else { throw AgentError.alreadyRunning }
                return
            }
            let runtime = try AgentRuntime(paths: paths)
            AgentRuntime.setProcess(runtime)
            try await Pair.install(on: runtime)
            try await Send.install(on: runtime)
            try await Clip.install(on: runtime)
            try await Audit.install(on: runtime)
            try await runtime.start()
            let control = try ControlServer(paths: paths, lock: lock)
            // For the test of a listener that fails while the agent runs.
            if ProcessInfo.processInfo.environment["CATFLAP_TEST_CONTROL_FAULT"] == "poll" { control.inject(.pollFails(errno: EBADF, afterPolls: 1)) }
            // The desktop side: clipboard capture, later the panel. CATFLAP_PLATFORM=off runs
            // the agent without it, for tests (whose agents must not watch the person's real
            // clipboard) and for a machine with no desktop session.
            let platform: Platform?
            if ProcessInfo.processInfo.environment["CATFLAP_PLATFORM"] == "off" {
                await runtime.setPlatformStatus(PlatformStatus(clipboardCapture: "off"))
                platform = nil
            } else {
                platform = try await Platform.start(on: runtime)
            }
            let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            term.setEventHandler { continuation.yield(()) }
            interrupt.setEventHandler { continuation.yield(()) }
            term.resume(); interrupt.resume()
            // A listener that fails ends the agent as a signal does, then with status 1.
            let task = Task { await control.run { await runtime.handle($0) }; continuation.yield(()) }
            for await _ in signals { break }
            control.stop(); await task.value
            continuation.finish(); term.cancel(); interrupt.cancel()
            await platform?.stop()
            await runtime.stop()
            AgentRuntime.setProcess(nil)
            listenerFailed = control.listenerFailed
            withExtendedLifetime(control) {}
            withExtendedLifetime(lock) {}
        } catch {
            reportAgentError(error)
            throw ExitCode.failure
        }
        // The socket and the lock were released with the server above.
        if listenerFailed {
            FileHandle.standardError.write(Data((ControlServer.listenerFailure + "\n").utf8))
            throw ExitCode.failure
        }
    }
    /// Asks the agent that runs for `paths` to show its panel with `panel.show`, which opens it
    /// focused and never hides it. An agent from before that command refuses it as invalid;
    /// that one is asked for the panel's state, and a hidden panel is opened with `toggle`.
    /// False if that agent cannot be asked.
    private static func showPanel(of paths: AgentPaths) async -> Bool {
        guard let shown = try? await ControlClient.requestAsync(.init("panel.show"), socket: paths.socket) else { return false }
        if shown.ok { return true }
        guard shown.error == AgentError.invalidRequest.rawValue else { return false }
        guard let state = try? await ControlClient.requestAsync(.init("ui.state"), socket: paths.socket), state.ok,
              let shape = (try? JSONSerialization.jsonObject(with: state.payload)) as? [String: Any] else { return false }
        if shape["visible"] as? Bool == true { return true }
        guard let toggled = try? await ControlClient.requestAsync(.init("toggle"), socket: paths.socket) else { return false }
        return toggled.ok
    }
}
struct Status: ParsableCommand {
    @OptionGroup var options: ClientOptions
    func run() throws { try options.call("status") { _ = try $0.expect(AgentStatus.self) } }
}
struct Devices: ParsableCommand {
    @OptionGroup var options: ClientOptions
    func run() throws { try options.call("devices") { _ = try $0.expect([DeviceSummary].self) } }
}
struct Toggle: ParsableCommand {
    @OptionGroup var options: ClientOptions
    func run() throws { try options.call("toggle") { try $0.expectObject() } }
}
struct UI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ui", subcommands: [State.self, Invoke.self])
    struct State: ParsableCommand {
        @OptionGroup var options: ClientOptions
        func run() throws { try options.call("ui.state") { try $0.expectObject() } }
    }
    struct Invoke: ParsableCommand {
        @OptionGroup var options: ClientOptions
        @Argument var action: String
        @Option(name: .long, help: "A file for the action, such as attach. Repeat for several.") var file: [String] = []
        func run() throws {
            var arguments = ["action": action]
            // Absolute paths: the agent does not share this command's working directory.
            let paths = file.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            if !paths.isEmpty { arguments["files"] = paths.joined(separator: "\n") }
            try options.call("ui.invoke", arguments: arguments) { try $0.expectObject() }
        }
    }
}
struct Version: ParsableCommand {
    @Flag(name: .long) var json = false
    private struct Output: Encodable {
        let version = "0.1.0-dev"
        let tailcatABI: UInt32
        enum CodingKeys: String, CodingKey { case version, tailcatABI = "tailcat_abi" }
    }
    func run() throws {
        if json { print(try ControlJSON.text(Output(tailcatABI: tc_abi_version()))) }
        else { print("Catflap 0.1.0-dev"); print("tailcat-abi \(tc_abi_version())") }
    }
}
