import Foundation
import Crypto
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// The MIME types a received image may have, its extension, and its first bytes.
enum ImageKind {
    static let extensions = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/tiff": "tiff", "image/webp": "webp", "image/heic": "heic"]
    static func matches(_ data: Data, mime: String) -> Bool {
        let b = [UInt8](data.prefix(16))
        func starts(_ prefix: [UInt8]) -> Bool { b.count >= prefix.count && Array(b.prefix(prefix.count)) == prefix }
        switch mime {
        case "image/png": return starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/jpeg": return starts([0xFF, 0xD8, 0xFF])
        case "image/gif": return starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8))
        case "image/tiff": return starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])
        case "image/webp": return b.count >= 12 && starts(Array("RIFF".utf8)) && Array(b[8..<12]) == Array("WEBP".utf8)
        case "image/heic":
            guard b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) else { return false }
            return ["heic", "heix", "heim", "heis", "hevc", "mif1", "msf1"].contains(String(decoding: b[8..<12], as: UTF8.self))
        default: return false
        }
    }
}

/// A part's identity: who sent it and what. The content digest is never stored bare, so a
/// stored row cannot be matched against a list of known file hashes.
func partIdentity(recoveryID: String, kind: String, size: Int64, sha256: String) -> String {
    var message = Data("catflap-part-v1".utf8)
    for piece in [recoveryID, kind, String(size), sha256] { message.append(0); message.append(Data(piece.utf8)) }
    return hex(SHA256.hash(data: message))
}

/// What a receive found for its offer in the parts table.
private struct PartRow {
    let recoveryID: String
    let directory: String
    let kind: String
    let identity: String
    let synced: Int64
}

extension TransferService {
    // MARK: Receiving

