import ArgumentParser
import CatflapCore
import CTailcat
import Foundation
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
                      Pair.self, Unpair.self, Send.self, Clip.self, Version.self, EraseIdentity.self])
}

struct ClientErrorOutput: Encodable {
    let ok = false
    let error: String
}

struct ClientOptions: ParsableArguments {
    @Option(name: .long, help: "Agent data directory.") var dataDir: String?
    @Flag(name: .long, help: "Print JSON.") var json = false
    var socket: URL { URL(fileURLWithPath: dataDir ?? AgentPaths.defaultDirectory.path).appendingPathComponent("control.sock") }
    func call(_ command: String, arguments: [String: String] = [:]) throws {
        let response: ControlResponse
        do { response = try ControlClient.request(.init(command, arguments: arguments), socket: socket) }
        catch {
            if json { print(try ControlJSON.text(ClientErrorOutput(error: AgentError.control.rawValue))) }
            else { FileHandle.standardError.write(Data("Cannot reach the agent control channel.\n".utf8)) }
            throw ExitCode.failure
        }
        guard response.ok else {
            if json {
                print(try ControlJSON.text(ClientErrorOutput(error: response.error ?? "Control request failed.")))
            } else { FileHandle.standardError.write(Data(((response.error ?? "Control request failed.") + "\n").utf8)) }
            throw ExitCode(response.exitCode)
        }
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
    mutating func run() async throws {
        // New sockets, database sidecars and any platform-created files are private from creation.
        umask(0o077)
        do {
            let paths = try AgentPaths(directory: URL(fileURLWithPath: dataDir ?? AgentPaths.defaultDirectory.path))
            let lock = try AgentLock(paths: paths)
            let runtime = try AgentRuntime(paths: paths)
            try await Pair.install(on: runtime)
            try await Send.install(on: runtime)
            try await Clip.install(on: runtime)
            try await runtime.start()
            let control = try ControlServer(paths: paths, lock: lock)
            let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            term.setEventHandler { continuation.yield(()) }
            interrupt.setEventHandler { continuation.yield(()) }
            term.resume(); interrupt.resume()
            let task = Task { await control.run { await runtime.handle($0) } }
            for await _ in signals { break }
            control.stop(); await task.value
            continuation.finish(); term.cancel(); interrupt.cancel()
            await runtime.stop()
            withExtendedLifetime(control) {}
        } catch {
            reportAgentError(error)
            throw ExitCode.failure
        }
    }
}
struct Status: ParsableCommand {
    @OptionGroup var options: ClientOptions
    func run() throws { try options.call("status") }
}
struct Devices: ParsableCommand {
    @OptionGroup var options: ClientOptions
    func run() throws { try options.call("devices") }
}
struct Toggle: ParsableCommand {
    @OptionGroup var options: ClientOptions
    func run() throws { try options.call("toggle") }
}
struct UI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ui", subcommands: [State.self, Invoke.self])
    struct State: ParsableCommand {
        @OptionGroup var options: ClientOptions
        func run() throws { try options.call("ui.state") }
    }
    struct Invoke: ParsableCommand {
        @OptionGroup var options: ClientOptions
        @Argument var action: String
        func run() throws { try options.call("ui.invoke", arguments: ["action": action]) }
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
