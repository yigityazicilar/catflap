import Foundation

/// A paired device as `devices` shows it: the public summary, what this device knows of the
/// other's state, and its presence. Never an address, key or secret.
public struct DeviceStatusSummary: Encodable, Sendable {
    public let summary: DeviceSummary
    /// `ok`, `update_peer`, `update_this_device` or `wrong_device`.
    public let peerState: String
    /// False until the other device showed it admits this one: a ping it answered, or an
    /// authenticated session either way. A pairing that finished on one side only stays false.
    public let confirmed: Bool
    public let presence: DevicePresence?
    enum CodingKeys: String, CodingKey { case peerState = "peer_state", confirmed, presence }
    public func encode(to encoder: any Encoder) throws {
        try summary.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(peerState, forKey: .peerState); try c.encode(confirmed, forKey: .confirmed)
        try c.encodeIfPresent(presence, forKey: .presence)
    }
}
public struct InboxStatus: Codable, Sendable {
    public let directory: String
    public let isDefault: Bool
    public let exists: Bool
    enum CodingKeys: String, CodingKey { case directory, exists, isDefault = "is_default" }
}
struct CancelOutcome: Encodable {
    struct Refused: Encodable {
        let deviceID: String, id: String, error: String
        enum CodingKeys: String, CodingKey { case id, error, deviceID = "device_id" }
    }
    let cancelled: [TransferRecord]
    let notCancelled: [Refused]
    enum CodingKeys: String, CodingKey { case cancelled, notCancelled = "not_cancelled" }
}

