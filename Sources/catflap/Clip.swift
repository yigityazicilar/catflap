import ArgumentParser
import CatflapCore
import Foundation

struct Clip: AsyncParsableCommand, AgentFeature {
    @OptionGroup var options: ClientOptions
    @Argument(help: "list, add, keep, delete, pause, or send") var action: String?
    @Argument(help: "Item id, or on/off for pause.") var id: String?
    @Option(name: .long) var text: String?
    @Option(name: .long, help: "Read an image from a file, or add a file reference with --kind files.") var file: String?
    @Option(name: .long) var kind = "text"
    @Option(name: .long) var mime: String?
    @Option(name: .long) var offeredType: [String] = []
    @Option(name: .long) var search: String?
    @Option(name: .long) var to: String?
    @Flag(name: .long) var dontKeep = false
    @Flag(name: .long, help: "With send: the newest copy, only if clipboard history recorded it.") var latest = false

    static func install(on runtime: AgentRuntime) async throws {
        guard let transfers = await runtime.service(TransferService.self) else { throw AgentError.invalidRequest }
        let store = await runtime.store
        let history = try await ClipboardHistory.open(store: store)
        let paths = await store.paths
        let service = ClipboardService(history: history, transfers: transfers, store: store, directory: paths.directory)
        try await service.install(on: runtime)
    }
    func run() async throws {
        guard let action, ["list", "add", "keep", "delete", "pause", "send"].contains(action) else {
            try fail("Use clip list, add, keep, delete, pause, or send.", code: 64)
        }
        if latest && action != "send" { try fail("--latest goes with clip send.", code: 64) }
        var arguments: [String: String] = [:]
        switch action {
        case "list": arguments["search"] = search
        case "add":
            guard ClipboardKind(rawValue: kind) != nil else { try fail("Use kind text, url, image, or files.", code: 64) }
            arguments["kind"] = kind; arguments["mime"] = mime
            arguments["offered_types"] = offeredType.joined(separator: "\n")
            if !SecretFilter.isMarked(offeredTypes: offeredType) {
                guard (text != nil) != (file != nil) else { try fail("Use exactly one of --text or --file.", code: 64) }
                if let file {
                    let url = URL(fileURLWithPath: file).standardizedFileURL
                    if kind == "files" { arguments["text"] = url.absoluteString }
                    else {
                        do {
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            let limit = kind == "image" ? ClipboardHistory.imageLimit : ClipboardHistory.textLimit
                            guard size <= limit else { try fail("Clipboard item is too large.", code: 1) }
                            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                            let data = try handle.read(upToCount: limit + 1) ?? Data()
                            guard data.count <= limit else { try fail("Clipboard item is too large.", code: 1) }
                            arguments["data"] = data.base64EncodedString()
                            if kind == "image", mime == nil { arguments["mime"] = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg" }
                        } catch is ExitCode { throw ExitCode.failure }
                        catch { try fail("Cannot read clipboard input file.", code: 1) }
                    }
                } else { arguments["text"] = text }
            }
        case "keep", "delete", "send":
            if latest {
                guard id == nil else { try fail("Use an item id or --latest, not both.", code: 64) }
                arguments["latest"] = "true"
            } else {
                guard let id else { try fail("An item id is required.", code: 64) }
                arguments["id"] = id
            }
        case "pause":
            if let id {
                guard ["on", "off"].contains(id) else { try fail("Use clip pause on or off.", code: 64) }
                arguments["paused"] = id == "on" ? "true" : "false"
            }
        default: break
        }
        if action != "send" {
            let response = try await request(.init("clip." + action, arguments: arguments))
            print(String(decoding: response.payload, as: UTF8.self)); return
        }
        // With --latest and no --to, the agent picks the most recently used device.
        if let to { arguments["device_id"] = to }
        else if !latest {
            guard let first = try await request(.init("devices")).decode([DeviceSummary].self).first else {
                try fail("No paired device. Pair one first with `catflap pair start`.", code: 1)
            }
            arguments["device_id"] = first.id
        }
        arguments["keep"] = dontKeep ? "false" : "true"
        var row = try await request(.init("clip.send", arguments: arguments)).decode(TransferRecord.self)
        let device = row.deviceID
        let deadline = ContinuousClock.now + .seconds(3600)
        while row.status == "sending", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            row = try await request(.init("clip.send.status", arguments: ["device_id": device, "id": row.id])).decode(TransferRecord.self)
        }
        if row.status == "ok" { print(try ControlJSON.text(row)); return }
        let reason = row.error ?? (row.status == "unconfirmed" ? "Not confirmed. The other device may have it; Retry will not send a second copy." : row.status == "sending" ? "Still sending after an hour. `catflap history` shows how it ends." : "Not sent.")
        if options.json { print(try ControlJSON.text(ClipSendFailure(error: reason, transfer: row))) }
        else { print(try ControlJSON.text(row)); FileHandle.standardError.write(Data((reason + "\n").utf8)) }
        throw ExitCode.failure
    }
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
private struct ClipSendFailure: Encodable {
    let ok = false
    let error: String
    let transfer: TransferRecord
}
