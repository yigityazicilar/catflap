import Foundation
import Crypto

public struct TransferLimits: Sendable {
    public var textBytes: Int64 = 4 * 1024 * 1024
    public var fileBytes: Int64 = 20 * 1024 * 1024 * 1024
    public var freeReserve: Int64 = 1024 * 1024 * 1024
    public var receivesPerDevice = 2
    public var idle: Duration = .seconds(30)
    public var dial: Duration = .seconds(30)
    public init() {}
}
public enum TransferCommitPoint: String, CaseIterable, Sendable { case recorded, written, hashed, renamed, committed }
public enum TransferFailure: Error, LocalizedError, Sendable {
    case rejected(TransferRejectReason), invalid, missingRetryContent, crash
    case unknownDevice, unreadableFile, tooLarge, alreadySending, nothingToRetry
    public var errorDescription: String? {
        switch self {
        case .rejected(.tooLarge): "The other device refused it: too large."
        case .rejected(.noSpace): "The other device refused it: not enough free space there."
        case .rejected(.busy): "The other device is busy receiving. Try again in a moment."
        case .rejected(.duplicate): "The other device already has it."
        case .invalid: "Invalid transfer."
        case .missingRetryContent: "Retry needs the original content."
        case .crash: "Transfer interrupted."
        case .unknownDevice: "No paired device has that id."
        case .unreadableFile: "Cannot read that file."
        case .tooLarge: "Too large to send."
        case .alreadySending: "That item is already being sent."
        case .nothingToRetry: "Nothing to retry under that id."
        }
    }
}
public enum TransferPayload: Sendable {
    case text(String)
    case file(URL)
}

