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
                      Pair.self, Unpair.self, Send.self, Transfers.self, Inbox.self, Clip.self, Follow.self, Open.self, Audit.self, Version.self, EraseIdentity.self])

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
                switch await Self.showPanel(of: paths) {
                case .shown: return
                case .noAnswer:
                    // The agent took `panel.show` and gave no reply: say so, with the status
                    // every other command gives for it.
                    FileHandle.standardError.write(Data((AgentError.noAnswer.rawValue + "\n").utf8))
                    throw ExitCode(69)
                case .refused: throw AgentError.alreadyRunning
                }
            }
            let runtime = try AgentRuntime(paths: paths)
            AgentRuntime.setProcess(runtime)
            try await Pair.install(on: runtime)
            try await Send.install(on: runtime)
            try await Clip.install(on: runtime)
            try await Audit.install(on: runtime)
            // Presence: pings on request, and every 60 s while a panel holds a watch lease.
            let identityServer = await runtime.identityServer
            let identity = await identityServer.identity
            let presence = PresenceService(store: await runtime.store, clientKeys: identity.clientKeys)
            await presence.install(on: runtime)
            if let peers = await runtime.service(PeerService.self) {
                // A device that answers a check admits this one: that confirms a new pairing,
                // and its waiting deliveries are due.
                await presence.setHereHandler { id in await peers.answered(deviceID: id) }
            }
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
            await presence.stop()
            await runtime.service(FollowService.self)?.stop()
            await runtime.service(TransferService.self)?.stop()
            await runtime.stop()
            AgentRuntime.setProcess(nil)
            listenerFailed = control.listenerFailed
            withExtendedLifetime(control) {}
            withExtendedLifetime(lock) {}
        } catch let code as ExitCode {
            throw code
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
    enum Shown { case shown, noAnswer, refused }
    /// Asks the agent that runs for `paths` to show its panel with `panel.show`, which opens it
    /// focused and never hides it. An agent from before that command refuses it as invalid;
    /// that one is asked for the panel's state, and a hidden panel is opened with `toggle`.
    /// `noAnswer` when that agent took a request and did not answer it in time.
    private static func showPanel(of paths: AgentPaths) async -> Shown {
        func ask(_ command: String) async -> Result<ControlResponse, AgentError> {
            do { return .success(try await ControlClient.requestAsync(.init(command), socket: paths.socket)) }
            catch { return .failure(error as? AgentError == .noAnswer ? .noAnswer : .control) }
        }
        let shown: ControlResponse
        switch await ask("panel.show") {
        case .success(let reply): shown = reply
        case .failure(let error): return error == .noAnswer ? .noAnswer : .refused
        }
        if shown.ok { return .shown }
        guard shown.error == AgentError.invalidRequest.rawValue else { return .refused }
        let state: ControlResponse
        switch await ask("ui.state") {
        case .success(let reply): state = reply
        case .failure(let error): return error == .noAnswer ? .noAnswer : .refused
        }
        guard state.ok, let shape = (try? JSONSerialization.jsonObject(with: state.payload)) as? [String: Any] else { return .refused }
        if shape["visible"] as? Bool == true { return .shown }
        switch await ask("toggle") {
        case .success(let reply): return reply.ok ? .shown : .refused
        case .failure(let error): return error == .noAnswer ? .noAnswer : .refused
        }
    }
}
struct Status: ParsableCommand {
    @OptionGroup var options: ClientOptions
    func run() throws { try options.call("status") { _ = try $0.expect(AgentStatus.self) } }
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
        @Argument(help: "Absolute paths of files and folders, as a file manager's %F passes them.") var paths: [String] = []
        func run() throws {
            var arguments = ["action": action]
            // Absolute paths: the agent does not share this command's working directory.
            for path in paths where !path.hasPrefix("/") {
                if options.json { print(try ControlJSON.text(ClientErrorOutput(error: "Paths given as arguments must be absolute."))) }
                else { FileHandle.standardError.write(Data("Paths given as arguments must be absolute.\n".utf8)) }
                throw ExitCode(64)
            }
            let all = (file + paths).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            if !all.isEmpty { arguments["files"] = all.joined(separator: "\n") }
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