    public func receive(deviceID: String, connection: WireConnection) async {
        var record: TransferRecord?
        var admittedID: String?
        var reserved: Int64 = 0
        var simulatedCrash = false
        var recovery: (id: String, inbox: TransferInbox)?
        // Bytes known to be on disk, and whether a part is worth keeping when the stream stops.
        var written: Int64 = 0
        var resumable = false
        var handle: FileHandle?
        defer { try? handle?.close() }
        do {
            guard var frame = try await connection.readFrame(timeout: .seconds(10)) else { return }
            if frame.type == TransferForget.type {
                let forget = try frame.decode(TransferForget.self)
                var count = 0
                for id in forget.ids.prefix(256) where (try? await dropPart(deviceID: deviceID, id: id, status: "cancelled")) == true { count += 1 }
                try await connection.send(TransferForgotten(count: count))
                guard let next = try await connection.readFrame(timeout: limits.idle) else { await connection.finish(); return }
                frame = next
            }
            let offer: TransferOffer
            do { offer = try frame.decode(TransferOffer.self) } catch { throw TransferFailure.rejected(.invalid) }
            guard !offer.id.isEmpty, offer.id.utf8.count <= 128, !offer.id.contains("/") else { throw TransferFailure.rejected(.invalid) }
            let known = try await history.record(deviceID: deviceID, id: offer.id)
            // An id this device used for something it sent is not the other device's to reuse.
            if known?.direction == "sent" { throw TransferFailure.invalid }
            try Self.check(offer)
            // A committed id wins even while the previous session is draining its final bytes.
            if known?.status == "ok" {
                try await connection.send(TransferReject(.duplicate)); await connection.finish(); return
            }
            // Reserve before the next suspension so same-id offers cannot race.
            if active[deviceID, default: []].contains(offer.id) || active[deviceID, default: []].count >= limits.receivesPerDevice {
                try await connection.send(TransferReject(.busy)); await connection.finish(); return
            }
            active[deviceID, default: []].insert(offer.id)
            admittedID = offer.id
            let kind = offer.kind
            let limit: Int64 = switch kind { case "text": limits.textBytes; case "image": limits.imageBytes; default: limits.fileBytes }
            if offer.size > limit { throw TransferFailure.rejected(.tooLarge) }
            if kind == "folder", (offer.entries ?? 0) > limits.folder.entries { throw TransferFailure.folderLimit(.entries) }

            // A part from this device for this id resumes only when everything about it matches.
            var resume: PartRow?
            if let part = try await partRow(deviceID: deviceID, id: offer.id) {
                if ["file", "folder"].contains(kind), part.kind == kind,
                   part.identity == partIdentity(recoveryID: part.recoveryID, kind: kind, size: offer.size, sha256: offer.sha256),
                   part.synced > 0, part.synced <= offer.size {
                    resume = part
                } else {
                    try await dropPart(deviceID: deviceID, id: offer.id, status: nil)
                }
            }
            if resume == nil, kind != "text", !(kind == "image" && !offer.keep) {
                let parts = try await history.store.query("SELECT COUNT(*) AS n FROM parts WHERE device_id=?", bindings: [.text(deviceID)])
                if case .integer(let n) = parts.first?["n"], n >= Int64(limits.partsPerDevice) { throw TransferFailure.rejected(.busy) }
            }
            // A text, and an image not kept, are held in memory only: no file, no name.
            let usesDisk = kind == "file" || kind == "folder" || (kind == "image" && offer.keep)
            var target: TransferInbox?
            if usesDisk {
                let chosen: TransferInbox
                if let resume {
                    // A part finishes in the folder it started in, whatever the inbox is now.
                    chosen = try TransferInbox(directory: URL(fileURLWithPath: resume.directory), create: false)
                } else {
                    do { chosen = try await currentInbox(); try chosen.prepare() } catch { throw TransferFailure.rejected(.noSpace) }
                }
                target = chosen
                let free = try freeBytesOverride ?? chosen.freeBytes()
                let need = offer.size - (resume?.synced ?? 0)
                guard free >= limits.freeReserve, need <= free - limits.freeReserve - reservedBytes else { throw TransferFailure.rejected(.noSpace) }
                reservedBytes += need; reserved = need
            }
            var row = known.flatMap { $0.status == "ok" ? nil : $0 } ?? TransferRecord(id: offer.id, deviceID: deviceID, direction: "received", kind: kind, size: offer.size, status: "receiving", keep: offer.keep)
            row.kind = kind; row.size = offer.size; row.keep = offer.keep; row.status = "receiving"
            row.timestamp = known?.timestamp ?? clock.now()
            row.mime = offer.mime.utf8.count <= 128 ? offer.mime : nil
            row.intent = offer.intent; row.clipKind = offer.clipKind; row.entries = offer.entries
            row.text = nil; row.path = nil; row.sha256 = nil; row.targetName = nil; row.error = nil
            if let target {
                let rid = resume?.recoveryID ?? TransferInbox.newRecoveryID()
                recovery = (rid, target)
                row.recoveryID = rid
            } else { row.recoveryID = nil }
            row.resumedFrom = resume?.synced
            row.phase = resume == nil ? "streaming" : "resuming"
            row.progress = TransferProgress(doneBytes: resume?.synced ?? 0, totalBytes: offer.size)
            record = row
            try await history.save(row)
            let key = deviceID + "/" + offer.id
            receiving[key] = row
            if let recovery, resume == nil {
                try await history.store.execute("""
                INSERT INTO parts(device_id,id,recovery_id,directory,kind,size,identity,synced_bytes,created_at,expires_at) VALUES(?,?,?,?,?,?,?,0,?,?)
                """, bindings: [.text(deviceID), .text(offer.id), .text(recovery.id), .text(recovery.inbox.directory.path), .text(kind), .integer(offer.size),
                                .text(partIdentity(recoveryID: recovery.id, kind: kind, size: offer.size, sha256: offer.sha256)),
                                .real(clock.now().timeIntervalSince1970), .real(clock.now().timeIntervalSince1970 + limits.partLifetime)])
            }
            try checkpoint(.recorded)

            // Folders: the manifest, checked whole before any payload byte.
            var stager: FolderStager?
            var manifestEntries: [ManifestEntry] = []
            if kind == "folder", let recovery {
                let frames: Data
                if resume != nil {
                    guard let saved = try? Data(contentsOf: recovery.inbox.sidecar(recovery.id)) else { throw TransferFailure.rejected(.invalid) }
                    frames = saved
                } else {
                    try await connection.send(WantManifest())
                    frames = try await readManifest(connection)
                }
                guard hex(SHA256.hash(data: frames)) == offer.sha256 else { throw TransferFailure.rejected(.invalid) }
                manifestEntries = try FolderManifest.decode(frames: frames)
                try FolderManifest.validate(manifestEntries, offer: offer, limits: limits.folder)
                if resume == nil { try Self.writeNew(frames, to: recovery.inbox.sidecar(recovery.id)) }
                stager = FolderStager(root: recovery.inbox.staging(recovery.id).path, paths: FolderManifest.diskPaths(manifestEntries), entries: manifestEntries)
                try stager!.prepareFolders()
            }

            // Where the stream starts, and the hash of what is already here.
            let offset = resume?.synced ?? 0
            var hash = SHA256()
            var fileIndexes: [Int] = []
            var current = 0
            var entryHash = SHA256(), entryDone: Int64 = 0
            if kind == "folder", let stager {
                fileIndexes = manifestEntries.indices.filter { manifestEntries[$0].type == "file" }
                var start: Int64 = 0
                current = fileIndexes.count
                var currentStart: Int64 = 0
                for (position, index) in fileIndexes.enumerated() {
                    let size = manifestEntries[index].size ?? 0
                    // The first entry not wholly before the offset. An empty one at the offset
                    // is made again: a crash may have come before it was.
                    if start + size > offset || (size == 0 && start >= offset) { current = position; currentStart = start; break }
                    start += size
                }
                if current < fileIndexes.count {
                    let within = offset - currentStart
                    let index = fileIndexes[current]
                    entryHash = within == 0 ? SHA256() : try await withHolds(connection) { try stager.hashPrefix(index, length: within) }
                    entryDone = within
                    handle = try stager.openFile(index, keeping: within)
                }
            } else if let recovery, kind == "file" || kind == "image" {
                if let resume {
                    handle = try recovery.inbox.reopenRecoveryPart(recovery.id, length: resume.synced)
                    let part = recovery.inbox.recoveryPart(recovery.id)
                    hash = try await withHolds(connection) { try Self.hashPrefix(of: part, length: resume.synced) }
                } else {
                    handle = try recovery.inbox.createRecoveryPart(recovery.id)
                }
            }
            try await connection.send(TransferAccept(offset: offset))
            resumable = kind == "file" || kind == "folder"
            written = offset

            // The payload.
            var memory = Data()
            var remaining = offer.size - offset
            var lastSync = offset
            /// Opens folder entries until one still needs bytes; checks each one as it ends.
            func advanceFolder() throws {
                guard let stager else { return }
                while current < fileIndexes.count, entryDone == (manifestEntries[fileIndexes[current]].size ?? 0) {
                    try handle?.synchronize(); try handle?.close(); handle = nil
                    guard hex(entryHash.finalize()) == manifestEntries[fileIndexes[current]].sha256 else { throw TransferFailure.rejected(.corrupt) }
                    current += 1; entryHash = SHA256(); entryDone = 0
                    if current < fileIndexes.count { handle = try stager.openFile(fileIndexes[current], keeping: 0) }
                }
            }
            try advanceFolder()
            while remaining > 0 {
                guard let chunk = try await connection.readRaw(maxLength: Int(min(remaining, 256 * 1024)), deadline: .now + limits.idle), !chunk.isEmpty else { throw WireError.truncated }
                remaining -= Int64(chunk.count)
                if kind == "folder" {
                    var rest = chunk[...]
                    while !rest.isEmpty {
                        guard current < fileIndexes.count else { throw TransferFailure.rejected(.invalid) }
                        let size = manifestEntries[fileIndexes[current]].size ?? 0
                        let piece = rest.prefix(Int(size - entryDone))
                        try handle?.write(contentsOf: piece); entryHash.update(data: piece)
                        entryDone += Int64(piece.count); written += Int64(piece.count)
                        rest = rest.dropFirst(piece.count)
                        try advanceFolder()
                    }
                } else {
                    hash.update(data: chunk)
                    if kind == "text" || kind == "image" { memory.append(chunk) }
                    try handle?.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                }
                if resumable, written - lastSync >= limits.syncEvery {
                    try handle?.synchronize()
                    try await recordSynced(deviceID: deviceID, id: offer.id, written)
                    lastSync = written
                }
                receiving[key]?.progress = TransferProgress(doneBytes: written, totalBytes: offer.size)
                receiving[key]?.phase = "streaming"
            }
            try advanceFolder()
            try handle?.synchronize(); try handle?.close(); handle = nil
            if recovery != nil { try await recordSynced(deviceID: deviceID, id: offer.id, written) }
            try checkpoint(.written)

            // `done`, or the sender giving up.
            guard let doneFrame = try await connection.readFrame(timeout: limits.idle) else { throw WireError.truncated }
            if doneFrame.type == TransferAbort.type {
                let abort = try doneFrame.decode(TransferAbort.self)
                try await dropPart(deviceID: deviceID, id: offer.id, status: abort.reason == "cancelled" ? "cancelled" : "failed")
                record = nil
                throw TransferFailure.cancelled
            }
            let done = try doneFrame.decode(TransferDone.self)
            receiving[key]?.phase = "verifying"
            let actual = kind == "folder" ? offer.sha256 : hex(hash.finalize())
            guard done.sha256 == offer.sha256, actual == offer.sha256 else { throw TransferFailure.rejected(.corrupt) }
            if kind == "text" { guard String(data: memory, encoding: .utf8) != nil else { throw TransferFailure.rejected(.invalid) } }
            if kind == "image" { guard ImageKind.matches(memory, mime: offer.mime) else { throw TransferFailure.rejected(.invalid) } }
            if offer.keep { row.sha256 = actual }
            // Kept: the name and path are recorded before the item is published, so a restart
            // finds them; a don't-keep name is chosen now and stays in memory.
            var name: String?
            if let recovery {
                switch kind {
                case "image":
                    let stem = TransferInbox.split(TransferInbox.clean(offer.name)).stem
                    name = stem + "." + (ImageKind.extensions[offer.mime] ?? "img")
                default: name = TransferInbox.clean(offer.name)
                }
                if offer.keep { row.targetName = name; row.path = recovery.inbox.directory.appendingPathComponent(name!).path }
            }
            try await history.save(row)
            try checkpoint(.hashed)
            if let recovery, let wanted = name {
                let published = kind == "folder" ? try recovery.inbox.publishStaging(recovery.id, as: wanted) : try recovery.inbox.publishPart(recovery.id, as: wanted)
                name = published
                if offer.keep { row.targetName = published; row.path = recovery.inbox.directory.appendingPathComponent(published).path }
            }
            try checkpoint(.renamed)
            if kind == "text" {
                let value = String(decoding: memory, as: UTF8.self)
                if offer.keep { row.text = value } else { rememberText(value, key: key) }
            }
            if kind == "image" && !offer.keep { rememberImage(memory, mime: offer.mime, key: key) }
            row.status = "ok"; row.phase = nil; row.progress = nil; row.resumedFrom = nil
            try await history.save(row)
            record = row
            try await history.store.execute("DELETE FROM parts WHERE device_id=? AND id=?", bindings: [.text(deviceID), .text(offer.id)])
            try checkpoint(.committed)
            if let recovery {
                if kind == "folder" { _ = unlink(recovery.inbox.sidecar(recovery.id).path) } else { _ = unlink(recovery.inbox.recoveryPart(recovery.id).path) }
            }
            receiving[key] = nil
            if !dropAck { try await connection.send(TransferAck(storedAs: offer.keep ? (name ?? "") : "")) }
            await connection.finish()
        } catch {
            simulatedCrash = (error as? TransferFailure).map { if case .crash = $0 { return true }; return false } ?? false
            var reason: TransferRejectReason?
            var limitName: String?
            if case TransferFailure.rejected(let rejected) = error { reason = rejected }
            if case TransferFailure.folderLimit(let limit) = error { reason = .folderLimits; limitName = limit.rawValue }
            if let limit = error as? FolderLimitError { reason = .folderLimits; limitName = limit.rawValue }
            // The row and the part are settled before any reject goes out, so a sender that
            // reads the reject sees the receiver's cleanup done.
            if !simulatedCrash, var row = record {
                let key = deviceID + "/" + row.id
                receiving[key] = nil
                // Never undo a committed row because the acknowledgement was lost.
                if row.status != "ok" {
                    // A file or folder cut off after some bytes keeps its part for a resume;
                    // anything refused, damaged or empty goes.
                    if resumable, reason == nil, written > 0, let recovery {
                        try? handle?.synchronize()
                        try? await recordSynced(deviceID: row.deviceID, id: row.id, written)
                        try? await history.store.execute("UPDATE parts SET expires_at=? WHERE device_id=? AND id=?",
                                                         bindings: [.real(clock.now().timeIntervalSince1970 + limits.partLifetime), .text(row.deviceID), .text(row.id)])
                        _ = recovery
                        row.status = "interrupted"
                    } else {
                        row.status = "failed"
                        try? await dropPart(deviceID: row.deviceID, id: row.id, status: nil)
                    }
                    row.phase = nil; row.progress = nil; row.text = nil; row.path = nil; row.targetName = nil; row.sha256 = nil
                    try? await history.save(row)
                }
            }
            if let reason {
                try? await connection.send(TransferReject(reason, limit: limitName))
                await connection.finish()
            }
        }
        if let admittedID { active[deviceID]?.remove(admittedID) }
        reservedBytes -= reserved
        await connection.close()
    }

