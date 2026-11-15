import Foundation
import Crypto
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// How one attempt to deliver an item ended.
enum AttemptOutcome: Sendable {
    case delivered
    /// Might go another time: the device was away or busy, or the connection broke.
    case retriable(String, unconfirmed: Bool)
    /// Will not change by trying again on its own.
    case permanent(String)
    case cancelled
}

extension TransferService {
    // MARK: Starting sends

    /// Starts one send to one device, which does not wait for an away device: the call the
    /// panels make. `send(_:)` is the one that waits.
    public func start(deviceID: String, payload: TransferPayload, keep: Bool = true, id: String = UUID().uuidString) async throws -> TransferRecord {
        let batch = try await enqueue(SendRequest(deviceIDs: [deviceID], payloads: [payload], keep: keep, wait: false, id: id), single: true)
        guard let row = batch.transfers.first else { throw TransferFailure.invalid }
        return row
    }
    /// Starts a send to every device in the request, of every payload: one transfer each,
    /// with its own outcome. Kept items wait for an away device unless `wait` is false.
    public func send(_ request: SendRequest) async throws -> TransferBatch {
        try await enqueue(request, single: false)
    }

    /// With `single`, a refusal throws instead of being listed, as `start` always did.
    private func enqueue(_ request: SendRequest, single: Bool) async throws -> TransferBatch {
        let paired = Set(try await history.store.devices().map(\.id))
        let sendID = UUID().uuidString
        var refused: [TransferRefusal] = []
        var devices: [String] = []
        for device in request.deviceIDs where !devices.contains(device) {
            if paired.contains(device) { devices.append(device) }
            else if single { throw TransferFailure.unknownDevice }
            else { refused.append(.init(deviceID: device, file: nil, error: TransferFailure.unknownDevice.errorDescription!)) }
        }
        var payloads: [(TransferPayload, kind: String, size: Int64, mime: String)] = []
        for payload in request.payloads {
            do { payloads.append(try check(payload)) }
            catch {
                if single { throw error }
                refused.append(.init(deviceID: nil, file: Self.path(of: payload), error: (error as? LocalizedError)?.errorDescription ?? "Cannot send it."))
            }
        }
        let waits = request.keep && request.wait
        var rows: [TransferRecord] = []
        var started: [String] = []
        for (payload, kind, size, mime) in payloads {
            for device in devices {
                let id = (single || (devices.count == 1 && payloads.count == 1)) ? (request.id ?? UUID().uuidString) : UUID().uuidString
                let key = device + "/" + id
                // From here to the insert nothing suspends, so two starts of one id cannot both pass.
                guard !sending.contains(key) else {
                    if single { throw TransferFailure.alreadySending }
                    refused.append(.init(deviceID: device, file: Self.path(of: payload), error: TransferFailure.alreadySending.errorDescription!)); continue
                }
                var row = TransferRecord(id: id, deviceID: device, direction: "sent", kind: kind, size: size, status: "sending", keep: request.keep)
                row.timestamp = clock.now()
                row.sendID = single ? nil : sendID
                row.mime = mime; row.intent = request.intent; row.clipKind = request.clipKind
                row.phase = "preparing"
                switch payload {
                case .text(let text): if request.keep { row.text = text }
                default: if request.keep { row.path = Self.path(of: payload) }
                }
                sending.insert(key)
                do { try await history.save(row) } catch { sending.remove(key); throw error }
                outgoing[key] = OutgoingItem(row: row, payload: payload, prepared: nil, waits: waits)
                results[key] = row
                rows.append(row); started.append(key)
            }
        }
        if !started.isEmpty { Task { await self.run(started) } }
        return TransferBatch(sendID: sendID, transfers: rows, refused: refused)
    }

    static func path(of payload: TransferPayload) -> String? {
        switch payload {
        case .text: nil
        case .file(let url), .image(let url, _), .folder(let url): url.path
        }
    }

