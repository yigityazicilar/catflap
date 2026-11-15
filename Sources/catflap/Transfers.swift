import ArgumentParser
import CatflapCore
import Foundation

/// `catflap transfers`: what was sent and received, what waits at the door, and cancelling or
/// retrying one. Lists carry previews; `show` gives one transfer whole.
struct Transfers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transfers", abstract: "List, show, cancel or retry transfers.",
        subcommands: [List.self, Show.self, Cancel.self, Retry.self], defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List transfers, newest first.")
        @OptionGroup var options: ClientOptions
        @Flag(name: .long, help: "Only sends waiting for a device that is away.") var waiting = false
        @Flag(name: .long, help: "Only transfers under way or interrupted.") var active = false
        @Flag(name: .long, help: "Every transfer (the default).") var all = false
        @Option(name: .long, help: "Only this device's, by id or name.") var to: String?
        @Option(name: .long) var search: String?
        @Option(name: .long, help: "At most this many, up to 500.") var limit: Int?
        func run() async throws {
            let call = AgentCall(options: options)
            guard [waiting, active, all].filter({ $0 }).count <= 1 else { try call.fail("Use one of --waiting, --active and --all.", code: 64) }
            if let limit, !(1...500).contains(limit) { try call.fail("The limit is 1 to 500.", code: 64) }
            var arguments: [String: String] = ["status": waiting ? "waiting" : active ? "active" : "all"]
            if let to { arguments["device_id"] = try call.resolve(to, in: try await call.devices()).id }
            arguments["search"] = search
            arguments["limit"] = limit.map(String.init)
            let page = try await call.request("transfers.list", arguments)
            _ = try page.expect(TransferPage.self)
            print(String(decoding: page.payload, as: UTF8.self))
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one transfer whole.")
        @OptionGroup var options: ClientOptions
        @Argument var id: String
        @Option(name: .long, help: "The device it went to or came from, when the id alone is not enough.") var to: String?
        func run() async throws {
            let call = AgentCall(options: options)
            let device = try await Transfers.device(of: id, to: to, call: call)
            let row = try await call.request("transfers.get", ["device_id": device, "id": id])
            _ = try row.expect(TransferRecord.self)
            print(String(decoding: row.payload, as: UTF8.self))
        }
    }

    struct Cancel: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Cancel a waiting or running send, or an interrupted receive.")
        @OptionGroup var options: ClientOptions
        @Argument var id: String?
        @Option(name: .long) var to: String?
        @Option(name: .long, help: "Cancel every transfer of one send.") var send: String?
        func run() async throws {
            let call = AgentCall(options: options)
            guard (id == nil) != (send == nil) else { try call.fail("Give a transfer id, or --send with a send id.", code: 64) }
            var arguments: [String: String] = [:]
            if let send { arguments["send_id"] = send }
            else if let id { arguments = ["device_id": try await Transfers.device(of: id, to: to, call: call), "id": id] }
            let reply = try await call.request("transfers.cancel", arguments)
            let outcome = try reply.expect(CancelReply.self)
            if let refused = outcome.notCancelled.first, outcome.cancelled.isEmpty {
                try call.fail(refused.error, code: 1)
            }
            print(String(decoding: reply.payload, as: UTF8.self))
            if !outcome.notCancelled.isEmpty { throw ExitCode.failure }
        }
    }

    struct Retry: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Try a transfer again; a waiting one is tried now.")
        @OptionGroup var options: ClientOptions
        @Argument var id: String
        @Option(name: .long) var to: String?
        func run() async throws {
            let call = AgentCall(options: options)
            let device = try await Transfers.device(of: id, to: to, call: call)
            let row = try await call.request("transfers.retry", ["device_id": device, "id": id])
            _ = try row.expect(TransferRecord.self)
            print(String(decoding: row.payload, as: UTF8.self))
        }
    }

    /// The device of transfer `id`: the one named, or the only one a transfer with that id
    /// belongs to.
    static func device(of id: String, to: String?, call: AgentCall) async throws -> String {
        if let to { return try call.resolve(to, in: try await call.devices()).id }
        var before: String?
        var found: Set<String> = []
        repeat {
            var arguments = ["status": "all", "limit": "500"]
            arguments["before"] = before
            let page = try await call.request("transfers.list", arguments).expect(TransferPage.self)
            for row in page.items where row.id == id { found.insert(row.deviceID) }
            before = page.nextBefore
        } while before != nil && found.count < 2
        guard found.count < 2 else { try call.fail("Transfers to several devices have that id: add --to.", code: 64) }
        guard let device = found.first else { try call.fail("No transfer has that id.", code: 1) }
        return device
    }
}