    /// The offer's own fields, before anything is stored.
    static func check(_ offer: TransferOffer) throws {
        guard ["text", "file", "image", "folder"].contains(offer.kind), offer.size >= 0, isDigest(offer.sha256),
              ["deliver", "follow", "open"].contains(offer.intent) else { throw TransferFailure.rejected(.invalid) }
        if offer.intent == "follow" { guard let clip = offer.clipKind, ["text", "url", "image"].contains(clip) else { throw TransferFailure.rejected(.invalid) } }
        else { guard offer.clipKind == nil else { throw TransferFailure.rejected(.invalid) } }
        if offer.intent == "open" { guard offer.kind == "text" else { throw TransferFailure.rejected(.invalid) } }
        if offer.kind == "image" { guard ImageKind.extensions[offer.mime] != nil else { throw TransferFailure.rejected(.invalid) } }
        if offer.kind == "folder" { guard let entries = offer.entries, entries >= 0 else { throw TransferFailure.rejected(.invalid) } }
    }

    /// The manifest frames up to `manifest_end`, as the exact bytes received.
    private func readManifest(_ connection: WireConnection) async throws -> Data {
        var frames = Data(), count = 0
        while true {
            guard let frame = try await connection.readFrame(timeout: limits.idle) else { throw WireError.truncated }
            if frame.type == ManifestEnd.type {
                guard try frame.decode(ManifestEnd.self).count == count else { throw TransferFailure.rejected(.invalid) }
                return frames
            }
            let part: ManifestFrame
            do { part = try frame.decode(ManifestFrame.self) } catch { throw TransferFailure.rejected(.invalid) }
            guard part.first == count else { throw TransferFailure.rejected(.invalid) }
            count += part.entries.count
            frames.append(try WireCodec.frame(header: frame.header))
            guard frames.count <= limits.folder.manifestBytes else { throw FolderLimitError.manifest }
            guard count <= limits.folder.entries else { throw FolderLimitError.entries }
        }
    }