    /// Quick checks before anything is stored: kind, size and MIME type.
    private func check(_ payload: TransferPayload) throws -> (TransferPayload, kind: String, size: Int64, mime: String) {
        switch payload {
        case .text(let text):
            guard Int64(text.utf8.count) <= limits.textBytes else { throw TransferFailure.tooLarge }
            return (payload, "text", Int64(text.utf8.count), "text/plain; charset=utf-8")
        case .file(let file):
            var info = stat()
            if stat(file.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) { throw TransferFailure.isFolder }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, let size = values.fileSize,
                  FileManager.default.isReadableFile(atPath: file.path) else { throw TransferFailure.unreadableFile }
            guard Int64(size) <= limits.fileBytes else { throw TransferFailure.tooLarge }
            return (payload, "file", Int64(size), "application/octet-stream")
        case .image(let file, let mime):
            guard ImageKind.extensions[mime] != nil else { throw TransferFailure.notImage }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, let size = values.fileSize,
                  FileManager.default.isReadableFile(atPath: file.path) else { throw TransferFailure.unreadableFile }
            guard Int64(size) <= limits.imageBytes else { throw TransferFailure.tooLarge }
            return (payload, "image", Int64(size), mime)
        case .folder(let folder):
            var info = stat()
            guard stat(folder.path, &info) == 0 else { throw TransferFailure.unreadableFile }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw TransferFailure.notFolder }
            guard access(folder.path, R_OK | X_OK) == 0 else { throw TransferFailure.unreadableFile }
            return (payload, "folder", 0, "inode/directory")
        }
    }

    /// Prepares each item once per payload, then tries every device at once.
    private func run(_ keys: [String]) async {
        var prepared: [String: Result<PreparedSource, TransferFailure>] = [:]
        for key in keys {
            guard let item = outgoing[key] else { continue }
            let source = Self.path(of: item.payload) ?? ("text:" + key)
            let result: Result<PreparedSource, TransferFailure>
            if let done = prepared[source] { result = done }
            else {
                let payload = item.payload, limits = self.limits
                result = await Task.detached { Self.prepare(payload, limits: limits) }.value
                if Self.path(of: item.payload) != nil { prepared[source] = result }
            }
            switch result {
            case .success(let source):
                outgoing[key]?.prepared = source
                outgoing[key]?.row.size = source.size
                outgoing[key]?.row.entries = source.manifest?.entries.count
                // A kept file, image or folder records the content it committed to.
                if item.row.keep && source.kind != "text" { outgoing[key]?.row.sha256 = source.sha256 }
                if item.row.keep { outgoing[key]?.row.skipped = source.manifest?.skipped }
                if item.waits { try? await enterQueue(key) }
            case .failure(let failure):
                await finish(key, outcome: .permanent(failure.errorDescription ?? "Cannot send it."))
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for key in keys where outgoing[key]?.prepared != nil {
                group.addTask { await self.deliverNow(key) }
            }
        }
    }

    /// Hashes the content, and lists a folder, before the first offer. Off the actor.
    nonisolated static func prepare(_ payload: TransferPayload, limits: TransferLimits) -> Result<PreparedSource, TransferFailure> {
        func hashFile(_ url: URL) throws -> (String, Int64, SourceStat) {
            let fd = open(url.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw TransferFailure.unreadableFile }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw TransferFailure.unreadableFile }
            var hash = SHA256(), size: Int64 = 0
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk); size += Int64(chunk.count) }
            guard size == Int64(info.st_size) else { throw TransferFailure.sourceChanged }
            return (hex(hash.finalize()), size, SourceStat(info))
        }
        do {
            switch payload {
            case .text(let text):
                let data = Data(text.utf8)
                return .success(PreparedSource(kind: "text", size: Int64(data.count), sha256: hex(SHA256.hash(data: data)), mime: "text/plain; charset=utf-8", name: "text", text: data))
            case .file(let url):
                let (digest, size, info) = try hashFile(url)
                guard size <= limits.fileBytes else { return .failure(.tooLarge) }
                return .success(PreparedSource(kind: "file", size: size, sha256: digest, mime: "application/octet-stream", name: url.lastPathComponent, url: url, stat: info))
            case .image(let url, let mime):
                let (digest, size, info) = try hashFile(url)
                guard size <= limits.imageBytes else { return .failure(.tooLarge) }
                return .success(PreparedSource(kind: "image", size: size, sha256: digest, mime: mime, name: "Clipboard image", url: url, stat: info))
            case .folder(let url):
                let manifest = try FolderManifest.scan(url, limits: limits.folder, maxBytes: limits.fileBytes)
                return .success(PreparedSource(kind: "folder", size: manifest.totalSize, sha256: manifest.digest, mime: "inode/directory",
                                               name: url.resolvingSymlinksInPath().lastPathComponent, url: url.resolvingSymlinksInPath(), manifest: manifest))
            }
        } catch let failure as TransferFailure { return .failure(failure) }
        catch let limit as FolderLimitError { return .failure(.folderLimit(limit)) }
        catch { return .failure(.unreadableFile) }
    }

    /// Tries an item at once, as a new send or a retry does, whatever its device's backoff.
    func deliverNow(_ key: String) async {
        let outcome = await attempt(key)
        await finish(key, outcome: outcome)
    }

    /// Settles an item after an attempt: delivered, waiting for its device, or ended.
    func finish(_ key: String, outcome: AttemptOutcome) async {
        guard var item = outgoing[key] else { sending.remove(key); return }
        var row = item.row
        let device = row.deviceID
        row.phase = nil; row.progress = nil; row.resumedFrom = nil
        var queued = false
        switch outcome {
        case .delivered:
            row.status = "ok"; row.error = nil
            failures[device] = nil
            try? await history.store.recordSend(to: device)
            try? await leaveQueue(key)
        case .cancelled:
            row.status = "cancelled"; row.error = nil
            try? await leaveQueue(key)
        case .permanent(let reason):
            row.status = "failed"; row.error = reason
            try? await leaveQueue(key)
        case .retriable(let reason, let unconfirmed):
            row.error = reason
            if item.waits, (try? await isQueued(key)) == true {
                queued = true
                row.status = "waiting"
                try? await backOff(key, unconfirmed: unconfirmed)
                // The scheduler may be asleep for up to a minute with nothing due: wake it so
                // it sleeps only until this item's next try, 30 s after a first failure.
                kick()
            } else {
                row.status = unconfirmed ? "unconfirmed" : "failed"
            }
        }
        // A cancel that came in while the attempt ran wins over its outcome, unless delivered.
        if let current = results[key], current.status == "cancelled", row.status != "ok" { row.status = "cancelled"; row.error = nil }
        do { try await history.save(row) } catch { row.status = "failed"; row.error = "Cannot save transfer history." }
        item.row = row
        sending.remove(key)
        try? await cleanOwnedCopy(row)
        // A finished send is read back from the store. One that can be retried, or waits,
        // stays here with its content and the reason it stopped.
        _ = queued
        if row.status == "ok" { outgoing[key] = nil; results[key] = nil }
        else { outgoing[key] = item; results[key] = row }
    }

    public func retry(deviceID: String, id: String) async throws -> TransferRecord {
        try await retry(deviceID: deviceID, id: id, waits: false)
    }
    /// Retry, or for a waiting item "try now". With `waits`, a kept item waits again.
    public func retry(deviceID: String, id: String, waits: Bool) async throws -> TransferRecord {
        let key = deviceID + "/" + id
        guard let old = try await status(deviceID: deviceID, id: id) else { throw TransferFailure.nothingToRetry }
        if old.status == "waiting" {
            failures[deviceID] = nil
            try await history.store.execute("UPDATE queue SET next_attempt_at=? WHERE device_id=?", bindings: [.real(clock.now().timeIntervalSince1970), .text(deviceID)])
            kick()
            return old
        }
        guard old.canRetry, !sending.contains(key) else { throw TransferFailure.nothingToRetry }
        let payload: TransferPayload
        if let original = outgoing[key]?.payload { payload = original }
        else if let text = old.text { payload = .text(text) }
        else if let path = old.path {
            let url = URL(fileURLWithPath: path)
            switch old.kind {
            case "folder": payload = .folder(url)
            case "image": payload = .image(url, mime: old.mime ?? "image/png")
            default: payload = .file(url)
            }
        } else { throw TransferFailure.missingRetryContent }
        _ = try check(payload)
        var row = old
        row.status = "sending"; row.phase = "preparing"; row.error = nil; row.waiting = nil
        row.timestamp = old.timestamp
        sending.insert(key)
        do { try await history.save(row) } catch { sending.remove(key); throw error }
        outgoing[key] = OutgoingItem(row: row, payload: payload, prepared: nil, waits: waits && old.keep)
        results[key] = row
        Task { await self.run([key]) }
        return row
    }

    // MARK: One attempt

    /// Opens a link, offers the item and streams it from the receiver's offset.
    func attempt(_ key: String) async -> AttemptOutcome {
        guard let item = outgoing[key], let source = item.prepared else { return .permanent(TransferFailure.invalid.errorDescription!) }
        let device = item.row.deviceID, id = item.row.id
        guard let connector else { return .permanent(TransferFailure.invalid.errorDescription!) }
        // An item that waited by reference must still be what was queued.
        if let failure = Self.sourceProblem(source) { return .permanent(failure.errorDescription!) }
        results[key]?.phase = "connecting"
        let link: PeerLink
        do { link = try await connector.link(deviceID: device, timeout: limits.dial) }
        catch let error as PeerError {
            switch error {
            case .refused, .wrongDevice: return .permanent(error.errorDescription!)
            default: return .retriable(error.errorDescription!, unconfirmed: false)
            }
        } catch { return .retriable("Cannot reach the other device. Retry is available.", unconfirmed: false) }
        let connection = link.connection
        // Until `done` is on its way the other device cannot have stored the item, so a failure
        // before that is certain. From the moment it is handed to the connection, only the
        // acknowledgement tells: a write that fails may still have delivered the frame.
        var doneSent = false
        let outcome: AttemptOutcome
        do {
            try await sendForgets(device, connection)
            let offer = TransferOffer(id: id, kind: source.kind, name: source.name, size: source.size, mime: source.mime, keep: item.row.keep,
                                      sha256: source.sha256, intent: item.row.intent, clipKind: item.row.clipKind,
                                      entries: source.manifest?.entries.count, skipped: source.manifest?.skipped.count)
            try await connection.send(offer)
            var offset: Int64?
            var duplicate = false
            let holdLimit = ContinuousClock.now + limits.maxHold
            while offset == nil && !duplicate {
                guard let frame = try await connection.readFrame(timeout: limits.idle) else { throw WireError.truncated }
                switch frame.type {
                case TransferHold.type: guard ContinuousClock.now < holdLimit else { throw WireError.timedOut }
                case WantManifest.type:
                    guard let manifest = source.manifest else { throw TransferFailure.invalid }
                    try await connection.write(manifest.frames, timeout: limits.idle)
                    try await connection.send(ManifestEnd(count: manifest.entries.count))
                case TransferReject.type:
                    let reject = try frame.decode(TransferReject.self)
                    if reject.reason == .duplicate { duplicate = true } else { throw TransferFailure.rejected(reject.reason) }
                default: offset = try frame.decode(TransferAccept.self).offset
                }
            }
            if duplicate { outcome = .delivered }
            else {
                guard let offset, offset >= 0, offset <= source.size else { throw TransferFailure.invalid }
                if offset > 0 { results[key]?.phase = "resuming"; results[key]?.resumedFrom = offset }
                results[key]?.phase = offset > 0 ? "resuming" : "streaming"
                if try await stream(key, source: source, from: offset, connection: connection) == false {
                    try? await connection.send(TransferAbort(reason: "cancelled"))
                    await connection.finish(timeout: .seconds(3))
                    await link.close()
                    return .cancelled
                }
                results[key]?.phase = "confirming"
                doneSent = true
                try await connection.send(TransferDone(sha256: source.sha256))
                var answer: WireFrame?
                repeat { answer = try await connection.readFrame(timeout: limits.idle) } while answer?.type == TransferHold.type
                guard let answer else { throw WireError.truncated }
                if answer.type == TransferReject.type { throw TransferFailure.rejected(try answer.decode(TransferReject.self).reason) }
                _ = try answer.decode(TransferAck.self)
                outcome = .delivered
            }
            await connection.finish()
        } catch TransferFailure.rejected(let reason) {
            switch reason {
            case .busy, .noSpace: outcome = .retriable(TransferFailure.rejected(reason).errorDescription!, unconfirmed: false)
            default: outcome = .permanent(TransferFailure.rejected(reason).errorDescription!)
            }
            await connection.close()
        } catch TransferFailure.sourceChanged {
            try? await connection.send(TransferAbort(reason: "source_changed"))
            await connection.finish(timeout: .seconds(3))
            outcome = .permanent(TransferFailure.sourceChanged.errorDescription!)
        } catch {
            outcome = .retriable("Transfer interrupted. Retry is available.", unconfirmed: doneSent)
            await connection.close()
        }
        await link.close()
        return outcome
    }

    /// The ids this device gave up while they may have left a part on `device`.
    private func sendForgets(_ device: String, _ connection: WireConnection) async throws {
        let rows = try await history.store.query("SELECT id FROM forget WHERE device_id=? ORDER BY created_at LIMIT 256", bindings: [.text(device)])
        let ids = rows.compactMap { if case .text(let id) = $0["id"] { id } else { nil } }
        guard !ids.isEmpty else { return }
        try await connection.send(TransferForget(ids: ids))
        guard let answer = try await connection.readFrame(timeout: limits.idle) else { throw WireError.truncated }
        _ = try answer.decode(TransferForgotten.self)
        for id in ids { try await history.store.execute("DELETE FROM forget WHERE device_id=? AND id=?", bindings: [.text(device), .text(id)]) }
    }

    /// Streams the content from `offset`. False when the person cancelled meanwhile.
    private func stream(_ key: String, source: PreparedSource, from offset: Int64, connection: WireConnection) async throws -> Bool {
        var sent = offset
        func progress(_ count: Int) {
            sent += Int64(count)
            results[key]?.progress = TransferProgress(doneBytes: sent, totalBytes: source.size)
        }
        if let text = source.text {
            let data = text.dropFirst(Int(offset))
            try await connection.write(Data(data), timeout: limits.idle); progress(data.count)
            return true
        }
        if let manifest = source.manifest, let root = source.url {
            var start: Int64 = 0
            var statIndex = 0
            for entry in manifest.entries where entry.type == "file" {
                let size = entry.size ?? 0
                defer { start += size; statIndex += 1 }
                guard start + size > offset else { continue }
                let url = entry.path.reduce(root) { $0.appendingPathComponent($1) }
                let handle = try Self.openUnchanged(url, expected: manifest.stats[statIndex], changed: .folderChanged)
                defer { try? handle.close() }
                let skip = max(0, offset - start)
                if skip > 0 { try handle.seek(toOffset: UInt64(skip)) }
                var hash = SHA256(), remaining = size - skip
                while remaining > 0 {
                    if outgoing[key]?.cancelRequested == true { return false }
                    guard let data = try handle.read(upToCount: Int(min(remaining, 256 * 1024))), !data.isEmpty else { throw TransferFailure.sourceChanged }
                    remaining -= Int64(data.count); if skip == 0 { hash.update(data: data) }
                    try await connection.write(data, timeout: limits.idle); progress(data.count)
                }
                if skip == 0, hex(hash.finalize()) != entry.sha256 { throw TransferFailure.sourceChanged }
            }
            return true
        }
        guard let url = source.url, let expected = source.stat else { throw TransferFailure.invalid }
        let handle = try Self.openUnchanged(url, expected: expected, changed: .sourceChanged)
        defer { try? handle.close() }
        if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }
        var hash = SHA256(), remaining = source.size - offset
        while remaining > 0 {
            if outgoing[key]?.cancelRequested == true { return false }
            guard let data = try handle.read(upToCount: Int(min(remaining, 256 * 1024))), !data.isEmpty else { throw TransferFailure.sourceChanged }
            remaining -= Int64(data.count); if offset == 0 { hash.update(data: data) }
            try await connection.write(data, timeout: limits.idle); progress(data.count)
        }
        // From the start, what was streamed must be what was hashed when it was queued.
        if offset == 0, hex(hash.finalize()) != source.sha256 { throw TransferFailure.sourceChanged }
        return true
    }

    /// Opens `url` without following a link, and checks it is the file that was hashed.
    nonisolated static func openUnchanged(_ url: URL, expected: SourceStat, changed: TransferFailure) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? (changed == .folderChanged ? TransferFailure.folderChanged : .sourceGone) : changed }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), SourceStat(info) == expected else { close(fd); throw changed }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    /// Why a prepared item can no longer be sent as it was queued, if it cannot.
    nonisolated static func sourceProblem(_ source: PreparedSource) -> TransferFailure? {
        if let manifest = source.manifest, let root = source.url {
            var index = 0
            for entry in manifest.entries where entry.type == "file" {
                let url = entry.path.reduce(root) { $0.appendingPathComponent($1) }
                do { try openUnchanged(url, expected: manifest.stats[index], changed: .folderChanged).close() } catch { return .folderChanged }
                index += 1
            }
            return nil
        }
        guard let url = source.url, let expected = source.stat else { return nil }
        do { try openUnchanged(url, expected: expected, changed: .sourceChanged).close(); return nil }
        catch let failure as TransferFailure { return failure }
        catch { return .sourceChanged }
    }
}

extension TransferFailure: Equatable {
    public static func == (lhs: TransferFailure, rhs: TransferFailure) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }
}
