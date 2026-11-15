import ArgumentParser
import CatflapCore
import Foundation

struct Follow: AsyncParsableCommand {
    @OptionGroup var options: ClientOptions
    @Option(name: .long) var to: String?
    @Flag(name: .long) var off = false
    @Option(name: .long) var device: String?
    @Option(name: .long) var permission: String?
    @Option(name: .long) var openLinks: String?
    @Flag(name: .long) var pending = false
    @Option(name: .long) var answer: String?
    @Flag(name: .long) var allow = false
    @Flag(name: .long) var refuse = false
    func run() async throws {
        let call = AgentCall(options: options)
        let modes = [to != nil, off, permission != nil, openLinks != nil, pending, answer != nil].filter { $0 }.count
        guard modes <= 1, !(allow && refuse), (answer != nil) == (allow || refuse),
              permission == nil || (device != nil && FollowPermission(rawValue: permission!) != nil),
              openLinks == nil || (device != nil && LinkOpenPolicy(rawValue: openLinks!) != nil) else {
            try usage("Use one follow action; permission/open-links need --device, and --answer needs --allow or --refuse.")
        }
        var command = "follow", arguments: [String: String] = [:]
        if let device { arguments["device_id"] = try call.resolve(device, in: await call.devices()).id }
        if let to { command = "follow.set"; arguments["device_id"] = try call.resolve(to, in: await call.devices()).id }
        if off { command = "follow.set"; arguments["off"] = "true" }
        if let permission { command = "follow.permission"; arguments["permission"] = permission }
        if let openLinks { command = "links.policy"; arguments["policy"] = openLinks }
        if pending { command = "follow.prompts" }
        if let answer { command = "follow.answer"; arguments["id"] = answer; arguments["allow"] = allow ? "true" : "false" }
        let response = try await call.request(command, arguments)
        if pending { _ = try response.expect([FollowPrompt].self) }
        else { try response.expectObject() }
        print(String(decoding: response.payload, as: UTF8.self))
    }
    private func usage(_ message: String) throws -> Never {
        if options.json { print(try ControlJSON.text(ClientErrorOutput(error: message))) }
        else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        throw ExitCode(64)
    }
}
struct Open: AsyncParsableCommand {
    @OptionGroup var options: ClientOptions
    @Option(name: .long) var from: String?
    @Option(name: .long) var to: String?
    @Option(name: .long) var url: String?
    @Argument var id: String?
    @Flag(name: .long) var dontKeep = false
    func run() async throws {
        let call = AgentCall(options: options)
        if let from, let id, to == nil, url == nil {
            let device = try call.resolve(from, in: await call.devices())
            let response = try await call.request("open", ["device_id": device.id, "id": id])
            try response.expectObject(); print(String(decoding: response.payload, as: UTF8.self))
            return
        }
        if let to, let url, from == nil, id == nil, let normalized = LinkNormalizer.normalize(url) {
            let device = try call.resolve(to, in: await call.devices())
            let response = try await call.request("transfers.send", ["device_ids": device.id, "text": normalized.absoluteString,
                "intent": "open", "keep": dontKeep ? "false" : "true", "wait": "false"])
            _ = try response.expect(TransferBatch.self); print(String(decoding: response.payload, as: UTF8.self))
            return
        }
        let message = "Use open --from <device> <item>, or open --to <device> --url <one http(s) URL>."
        if options.json { print(try ControlJSON.text(ClientErrorOutput(error: message))) }
        else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        throw ExitCode(64)
    }
}
