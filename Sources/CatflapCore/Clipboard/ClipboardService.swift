import Foundation

public actor ClipboardService {
    public let history: ClipboardHistory
    private let transfers: TransferService
    private let store: Store
    private let outbox: URL
    private var preparing: Set<String> = []
    public init(history: ClipboardHistory, transfers: TransferService, store: Store, directory: URL) {
        self.history = history; self.transfers = transfers; self.store = store
        outbox = directory.appendingPathComponent("outbox")
    }
    public func install(on runtime: AgentRuntime) async throws {
        try await cleanOutbox()
        await runtime.provide(history)
        await runtime.provide(self)
        for command in ["clip.list", "clip.add", "clip.keep", "clip.delete", "clip.pause", "clip.send", "clip.send.status"] {
            await runtime.register(command) { [self] request in
                do { return try await handle(request) }
                catch let failure as ClipboardFailure { return ControlResponse(failure: failure.rawValue) }
                catch let failure as TransferFailure { return ControlResponse(failure: failure.localizedDescription) }
                catch { return ControlResponse(failure: "Cannot access clipboard history.") }
            }
        }
    }
    private func handle(_ request: ControlRequest) async throws -> ControlResponse {
        let a = request.arguments
        switch request.command {
        case "clip.list": return try await ControlResponse(value: history.items(search: a["search"]))
        case "clip.add":
            guard let kind = ClipboardKind(rawValue: a["kind"] ?? "text") else { throw ClipboardFailure.invalid }
            let types = a["offered_types"]?.split(separator: "\n").map(String.init) ?? []
            // Base64 decoding and validation are inside the reader, after the marker gate.
            let result = try await history.ingest(offeredTypes: types, passwordManagerFrontmost: a["password_manager_frontmost"] == "true", kind: kind) {
                let bytes: Data
                if let encoded = a["data"] {
                    guard let decoded = Data(base64Encoded: encoded) else { throw ClipboardFailure.invalid }
                    bytes = decoded
                } else { bytes = Data((a["text"] ?? "").utf8) }
                return .init(kind: kind, data: bytes, mime: a["mime"] ?? (kind == .image ? nil : "text/plain"))
            }
            return try ControlResponse(value: result)
        case "clip.keep":
            guard let id = a["id"] else { throw ClipboardFailure.noPending }
            return try await ControlResponse(value: history.keep(id: id))
        case "clip.delete":
            guard let id = a["id"] else { throw ClipboardFailure.missing }
            try await history.delete(id: id)
            return try ControlResponse(value: ClipboardIngestResult("deleted", id: id))
        case "clip.pause":
            if let value = a["paused"] {
                guard ["true", "false"].contains(value) else { throw ClipboardFailure.invalid }
                try await history.setPaused(value == "true")
            }
            return try ControlResponse(value: ["paused": await history.isPaused()])
        case "clip.send":
            guard let id = a["id"], let device = a["device_id"] else { throw ClipboardFailure.missing }
            return try await ControlResponse(value: send(id: id, deviceID: device, keep: a["keep"] != "false"))
        case "clip.send.status":
            guard let id = a["id"], let device = a["device_id"],
                  let row = try await transfers.status(deviceID: device, id: id) else { throw ClipboardFailure.missing }
            try await cleanOutbox()
            return try ControlResponse(value: row)
        default: throw ClipboardFailure.invalid
        }
    }
    public func send(id: String, deviceID: String, keep: Bool = true) async throws -> TransferRecord {
        let item = try await history.item(id: id)
        switch item.kind {
        case .text, .url:
            return try await transfers.start(deviceID: deviceID, payload: .text(String(decoding: item.content, as: UTF8.self)), keep: keep)
        case .files:
            // A history item is one transfer. Multiple references remain available to the panel
            // for selection; silently choosing a subset would send something different.
            let references = String(decoding: item.content, as: UTF8.self).split(separator: "\n")
            guard references.count == 1, let url = URL(string: String(references[0])), url.isFileURL else {
                throw ClipboardFailure.invalid
            }
            return try await transfers.start(deviceID: deviceID, payload: .file(url), keep: keep)
        case .image:
            _ = try AgentPaths(directory: outbox)
            let transferID = UUID().uuidString
            preparing.insert(transferID)
            defer { preparing.remove(transferID) }
            let file = outbox.appendingPathComponent(transferID + (item.mime == "image/png" ? ".png" : ".jpg"))
            try AgentPaths.writePrivate(item.content, to: file)
            do {
                let row = try await transfers.start(deviceID: deviceID, payload: .file(file), keep: keep, id: transferID)
                Task { [self] in
                    // Only successful delivery permits removal. Failed and uncertain sends need
                    // the source for Retry, including after a restart.
                    do {
                        while let status = try await transfers.status(deviceID: deviceID, id: row.id), status.status == "sending" {
                            try await Task.sleep(for: .milliseconds(200))
                        }
                        try await cleanOutbox()
                    } catch { /* Startup retries cleanup; a failed send keeps its source. */ }
                }
                return row
            } catch { try FileManager.default.removeItem(at: file); throw error }
        }
    }
    public func cleanOutbox(now: Date = Date()) async throws {
        guard FileManager.default.fileExists(atPath: outbox.path) else { return }
        _ = try AgentPaths(directory: outbox)
        for file in try FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]) {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
            if preparing.contains(file.deletingPathExtension().lastPathComponent) { continue }
            let rows = try await store.query("SELECT status FROM history WHERE direction='sent' AND id=?", bindings: [.text(file.deletingPathExtension().lastPathComponent)])
            let expired = (info.contentModificationDate ?? .distantPast) < now.addingTimeInterval(-ClipboardHistory.lifetime)
            let needed = rows.contains { row in
                if case .text(let status) = row["status"] { return status != "ok" }
                return false
            }
            if (!needed || expired) && FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