private struct CancelReply: Decodable {
    struct Refused: Decodable { let error: String }
    let cancelled: [TransferRecord]
    let notCancelled: [Refused]
    enum CodingKeys: String, CodingKey { case cancelled, notCancelled = "not_cancelled" }
}

/// `catflap inbox`: the folder received files go to. A new one applies at once.
struct Inbox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show or set the folder received files go to.")
    @OptionGroup var options: ClientOptions
    @Option(name: .long, help: "Use this folder from the next transfer on.") var set: String?
    func run() async throws {
        let call = AgentCall(options: options)
        let reply: ControlResponse
        if let set { reply = try await call.request("inbox.set", ["directory": URL(fileURLWithPath: set).standardizedFileURL.path]) }
        else { reply = try await call.request("inbox") }
        _ = try reply.expect(InboxStatus.self)
        print(String(decoding: reply.payload, as: UTF8.self))
    }
}

/// `catflap devices`: paired devices with their presence. Without `--json`, one line each.
struct Devices: AsyncParsableCommand {
    @OptionGroup var options: ClientOptions
    func run() async throws {
        let call = AgentCall(options: options)
        // Ask for a check, then read cached results until none is still checking; an agent
        // without presence just lists its devices.
        _ = try? await ControlClient.requestAsync(.init("presence"), socket: options.socket)
        var reply = try await call.request("devices")
        _ = try reply.expect([DeviceSummary].self)
        let deadline = ContinuousClock.now + .seconds(12)
        while Self.checking(reply.payload) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            reply = try await call.request("devices")
            _ = try reply.expect([DeviceSummary].self)
        }
        if options.json { print(String(decoding: reply.payload, as: UTF8.self)); return }
        let rows = (try? JSONSerialization.jsonObject(with: reply.payload)) as? [[String: Any]] ?? []
        if rows.isEmpty { print("No paired device.") }
        for row in rows { print(Self.line(row)) }
    }
    static func checking(_ payload: Data) -> Bool {
        let rows = (try? JSONSerialization.jsonObject(with: payload)) as? [[String: Any]] ?? []
        return rows.contains { ($0["presence"] as? [String: Any])?["state"] as? String == "checking" }
    }
    /// `<name> — here · direct · 12 ms`, `… via relay fra …`, `… — away`, `… — checking…`.
    static func line(_ row: [String: Any]) -> String {
        let name = row["name"] as? String ?? "?"
        var parts: [String] = []
        if let presence = row["presence"] as? [String: Any] {
            switch presence["state"] as? String {
            case "here":
                parts.append("here")
                if presence["path"] as? String == "direct" { parts.append("direct") }
                else if let code = presence["relay_region_code"] as? String { parts.append("via relay \(code)") }
                if let latency = presence["latency_ms"] as? Double { parts.append("\(Int(latency.rounded())) ms") }
            case "away": parts.append("away")
            default: parts.append("checking…")
            }
            if let age = presence["age_seconds"] as? Double, age >= 90, presence["state"] as? String != "checking" { parts.append("checked \(Int(age)) s ago") }
        }
        if row["confirmed"] as? Bool == false { parts.append("not yet confirmed by \(name): if it does not list this device, pair again") }
        switch row["peer_state"] as? String {
        case "update_peer": parts.append("update Catflap on \(name)")
        case "update_this_device": parts.append("update Catflap on this device")
        case "wrong_device": parts.append("the device at its address is not \(name): pair again")
        default: break
        }
        return parts.isEmpty ? name : name + " — " + parts.joined(separator: " · ")
    }
}
