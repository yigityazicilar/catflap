import ArgumentParser
import CatflapCore
import Foundation

struct Send: AsyncParsableCommand, AgentFeature {
    @OptionGroup var options: ClientOptions
    @Option(name: .long, help: "Paired device id. Defaults to the most recently used device.") var to: String?
    @Option(name: .long) var text: String?
    @Option(name: .long) var file: String?
    @Option(name: .long, help: "Retry a history id without sending a second copy.") var retry: String?
    @Flag(name: .long) var dontKeep = false

    static func install(on runtime: AgentRuntime) async throws {
        guard let peers = await runtime.service(PeerService.self) else { throw AgentError.invalidRequest }
        let store = await runtime.store
        let configured = try await store.setting("inbox")
        let directory = configured.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Catflap")
        let service = TransferService(store: store, inbox: try TransferInbox(directory: directory, create: false), peers: peers)
        try await service.install(on: runtime)
    }
    func run() async throws {
        guard [text != nil, file != nil, retry != nil].filter({ $0 }).count == 1 else { try fail("Use --text, --file, or --retry.", code: 64) }
        let device: String
        if let to { device = to }
        else {
            guard let first = try await request(.init("devices")).decode([DeviceSummary].self).first else {
                try fail("No paired device. Pair one first with `catflap pair start`.", code: 1)
            }
            device = first.id
        }
        var arguments = ["device_id": device, "keep": dontKeep ? "false" : "true"]
        arguments["text"] = text; arguments["file"] = file.map { URL(fileURLWithPath: $0).standardizedFileURL.path }; arguments["retry"] = retry
        var row = try await request(.init("send", arguments: arguments)).decode(TransferRecord.self)
        let deadline = ContinuousClock.now + .seconds(3600)
        while row.status == "sending" && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            row = try await request(.init("send.status", arguments: ["device_id": device, "id": row.id])).decode(TransferRecord.self)
        }
        print(try ControlJSON.text(row))
        if row.status != "ok" {
            if !options.json { FileHandle.standardError.write(Data(((row.error ?? "Not sent.") + "\n").utf8)) }
            throw ExitCode.failure
        }
    }
    /// One control request. A refusal, or an agent that cannot be reached, ends the command
    /// with the reason: JSON on standard output with `--json`, a line on standard error without.
    private func request(_ request: ControlRequest) async throws -> ControlResponse {
        let response: ControlResponse
        do { response = try await ControlClient.requestAsync(request, socket: options.socket) }
        catch { try fail(AgentError.control.rawValue, code: 1) }
        guard response.ok else { try fail(response.error ?? "Control request failed.", code: response.exitCode) }
        return response
    }
    private func fail(_ message: String, code: Int32) throws -> Never {
        if options.json { print(try ControlJSON.text(ClientErrorOutput(error: message))) }
        else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        throw ExitCode(code)
    }
}