    /// Runs slow local work, such as re-hashing a part, and tells the sender to hold on every
    /// 5 seconds meanwhile.
    private func withHolds<T: Sendable>(_ connection: WireConnection, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let job = Task.detached { try work() }
        let holding = Task {
            let started = ContinuousClock.now
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(5))
                guard ContinuousClock.now - started < .seconds(1800) else { return }
                try await connection.send(TransferHold())
            }
        }
        defer { holding.cancel() }
        return try await job.value
    }

    static func hashPrefix(of url: URL, length: Int64) throws -> SHA256 {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AgentError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var hash = SHA256(), remaining = length
        while remaining > 0, let chunk = try handle.read(upToCount: Int(min(remaining, 1024 * 1024))), !chunk.isEmpty {
            hash.update(data: chunk); remaining -= Int64(chunk.count)
        }
        guard remaining == 0 else { throw AgentError.storage }
        return hash
    }
    static func writeNew(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data); try handle.synchronize()
    }

    private func partRow(deviceID: String, id: String) async throws -> PartRow? {
        guard let row = try await history.store.query("SELECT * FROM parts WHERE device_id=? AND id=?", bindings: [.text(deviceID), .text(id)]).first,
              case .text(let rid) = row["recovery_id"], case .text(let directory) = row["directory"], case .text(let kind) = row["kind"],
              case .text(let identity) = row["identity"], case .integer(let synced) = row["synced_bytes"] else { return nil }
        return PartRow(recoveryID: rid, directory: directory, kind: kind, identity: identity, synced: synced)
    }
    private func recordSynced(deviceID: String, id: String, _ bytes: Int64) async throws {
        try await history.store.execute("UPDATE parts SET synced_bytes=? WHERE device_id=? AND id=?", bindings: [.integer(bytes), .text(deviceID), .text(id)])
    }

    /// Removes a received item's part files and its parts row. With `status`, an unfinished
    /// row gets it. True when there was a part.
    @discardableResult
    func dropPart(deviceID: String, id: String, status: String?) async throws -> Bool {
        let part = try await partRow(deviceID: deviceID, id: id)
        if let part {
            TransferInbox.removeRecoveryFiles(directory: URL(fileURLWithPath: part.directory), id: part.recoveryID)
            try await history.store.execute("DELETE FROM parts WHERE device_id=? AND id=?", bindings: [.text(deviceID), .text(id)])
        }
        if let status, var row = try await history.record(deviceID: deviceID, id: id), row.direction == "received", ["receiving", "interrupted"].contains(row.status) {
            row.status = status; row.targetName = nil; row.path = nil; row.sha256 = nil
            try await history.save(row)
        }
        return part != nil
    }

    // MARK: After a restart

    public func reconcile() async throws {
        let now = clock.now()
        let waiting = Set(try await history.store.query("SELECT device_id, id FROM queue").compactMap { row -> String? in
            guard case .text(let d) = row["device_id"], case .text(let i) = row["id"] else { return nil }
            return d + "/" + i
        })
        for var row in try await history.rows() {
            if row.direction == "sent" && row.status == "sending" {
                // A send this device was in the middle of when it stopped. One that waits goes
                // back to the queue, due now. Otherwise how far it got is not recorded, so the
                // other device may have the item: unconfirmed, not failed. Retry settles it,
                // because the other device answers `duplicate` for an id it stored.
                if waiting.contains(row.deviceID + "/" + row.id) {
                    row.status = "waiting"
                    try await history.store.execute("UPDATE queue SET next_attempt_at=? WHERE device_id=? AND id=?",
                                                    bindings: [.real(now.timeIntervalSince1970), .text(row.deviceID), .text(row.id)])
                } else { row.status = "unconfirmed" }
                try await history.save(row)
                continue
            }
            guard row.direction == "received", row.status == "receiving" else { continue }
            guard let rid = row.recoveryID else {
                // A row from before recovery ids: the old rule.
                var valid = false
                if let name = row.targetName, let hash = row.sha256, let final = try? inbox.url(name), inbox.exists(name) {
                    valid = (try? TransferInbox.hash(final)) == hash
                }
                row.status = valid ? "ok" : "failed"
                if let name = row.targetName { try? inbox.removePart(name) }
                if !valid { row.targetName = nil; row.path = nil }
                try await history.save(row)
                continue
            }
            // Only a file or folder can be found finished on disk. A text is stored with its
            // row in one step, so one still marked as arriving never arrived.
            guard let part = try await partRow(deviceID: row.deviceID, id: row.id) else {
                row.status = "failed"; row.targetName = nil; row.path = nil; row.sha256 = nil
                try await history.save(row); continue
            }
            let folder = TransferInbox(resolved: URL(fileURLWithPath: part.directory))
            var status = "failed"
            if part.kind == "folder" {
                var info = stat()
                let staged = lstat(folder.staging(rid).path, &info) == 0
                let sidecar = lstat(folder.sidecar(rid).path, &info) == 0
                if staged { status = part.synced > 0 ? "interrupted" : "failed" }
                else if sidecar { status = "ok" }
            } else if let links = folder.linkCount(ofPart: rid) {
                // Published after its check: the link to its name is the commit.
                if links >= 2 { status = "ok" }
                else if part.kind == "file", part.synced > 0 { status = "interrupted" }
            }
            row.status = status
            if status == "ok" {
                if row.keep, part.kind != "folder", let name = folder.publishedName(ofPart: rid) {
                    row.targetName = name; row.path = folder.directory.appendingPathComponent(name).path
                }
                TransferInbox.removeRecoveryFiles(directory: folder.directory, id: rid, keepStaging: true)
                try await history.store.execute("DELETE FROM parts WHERE device_id=? AND id=?", bindings: [.text(row.deviceID), .text(row.id)])
            } else {
                row.targetName = nil; row.path = nil; row.sha256 = nil
                if status == "failed" {
                    TransferInbox.removeRecoveryFiles(directory: folder.directory, id: rid)
                    try await history.store.execute("DELETE FROM parts WHERE device_id=? AND id=?", bindings: [.text(row.deviceID), .text(row.id)])
                }
            }
            try await history.save(row)
        }
        try await sweepParts()
    }

    /// Drops parts past their lifetime, and every Catflap entry in a known inbox folder that
    /// no live part names. Only names of the exact `.catflap-<32 hex>` form are touched.
    public func sweepParts() async throws {
        let now = clock.now().timeIntervalSince1970
        for row in try await history.store.query("SELECT device_id, id FROM parts WHERE expires_at<?", bindings: [.real(now)]) {
            guard case .text(let device) = row["device_id"], case .text(let id) = row["id"] else { continue }
            try await dropPart(deviceID: device, id: id, status: "expired")
        }
        var live: Set<String> = []
        var folders: Set<String> = [inbox.directory.path]
        if let current = try? await currentInbox() { folders.insert(current.directory.path) }
        for row in try await history.store.query("SELECT recovery_id, directory FROM parts") {
            if case .text(let id) = row["recovery_id"] { live.insert(id) }
            if case .text(let directory) = row["directory"] { folders.insert(directory) }
        }
        // Receives under way hold their part rows already; nothing else may own a part.
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names {
                guard let id = TransferInbox.recoveryID(inName: name), !live.contains(id) else { continue }
                let path = folder + "/" + name
                if name.hasSuffix(".partdir") { TransferInbox.removeTree(path) } else { _ = unlink(path) }
            }
        }
    }
}

extension TransferInbox {
    /// An inbox at a folder that is already resolved and checked, without touching it.
    init(resolved directory: URL) { self.directory = directory }
    static func removeRecoveryFiles(directory: URL, id: String, keepStaging: Bool = false) {
        let folder = TransferInbox(resolved: directory)
        _ = unlink(folder.recoveryPart(id).path)
        _ = unlink(folder.sidecar(id).path)
        if !keepStaging { removeTree(folder.staging(id).path) }
    }
    /// The name in this folder that is the same file as the part: where it was published.
    func publishedName(ofPart id: String) -> String? {
        var part = stat()
        guard lstat(recoveryPart(id).path, &part) == 0 else { return nil }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        for name in names where TransferInbox.recoveryID(inName: name) == nil {
            var info = stat()
            if lstat(directory.appendingPathComponent(name).path, &info) == 0, info.st_ino == part.st_ino, info.st_dev == part.st_dev { return name }
        }
        return nil
    }
}