/// The control commands of transfers. Lists carry previews, never bodies.
enum TransferControl {
    static func failure(_ error: any Error) -> ControlResponse {
        ControlResponse(failure: (error as? LocalizedError)?.errorDescription ?? AgentError.invalidRequest.rawValue)
    }
    static func lines(_ value: String?) -> [String] {
        (value ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    static func register(_ service: TransferService, on runtime: AgentRuntime) async {
        let history = service.history
        await runtime.register("history") { request in
            try ControlResponse(value: try await history.rows(search: request.arguments["search"]))
        }
        // The panels' single-device send, which never waits. `transfers.send` replaces it.
        await runtime.register("send") { request in
            guard let device = request.arguments["device_id"] else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
            do {
                let row: TransferRecord
                let keep = request.arguments["keep"] != "false"
                if let id = request.arguments["retry"] { row = try await service.retry(deviceID: device, id: id) }
                else if let text = request.arguments["text"] { row = try await service.start(deviceID: device, payload: .text(text), keep: keep) }
                else if let file = request.arguments["file"] { row = try await service.start(deviceID: device, payload: .file(URL(fileURLWithPath: file)), keep: keep) }
                else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
                return try ControlResponse(value: row)
            } catch { return failure(error) }
        }
        await runtime.register("send.status") { request in
            guard let device = request.arguments["device_id"], let id = request.arguments["id"], let row = try await service.status(deviceID: device, id: id) else { throw AgentError.invalidRequest }
            return try ControlResponse(value: row)
        }
        await runtime.register("transfers.send") { [weak runtime] request in
            let a = request.arguments
            let devices = lines(a["device_ids"] ?? a["device_id"])
            guard (1...16).contains(devices.count) else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
            let files = lines(a["files"]), folders = lines(a["folders"] ?? a["folder"])
            let sources = [a["text"] != nil, !files.isEmpty || !folders.isEmpty, a["clip_id"] != nil].filter { $0 }.count
            guard sources == 1, (files + folders).allSatisfy({ $0.hasPrefix("/") }), files.count + folders.count <= 256,
                  [nil, "true", "false"].contains(a["keep"]), [nil, "true", "false"].contains(a["wait"]),
                  [nil, "deliver", "open"].contains(a["intent"]) else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
            let keep = a["keep"] != "false"
            var payloads: [TransferPayload] = []
            if let text = a["text"] { payloads = [.text(text)] }
            payloads += files.map { .file(URL(fileURLWithPath: $0)) } + folders.map { .folder(URL(fileURLWithPath: $0)) }
            do {
                if let clip = a["clip_id"] {
                    guard let clipboard = await runtime?.service(ClipboardService.self) else { return ControlResponse(error: .unsupported, exitCode: 64) }
                    payloads = [try await clipboard.payload(forItem: clip, keep: keep)]
                }
                let batch = try await service.send(SendRequest(deviceIDs: devices, payloads: payloads, keep: keep, wait: keep && a["wait"] != "false",
                                                               intent: a["intent"] ?? "deliver"))
                return try ControlResponse(value: batch)
            } catch { return failure(error) }
        }
        await runtime.register("transfers.list") { request in
            let a = request.arguments
            var query = TransferQuery()
            if let groups = a["status"] {
                let names = Set(groups.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
                guard names.isSubset(of: ["waiting", "active", "done", "all"]) else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
                query.groups = names.contains("all") ? [] : names
            }
            query.deviceID = a["device_id"]; query.search = a["search"]
            if let direction = a["direction"] {
                guard ["sent", "received"].contains(direction) else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
                query.direction = direction
            }
            if let limit = a["limit"] {
                guard let value = Int(limit), (1...500).contains(value) else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
                query.limit = value
            }
            if let before = a["before"] {
                guard let date = TransferCursor.parse(before) else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
                query.before = date
            }
            return try ControlResponse(value: try await service.list(query))
        }
        await runtime.register("transfers.get") { request in
            guard let device = request.arguments["device_id"], let id = request.arguments["id"] else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
            guard let row = try await service.status(deviceID: device, id: id) else { return ControlResponse(failure: "No transfer has that id.") }
            return try ControlResponse(value: row)
        }
        await runtime.register("transfers.cancel") { request in
            let a = request.arguments
            if let sendID = a["send_id"] {
                let (done, refused) = try await service.cancel(sendID: sendID)
                return try ControlResponse(value: CancelOutcome(cancelled: done, notCancelled: refused.map { .init(deviceID: $0.0.deviceID, id: $0.0.id, error: $0.1) }))
            }
            guard let device = a["device_id"], let id = a["id"] else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
            do { return try ControlResponse(value: CancelOutcome(cancelled: [try await service.cancel(deviceID: device, id: id)], notCancelled: [])) }
            catch { return try ControlResponse(value: CancelOutcome(cancelled: [], notCancelled: [.init(deviceID: device, id: id, error: (error as? LocalizedError)?.errorDescription ?? "Cannot cancel it.")])) }
        }
        await runtime.register("transfers.retry") { request in
            guard let device = request.arguments["device_id"], let id = request.arguments["id"] else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
            do { return try ControlResponse(value: try await service.retry(deviceID: device, id: id, waits: true)) }
            catch { return failure(error) }
        }
        await runtime.register("inbox") { _ in
            try ControlResponse(value: try await service.inboxStatus())
        }
        await runtime.register("inbox.set") { request in
            guard let directory = request.arguments["directory"], directory.hasPrefix("/") else {
                return ControlResponse(failure: TransferInboxError.notAbsolute.rawValue)
            }
            do {
                let url = URL(fileURLWithPath: directory).standardizedFileURL
                try TransferInbox.prepare(url)
                try await history.store.setSetting("inbox", value: url.path)
                return try ControlResponse(value: try await service.inboxStatus())
            } catch { return failure(error) }
        }
        await runtime.register("devices") { [weak runtime] _ in
            let devices = try await history.store.devices()
            let states = await service.peers?.deviceStates() ?? [:]
            var presence: [String: DevicePresence] = [:]
            if let service = await runtime?.service(PresenceService.self) {
                for row in (try? await service.presence(refresh: false)) ?? [] { presence[row.deviceID] = row }
            }
            return try ControlResponse(value: devices.map { device in
                DeviceStatusSummary(summary: DeviceSummary(device), peerState: states[device.id]?.peerState ?? "ok",
                                    confirmed: states[device.id]?.confirmed ?? true, presence: presence[device.id])
            })
        }
    }
}

extension TransferService {
    public func inboxStatus() async throws -> InboxStatus {
        let configured = try await history.store.setting("inbox").flatMap { $0.isEmpty ? nil : $0 }
        let directory = configured ?? inbox.directory.path
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory, isDirectory: &isFolder) && isFolder.boolValue
        return InboxStatus(directory: directory, isDefault: configured == nil, exists: exists)
    }
}