public actor TransferService {
    public nonisolated let history: TransferHistory
    public let inbox: TransferInbox
    public let peers: PeerService?
    public var limits: TransferLimits
    private var active: [String: Set<String>] = [:]
    private var targets: Set<String> = []
    private var reservedBytes: Int64 = 0
    private var outgoing: [String: TransferPayload] = [:]
    private var sending: Set<String> = []
    private var results: [String: TransferRecord] = [:]
    private var ephemeral: [String: (Date, String)] = [:]
    public var freeBytesOverride: Int64?
    public var crashAt: TransferCommitPoint?
    public var dropAck = false

    public init(store: Store, inbox: TransferInbox, peers: PeerService? = nil, limits: TransferLimits = .init()) {
        history = TransferHistory(store: store); self.inbox = inbox; self.peers = peers; self.limits = limits
    }
    public func configure(freeBytes: Int64? = nil, crashAt: TransferCommitPoint? = nil, dropAck: Bool = false) {
        freeBytesOverride = freeBytes; self.crashAt = crashAt; self.dropAck = dropAck
    }
    public func install(on runtime: AgentRuntime) async throws {
        try await reconcile()
        await peers?.setSessionHandler { [weak self] session, inbound in
            if inbound { await self?.receive(deviceID: session.device.id, connection: session.connection) }
        }
        await runtime.provide(self)
        await runtime.register("history") { [history] request in
            try ControlResponse(value: try await history.rows(search: request.arguments["search"]))
        }
        await runtime.register("send") { [self] request in
            guard let device = request.arguments["device_id"] else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
            do {
                let row: TransferRecord
                if let id = request.arguments["retry"] { row = try await retry(deviceID: device, id: id) }
                else if let text = request.arguments["text"] { row = try await start(deviceID: device, payload: .text(text), keep: request.arguments["keep"] != "false") }
                else if let file = request.arguments["file"] { row = try await start(deviceID: device, payload: .file(URL(fileURLWithPath: file)), keep: request.arguments["keep"] != "false") }
                else { return ControlResponse(error: .invalidRequest, exitCode: 64) }
                return try ControlResponse(value: row)
            } catch { return ControlResponse(failure: (error as? LocalizedError)?.errorDescription ?? AgentError.invalidRequest.rawValue) }
        }
        await runtime.register("send.status") { [self] request in
            guard let device = request.arguments["device_id"], let id = request.arguments["id"], let row = try await status(deviceID: device, id: id) else { throw AgentError.invalidRequest }
            return try ControlResponse(value: row)
        }
    }
    public func copyText(deviceID: String, id: String, now: Date = Date()) async throws -> String? {
        let key = deviceID + "/" + id
        if let item = ephemeral[key] {
            if now.timeIntervalSince(item.0) < 600 { return item.1 }
            ephemeral[key] = nil
        }
        return try await history.record(deviceID: deviceID, id: id)?.text
    }
    private func rememberText(_ text: String, key: String) {
        let created = Date()
        ephemeral[key] = (created, text)
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
            await self?.expireText(key: key, created: created)
        }
    }
    private func expireText(key: String, created: Date) {
        if ephemeral[key]?.0 == created { ephemeral[key] = nil }
    }
    private func checkpoint(_ point: TransferCommitPoint) throws { if crashAt == point { throw TransferFailure.crash } }

    public func reconcile() async throws {
        for var row in try await history.rows() {
            if row.direction == "sent" && row.status == "sending" { row.status = "unconfirmed"; try await history.save(row) }
            guard row.direction == "received", row.status == "receiving" else { continue }
            // Only a file can be found finished on disk. A text is stored with its row in one
            // step, so one still marked as arriving never arrived.
            var valid = false
            if let name = row.targetName, let hash = row.sha256, let final = try? inbox.url(name), inbox.exists(name) {
                valid = (try? TransferInbox.hash(final)) == hash
            }
            row.status = valid ? "ok" : "failed"
            if let name = row.targetName { try inbox.removePart(name) }
            try await history.save(row)
        }
    }
    public func receive(deviceID: String, connection: WireConnection) async {
        var record: TransferRecord?
        var target: String?
        var admittedID: String?
        var reserved: Int64 = 0
        var simulatedCrash = false
        do {
            guard let frame = try await connection.readFrame(timeout: .seconds(10)) else { return }
            let offer = try frame.decode(TransferOffer.self)
            guard !offer.id.isEmpty, offer.id.utf8.count <= 128, !offer.id.contains("/"), ["text", "file", "image"].contains(offer.kind), offer.size >= 0 else { throw TransferFailure.invalid }
            let size = offer.size
            let isText = offer.kind == "text"
            let known = try await history.record(deviceID: deviceID, id: offer.id)
            // An id this device used for something it sent is not the other device's to reuse.
            if known?.direction == "sent" { throw TransferFailure.invalid }
            // A committed id wins even while the previous session is draining its final bytes.
            if known?.status == "ok" {
                try await connection.send(TransferReject(.duplicate)); await connection.finish(); return
            }
            // Reserve before the next suspension so same-id offers cannot race.
            if active[deviceID, default: []].contains(offer.id) { try await connection.send(TransferReject(.busy)); await connection.finish(); return }
            if active[deviceID, default: []].count >= limits.receivesPerDevice { try await connection.send(TransferReject(.busy)); await connection.finish(); return }
            active[deviceID, default: []].insert(offer.id)
            admittedID = offer.id
            record = TransferRecord(id: offer.id, deviceID: deviceID, direction: "received", kind: offer.kind, size: offer.size, status: "receiving", keep: offer.keep)
            if let old = try await history.record(deviceID: deviceID, id: offer.id), old.status == "ok" {
                record = nil
                try await connection.send(TransferReject(.duplicate)); await connection.finish()
            } else {
                if offer.size > (isText ? limits.textBytes : limits.fileBytes) { throw TransferFailure.rejected(.tooLarge) }
                // A text is held in memory and stored with its row, so it never leaves a file
                // in the inbox. Only files need the inbox, its free space and a name there.
                var name: String?
                if !isText {
                    try inbox.prepare()
                    let free = try freeBytesOverride ?? inbox.freeBytes()
                    guard free >= limits.freeReserve, size <= free - limits.freeReserve - reservedBytes else { throw TransferFailure.rejected(.noSpace) }
                    reservedBytes += size; reserved = size
                    let chosen = inbox.availableName(offer.name, excluding: targets)
                    name = chosen; target = chosen; targets.insert(chosen)
                    record!.targetName = chosen
                    if offer.keep { record!.path = try inbox.url(chosen).path }
                }
                try await history.save(record!)
                try checkpoint(.recorded)
                let handle = try name.map { try inbox.createPart($0) }
                defer { try? handle?.close() }
                try await connection.send(TransferAccept())
                var hash = SHA256(); var remaining = size; var text = Data()
                while remaining > 0 {
                    guard let chunk = try await connection.readRaw(maxLength: Int(min(remaining, 256 * 1024)), deadline: .now + limits.idle), !chunk.isEmpty else { throw WireError.truncated }
                    remaining -= Int64(chunk.count); hash.update(data: chunk)
                    if isText { text.append(chunk) }
                    try handle?.write(contentsOf: chunk)
                }
                try handle?.synchronize(); try handle?.close()
                try checkpoint(.written)
                guard let doneFrame = try await connection.readFrame(timeout: limits.idle) else { throw WireError.truncated }
                let done = try doneFrame.decode(TransferDone.self)
                let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard done.sha256 == actual else { throw TransferFailure.invalid }
                if isText { guard String(data: text, encoding: .utf8) != nil else { throw TransferFailure.invalid } }
                record!.sha256 = actual
                try await history.save(record!)
                try checkpoint(.hashed)
                if let name { try inbox.publish(name) }
                try checkpoint(.renamed)
                if isText {
                    let value = String(decoding: text, as: UTF8.self)
                    if offer.keep { record!.text = value }
                    else { rememberText(value, key: deviceID + "/" + offer.id) }
                }
                record!.status = "ok"; try await history.save(record!)
                try checkpoint(.committed)
                if !dropAck { try await connection.send(TransferAck(storedAs: name ?? "")) }
                await connection.finish()
            }
        } catch {
            simulatedCrash = (error as? TransferFailure).map { if case .crash = $0 { return true }; return false } ?? false
            if case TransferFailure.rejected(let reason) = error {
                try? await connection.send(TransferReject(reason))
                await connection.finish()
            }
            if !simulatedCrash, var row = record {
                // Never undo a committed row because the acknowledgement was lost.
                if row.status != "ok" { row.status = "failed"; try? await history.save(row) }
            }
        }
        if let admittedID { active[deviceID]?.remove(admittedID) }
        reservedBytes -= reserved
        if let target {
            targets.remove(target)
            if !simulatedCrash { try? inbox.removePart(target) }
        }
        await connection.close()
    }

    public func start(deviceID: String, payload: TransferPayload, keep: Bool = true, id: String = UUID().uuidString) async throws -> TransferRecord {
        let key = deviceID + "/" + id
        guard try await history.store.devices().contains(where: { $0.id == deviceID }) else { throw TransferFailure.unknownDevice }
        // From here to the insert nothing suspends, so two starts of one id cannot both pass.
        guard !sending.contains(key) else { throw TransferFailure.alreadySending }
        var row: TransferRecord
        switch payload {
        case .text(let text):
            guard Int64(text.utf8.count) <= limits.textBytes else { throw TransferFailure.tooLarge }
            row = TransferRecord(id: id, deviceID: deviceID, direction: "sent", kind: "text", size: Int64(text.utf8.count), status: "sending", keep: keep)
            if keep { row.text = text }
        case .file(let file):
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, let size = values.fileSize,
                  FileManager.default.isReadableFile(atPath: file.path) else { throw TransferFailure.unreadableFile }
            guard Int64(size) <= limits.fileBytes else { throw TransferFailure.tooLarge }
            row = TransferRecord(id: id, deviceID: deviceID, direction: "sent", kind: "file", size: Int64(size), status: "sending", keep: keep)
            if keep { row.path = file.path }
        }
        sending.insert(key)
        do { try await history.save(row) } catch { sending.remove(key); throw error }
        outgoing[key] = payload; results[key] = row
        Task { await self.perform(row, payload: payload) }
        return row
    }
    public func status(deviceID: String, id: String) async throws -> TransferRecord? {
        if let row = results[deviceID + "/" + id] { return row }
        return try await history.record(deviceID: deviceID, id: id)
    }
    public func retry(deviceID: String, id: String) async throws -> TransferRecord {
        let key = deviceID + "/" + id
        guard let old = try await status(deviceID: deviceID, id: id), old.canRetry else { throw TransferFailure.nothingToRetry }
        let payload: TransferPayload
        if let original = outgoing[key] { payload = original }
        else if let text = old.text { payload = .text(text) }
        else if let path = old.path { payload = .file(URL(fileURLWithPath: path)) }
        else { throw TransferFailure.missingRetryContent }
        return try await start(deviceID: deviceID, payload: payload, keep: old.keep, id: id)
    }
    private func perform(_ initial: TransferRecord, payload: TransferPayload) async {
        var row = initial
        let key = row.deviceID + "/" + row.id
        defer { sending.remove(key) }
        var session: PeerSession?
        // Until `done` is on its way the other device cannot have stored the item, so a failure
        // before that is certain. After it, only the acknowledgement tells.
        var doneSent = false
        do {
            guard let peers else { throw TransferFailure.invalid }
            let opened = try await peers.open(deviceID: row.deviceID, timeout: limits.dial)
            session = opened
            let connection = opened.connection
            let name: String
            switch payload { case .text: name = "text"; case .file(let file): name = file.lastPathComponent }
            try await connection.send(TransferOffer(id: row.id, kind: row.kind, name: name, size: row.size, mime: row.kind == "text" ? "text/plain" : "application/octet-stream", keep: row.keep))
            guard let response = try await connection.readFrame(timeout: limits.idle) else { throw WireError.truncated }
            if response.type == TransferReject.type {
                let reject = try response.decode(TransferReject.self)
                if reject.reason == .duplicate { row.status = "ok" }
                else { throw TransferFailure.rejected(reject.reason) }
            } else {
                _ = try response.decode(TransferAccept.self)
                var hash = SHA256()
                switch payload {
                case .text(let text):
                    let data = Data(text.utf8); hash.update(data: data); try await connection.write(data, timeout: limits.idle)
                case .file(let file):
                    let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                    var remaining = row.size
                    while remaining > 0 {
                        guard let data = try handle.read(upToCount: Int(min(remaining, 256 * 1024))), !data.isEmpty else { throw TransferFailure.invalid }
                        remaining -= Int64(data.count); hash.update(data: data); try await connection.write(data, timeout: limits.idle)
                    }
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                if row.keep { row.sha256 = digest }
                doneSent = true
                try await connection.send(TransferDone(sha256: digest))
                guard let frame = try await connection.readFrame(timeout: limits.idle) else { throw WireError.truncated }
                _ = try frame.decode(TransferAck.self)
                row.status = "ok"
            }
            try await history.store.recordSend(to: row.deviceID)
            await connection.finish()
        } catch {
            row.status = doneSent ? "unconfirmed" : "failed"
            if error is TransferFailure { row.error = (error as? TransferFailure)?.errorDescription }
            else if let peerError = error as? PeerError { row.error = peerError.errorDescription }
            else { row.error = "Transfer interrupted. Retry is available." }
        }
        if let session { await peers?.release(session) }
        do { try await history.save(row) } catch { row.status = "failed"; row.error = "Cannot save transfer history." }
        // A finished send is read back from the store; only one that can be retried stays here,
        // with its content and the reason it stopped.
        results[key] = row.status == "ok" ? nil : row
        if row.status == "ok" { outgoing[key] = nil }
    }
}
