import ArgumentParser
import CatflapCore
import Foundation

/// `catflap pair start` on one device, `catflap pair join <code>` on the other. The pairing
/// lives in the agent; these commands start it, poll it and confirm or decline it in short
/// requests, because a control request must be answered within a few seconds.
struct Pair: ParsableCommand, AgentFeature {
    static let configuration = CommandConfiguration(
        commandName: "pair", abstract: "Pair this device with another one.",
        subcommands: [Start.self, Join.self, PairStatus.self, Confirm.self, Decline.self, Check.self])
    @OptionGroup var options: ClientOptions

    func run() throws {
        // Pairing needs a direction: make a code here, or use one made elsewhere.
        let message = "Use \"catflap pair start\" on one device and \"catflap pair join <code>\" on the other."
        if options.json { print(try ControlJSON.text(ClientErrorOutput(error: message))) }
        else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        throw ExitCode(64)
    }

    static func install(on runtime: AgentRuntime) async throws {
        await PairingService.install(on: runtime)
    }

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Make a one-time code for the other device.")
        @OptionGroup var options: ClientOptions
        @Flag(name: .long, help: "Print the code and return; confirm later with \"catflap pair confirm\".")
        var noWait = false
        func run() throws {
            let client = PairClient(options)
            var status = try client.request("pair.start")
            while status.state == .starting { status = try client.poll() }
            try client.follow(status, wait: !noWait)
        }
    }

    struct Join: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Join the device that made a code.")
        @OptionGroup var options: ClientOptions
        @Argument(help: "The code from \"catflap pair start\" on the other device.") var code: String
        @Flag(name: .long, help: "Return at once; confirm later with \"catflap pair confirm\".")
        var noWait = false
        func run() throws {
            let client = PairClient(options)
            try client.follow(try client.request("pair.join", ["code": code]), wait: !noWait)
        }
    }

    struct PairStatus: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the pairing in progress.")
        @OptionGroup var options: ClientOptions
        func run() throws {
            let client = PairClient(options)
            try client.show(try client.request("pair.status"))
        }
    }

    struct Confirm: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Confirm that both devices show the same six digits.")
        @OptionGroup var options: ClientOptions
        func run() throws {
            let client = PairClient(options)
            try client.show(try client.request("pair.confirm"))
        }
    }

    struct Decline: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the pairing in progress. Nothing is stored.")
        @OptionGroup var options: ClientOptions
        func run() throws {
            let client = PairClient(options)
            try client.show(try client.request("pair.decline"))
        }
    }

    /// Runs the Open step against a paired device and reports the result.
    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check that a paired device answers.", shouldDisplay: false)
        @OptionGroup var options: ClientOptions
        @Argument(help: "Device id or name.") var device: String
        func run() throws {
            let client = PairClient(options)
            var result = try client.send("pair.check", ["device": device, "start": "1"], as: PairingService.CheckStatus.self)
            while result.state == "running" {
                Thread.sleep(forTimeInterval: 0.5)
                result = try client.send("pair.check", ["device": device], as: PairingService.CheckStatus.self)
            }
            if options.json { print(try ControlJSON.text(result)) }
            else if result.state == "ok" { print("\(device) answered.") }
            else { FileHandle.standardError.write(Data(((result.error ?? "Check failed.") + "\n").utf8)) }
            if result.state != "ok" { throw ExitCode.failure }
        }
    }
}

/// Control requests for pairing, with the agent's error text passed through.
struct PairClient {
    let options: ClientOptions
    init(_ options: ClientOptions) { self.options = options }

    func send<T: Decodable>(_ command: String, _ arguments: [String: String] = [:], as type: T.Type) throws -> T {
        let response: ControlResponse
        do { response = try ControlClient.request(.init(command, arguments: arguments), socket: options.socket) }
        catch { try fail(AgentError.control.rawValue, code: ExitCode.failure) }
        guard response.ok else { try fail(response.error ?? "Control request failed.", code: ExitCode(response.exitCode)) }
        return try response.decode(type)
    }

    func request(_ command: String, _ arguments: [String: String] = [:]) throws -> PairingStatus {
        try send(command, arguments, as: PairingStatus.self)
    }

    func poll() throws -> PairingStatus {
        Thread.sleep(forTimeInterval: 0.5)
        return try request("pair.status")
    }

    func fail(_ message: String, code: ExitCode) throws -> Never {
        if options.json { say(try ControlJSON.text(ClientErrorOutput(error: message))) }
        else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        throw code
    }

    /// Writes to standard output at once: a pairing waits on the person, so a line held in a
    /// buffer (stdout is buffered when it is not a terminal) would never be seen in time.
    func say(_ text: String, newline: Bool = true) {
        FileHandle.standardOutput.write(Data((newline ? text + "\n" : text).utf8))
    }

    func show(_ status: PairingStatus) throws {
        if options.json {
            say(try ControlJSON.text(status))
            return
        }
        switch status.state {
        case .idle: say("No pairing in progress.")
        case .starting: say("Starting a pairing server…")
        case .waiting:
            say("Pairing code, valid for ten minutes and one use:")
            say(status.code ?? "")
            say("On the other device run: catflap pair join <code>")
        case .connecting: say("Connecting…")
        case .confirm:
            say("Pairing with \(status.peerName ?? "the other device"). Both devices must show: \(status.digits ?? "")")
        case .confirmed: say("Confirmed here. Waiting for the other device.")
        case .exchanging: say("Both confirmed. Exchanging addresses…")
        case .paired: say("Paired with \(status.peerName ?? "the other device").")
        case .failed: FileHandle.standardError.write(Data(((status.error ?? "Pairing failed.") + "\n").utf8))
        }
    }

    /// Shows the status and, unless told not to wait or printing JSON, follows the pairing
    /// to its end, asking the person to compare the digits.
    func follow(_ initial: PairingStatus, wait: Bool) throws {
        var status = initial
        try show(status)
        if !wait || options.json {
            if status.state == .failed { throw ExitCode.failure }
            return
        }
        var shown = status.state
        var asked = false
        while status.isActive {
            if status.state == .confirm && !asked {
                asked = true
                say("Do both devices show the same six digits? Type yes to pair: ", newline: false)
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
                status = try request(answer == "yes" || answer == "y" ? "pair.confirm" : "pair.decline")
            } else {
                status = try poll()
            }
            if status.state != shown { try show(status) }
            shown = status.state
        }
        if status.state != .paired { throw ExitCode.failure }
    }
}
