import ArgumentParser
import CatflapCore
import Foundation

/// `catflap send`: text, files or folders to one or several paired devices. A kept send to a
/// device that is away waits for it (status 75) and is delivered when it answers, for up to 7
/// days; `--now` and `--dont-keep` send now or fail.
struct Send: AsyncParsableCommand, AgentFeature {
    static let configuration = CommandConfiguration(abstract: "Send text, files or folders to paired devices.")
    @OptionGroup var options: ClientOptions
    @Option(name: .long, help: "A paired device's id or name. Repeat for several. Defaults to the most recently used device.") var to: [String] = []
    @Option(name: .long) var text: String?
    @Option(name: .long, help: "A file. Repeat for several.") var file: [String] = []
    @Option(name: .long, help: "A folder. Repeat for several.") var folder: [String] = []
    @Option(name: .long, help: "Retry a history id without sending a second copy.") var retry: String?
    @Flag(name: .long) var dontKeep = false
    @Flag(name: .long, help: "Send now or fail; do not wait for a device that is away.") var now = false
    @Argument(help: "Absolute paths of files and folders, as a file manager passes them.") var paths: [String] = []

    static func install(on runtime: AgentRuntime) async throws {
        guard let peers = await runtime.service(PeerService.self) else { throw AgentError.invalidRequest }
        let store = await runtime.store
        // The inbox setting is read again at each receive, so a new choice applies at once.
        let configured = try await store.setting("inbox").flatMap { $0.isEmpty ? nil : $0 }
        let directory = configured.map { URL(fileURLWithPath: $0) } ?? TransferInbox.defaultDirectory
        let service = TransferService(store: store, inbox: try TransferInbox(directory: directory, create: false), peers: peers)
        try await service.install(on: runtime)
    }

    func run() async throws {
        let call = AgentCall(options: options)
        let given = try absolutePaths(paths, call: call)
        var files = file.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var folders = folder.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for path in files {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue { try call.fail("Use --folder for a folder.", code: 64) }
        }
        for path in given {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue { folders.append(path) } else { files.append(path) }
        }
        let sources = [text != nil, !files.isEmpty || !folders.isEmpty, retry != nil].filter { $0 }.count
        guard sources == 1 else { try call.fail("Use --text, --file, --folder, paths, or --retry.", code: 64) }
        guard retry == nil || to.count <= 1 else { try call.fail("Retry one transfer at a time.", code: 64) }
        let known = try await call.devices()
        var devices: [DeviceSummary] = []
        if to.isEmpty {
            guard let first = known.first else { try call.fail("No paired device. Pair one first with `catflap pair start`.", code: 1) }
            devices = [first]
        } else {
            for name in to {
                let device = try call.resolve(name, in: known)
                if !devices.contains(where: { $0.id == device.id }) { devices.append(device) }
            }
        }
        var batch: TransferBatch
        if let retry {
            let row = try await call.request("transfers.retry", ["device_id": devices[0].id, "id": retry]).expect(TransferRecord.self)
            batch = TransferBatch(sendID: row.sendID ?? "", transfers: [row], refused: [])
        } else {
            var arguments = ["device_ids": devices.map(\.id).joined(separator: "\n"), "keep": dontKeep ? "false" : "true", "wait": now || dontKeep ? "false" : "true"]
            arguments["text"] = text
            if !files.isEmpty { arguments["files"] = files.joined(separator: "\n") }
            if !folders.isEmpty { arguments["folders"] = folders.joined(separator: "\n") }
            batch = try await call.request("transfers.send", arguments).expect(TransferBatch.self)
        }
        // Wait while anything is being sent; waiting is a resting state, not waited out.
        var rows = batch.transfers
        let deadline = ContinuousClock.now + .seconds(3600)
        while rows.contains(where: { $0.status == "sending" }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            for (index, row) in rows.enumerated() where row.status == "sending" {
                rows[index] = try await call.request("transfers.get", ["device_id": row.deviceID, "id": row.id]).expect(TransferRecord.self)
            }
        }
        batch = TransferBatch(sendID: batch.sendID, transfers: rows, refused: batch.refused)
        try report(batch, devices: known, call: call)
    }

    /// Prints the outcome and ends with 0 (all delivered), 75 (some wait, none failed) or 1.
    private func report(_ batch: TransferBatch, devices: [DeviceSummary], call: AgentCall) throws {
        let rows = batch.transfers
        let bad = rows.filter { !["ok", "waiting"].contains($0.status) }
        let waiting = rows.filter { $0.status == "waiting" }
        if rows.isEmpty, let refusal = batch.refused.first { try call.fail(refusal.error, code: 1) }
        let single = rows.count == 1 && batch.refused.isEmpty
        if bad.isEmpty && batch.refused.isEmpty {
            print(single ? try ControlJSON.text(rows[0]) : try ControlJSON.text(batch))
            if !options.json {
                for row in waiting {
                    let name = devices.first(where: { $0.id == row.deviceID })?.name ?? "the other device"
                    FileHandle.standardError.write(Data("Waiting at the door: \(name) is away. Catflap delivers it when \(name) answers, for up to 7 days.\n".utf8))
                }
            }
            if !waiting.isEmpty { throw ExitCode(75) }
            return
        }
        // Something did not end well. A row read back from the store carries no reason, so
        // one is supplied here. With --json the reason and the rows are one object, in the shape
        // every other failure has; without it the rows are printed and the reason follows on
        // standard error.
        let reason = bad.first.map(Self.reason) ?? batch.refused.first?.error ?? "Not sent."
        if options.json {
            if single { print(try ControlJSON.text(SendFailureOutput(error: reason, transfer: rows[0]))) }
            else { print(try ControlJSON.text(BatchFailureOutput(error: reason, sendID: batch.sendID, transfers: rows, refused: batch.refused))) }
        } else {
            print(single ? try ControlJSON.text(rows[0]) : try ControlJSON.text(batch))
            FileHandle.standardError.write(Data((reason + "\n").utf8))
        }
        throw ExitCode.failure
    }
    static func reason(_ row: TransferRecord) -> String {
        if let said = row.error { return said }
        switch row.status {
        case "unconfirmed": return "Not confirmed. The other device may have it; Retry will not send a second copy."
        case "sending": return "Still sending after an hour. `catflap history` shows how it ends."
        case "cancelled": return "Cancelled."
        case "expired": return "Not delivered: the other device stayed away for 7 days."
        default: return "Not sent."
        }
    }
}

/// A send that started and did not end well: the reason, and the row, which holds the id to
/// retry with.
private struct SendFailureOutput: Encodable {
    let ok = false
    let error: String
    let transfer: TransferRecord
}
private struct BatchFailureOutput: Encodable {
    let ok = false
    let error: String
    let sendID: String
    let transfers: [TransferRecord]
    let refused: [TransferRefusal]
    enum CodingKeys: String, CodingKey { case ok, error, transfers, refused, sendID = "send_id" }
}
