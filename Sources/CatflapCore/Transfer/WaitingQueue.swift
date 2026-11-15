import Foundation

extension TransferService {
    // MARK: The waiting queue

    /// Records a kept item so it survives a restart and waits for its device: by reference
    /// for a file or folder (with what it looked like), from its row for a text, and as the
    /// private copy for a clipboard image.
    func enterQueue(_ key: String) async throws {
        guard let item = outgoing[key], let source = item.prepared else { return }
        let now = clock.now().timeIntervalSince1970
        let kind: String
        var path: String?, manifestPath: String?
        switch item.payload {
        case .text: kind = "row_text"
        case .file(let url): kind = "file"; path = url.path
        case .image(let url, _): kind = "owned_copy"; path = url.path
        case .folder(let url):
            kind = "folder"; path = url.resolvingSymlinksInPath().path
            if let manifest = source.manifest {
                _ = try AgentPaths(directory: outbox)
                let file = outbox.appendingPathComponent(item.row.id + ".manifest")
                try AgentPaths.writePrivate(try JSONEncoder().encode(manifest), to: file)
                manifestPath = file.path
            }
        }
        let stat = source.stat
        try await history.store.execute("""
        INSERT INTO queue(device_id,id,queued_at,expires_at,next_attempt_at,attempts,source,source_path,source_size,source_mtime_ns,source_dev,source_ino,source_sha256,manifest_path)
        VALUES(?,?,?,?,?,0,?,?,?,?,?,?,?,?) ON CONFLICT(device_id,id) DO UPDATE SET next_attempt_at=excluded.next_attempt_at,
        source=excluded.source,source_path=excluded.source_path,source_size=excluded.source_size,source_mtime_ns=excluded.source_mtime_ns,
        source_dev=excluded.source_dev,source_ino=excluded.source_ino,source_sha256=excluded.source_sha256,manifest_path=excluded.manifest_path
        """, bindings: [.text(item.row.deviceID), .text(item.row.id), .real(now), .real(now + limits.waitLifetime), .real(now), .text(kind), path.sql,
                        stat.map { .integer($0.size) } ?? .null, stat.map { .integer($0.mtimeNs) } ?? .null, stat.map { .integer($0.device) } ?? .null,
                        stat.map { .integer($0.inode) } ?? .null, .text(source.sha256), manifestPath.sql])
    }
    func leaveQueue(_ key: String) async throws {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        try await history.store.execute("DELETE FROM queue WHERE device_id=? AND id=?", bindings: [.text(parts[0]), .text(parts[1])])
    }
    func isQueued(_ key: String) async throws -> Bool {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        return try await !history.store.query("SELECT 1 FROM queue WHERE device_id=? AND id=?", bindings: [.text(parts[0]), .text(parts[1])]).isEmpty
    }

    /// The wait after the n-th failed attempt in a row: 30 s doubling to 5 minutes, ±10 %.
    public nonisolated static func backoff(afterFailures count: Int, jitter: Double = Double.random(in: -0.1...0.1)) -> TimeInterval {
        let base = min(30 * pow(2, Double(max(0, count - 1))), 300)
        return base * (1 + jitter)
    }
    /// One more failed attempt for the item's device: every item it has waits the device's
    /// backoff.
    func backOff(_ key: String, unconfirmed: Bool = false) async throws {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let device = parts[0]
        let count = (failures[device] ?? 0) + 1
        failures[device] = count
        let next = clock.now().timeIntervalSince1970 + Self.backoff(afterFailures: count)
        try await history.store.execute("UPDATE queue SET attempts=attempts+1, unconfirmed=?, sent_bytes=? WHERE device_id=? AND id=?",
                                        bindings: [.integer(unconfirmed ? 1 : 0), .integer(results[key]?.progress?.doneBytes ?? 0), .text(device), .text(parts[1])])
        try await history.store.execute("UPDATE queue SET next_attempt_at=? WHERE device_id=?", bindings: [.real(next), .text(device)])
    }

    /// A device answered: a session either way, a ping, or a presence check that found it.
    /// Its waiting items are due now.
    public func peerSeen(deviceID: String) async {
        failures[deviceID] = nil
        let due = (try? await history.store.query("SELECT 1 FROM queue WHERE device_id=? LIMIT 1", bindings: [.text(deviceID)]))?.isEmpty == false
        guard due else { return }
        try? await history.store.execute("UPDATE queue SET next_attempt_at=? WHERE device_id=?", bindings: [.real(clock.now().timeIntervalSince1970), .text(deviceID)])
        kick()
    }

    func kick() { wake?.yield(()) }

    /// Starts the waiting queue's scheduler; `install(on:)` calls it.
    public func startScheduler() {
        guard schedulerTask == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        let sleeper = self.sleeper
        schedulerTask = Task { [weak self] in
            // Each device's first try after a start comes 0 to 10 s in, so they do not all go at once.
            await sleeper.sleep(seconds: Double.random(in: 0...10))
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled {
                guard let self else { return }
                await self.runDueDeliveries()
                let wait = await self.secondsUntilNextDue()
                // Sleep until the next item is due, or a kick, whichever comes first.
                let napping = Task { await sleeper.sleep(seconds: max(1, min(wait, 60))); continuation.yield(()) }
                _ = await iterator.next()
                napping.cancel()
            }
        }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3600)) } catch { return }
                try? await self?.sweepParts()
            }
        }
    }
    private func secondsUntilNextDue() async -> Double {
        let rows = (try? await history.store.query("SELECT MIN(next_attempt_at) AS next FROM queue")) ?? []
        guard case .real(let next) = rows.first?["next"] else { return 60 }
        return next - clock.now().timeIntervalSince1970
    }

    /// One pass of the queue: expires items past their wait, then for each device with an
    /// item due, pings it and delivers its due items oldest first. At most one attempt per
    /// device and `queueDevices` devices at once. Tests call it directly with their clock.
    public func runDueDeliveries() async {
        let now = clock.now().timeIntervalSince1970
        try? await expireWaiting(now: now)
        guard let rows = try? await history.store.query("SELECT device_id, id FROM queue WHERE next_attempt_at<=? ORDER BY queued_at, id", bindings: [.real(now)]) else { return }
        var perDevice: [String: [String]] = [:]
        var order: [String] = []
        for row in rows {
            guard case .text(let device) = row["device_id"], case .text(let id) = row["id"] else { continue }
            if perDevice[device] == nil { order.append(device) }
            perDevice[device, default: []].append(device + "/" + id)
        }
        let devices = order.filter { !serving.contains($0) }.prefix(limits.queueDevices)
        for device in devices { serving.insert(device) }
        await withTaskGroup(of: Void.self) { group in
            for device in devices {
                let keys = perDevice[device] ?? []
                group.addTask { await self.serve(device: device, keys: keys) }
            }
        }
    }

    private func serve(device: String, keys: [String]) async {
        defer { serving.remove(device) }
        guard let connector else { return }
        // A ping first: cheap, and an answer proves the device admits this one.
        do { _ = try await connector.ping(deviceID: device, timeout: limits.ping) }
        catch {
            let count = (failures[device] ?? 0) + 1
            failures[device] = count
            for key in keys where !sending.contains(key) {
                if outgoing[key] == nil { try? await restore(key) }
                try? await stillWaiting(key)
            }
            let next = clock.now().timeIntervalSince1970 + Self.backoff(afterFailures: count)
            try? await history.store.execute("UPDATE queue SET next_attempt_at=? WHERE device_id=?", bindings: [.real(next), .text(device)])
            return
        }
        failures[device] = nil
        for key in keys where !sending.contains(key) {
            if outgoing[key] == nil {
                do { try await restore(key) } catch { continue }
            }
            guard let item = outgoing[key], (try? await isQueued(key)) == true else { continue }
            if item.prepared == nil {
                await finish(key, outcome: .permanent(TransferFailure.missingRetryContent.errorDescription!)); continue
            }
            sending.insert(key)
            var row = item.row
            row.status = "sending"; row.phase = "connecting"
            outgoing[key]?.row = row; results[key] = row
            try? await history.save(row)
            let outcome = await attempt(key)
            await finish(key, outcome: outcome)
            // Stop at the first item that has to wait again: the device went away.
            if case .retriable = outcome { break }
        }
    }
    /// A ping that got no answer: one more attempt, and the item keeps (or gets) its reason.
    private func stillWaiting(_ key: String) async throws {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        try await history.store.execute("UPDATE queue SET attempts=attempts+1 WHERE device_id=? AND id=?", bindings: [.text(parts[0]), .text(parts[1])])
        var found = results[key]
        if found == nil { found = try await history.record(deviceID: parts[0], id: parts[1]) }
        guard var row = found else { return }
        var changed = false
        if row.status != "waiting" { row.status = "waiting"; changed = true }
        if row.error == nil, let device = try await history.store.devices().first(where: { $0.id == row.deviceID }) {
            row.error = PeerError.unreachable(device: device.name, lastSeenBuild: device.build).errorDescription
            changed = true
        }
        if changed { try await history.save(row) }
        results[key] = row
        outgoing[key]?.row = row
    }

    /// Rebuilds an item this agent did not start, from its row and queue entry, after a restart.
    func restore(_ key: String) async throws {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let row = try await history.record(deviceID: parts[0], id: parts[1]),
              let entry = try await history.store.query("SELECT * FROM queue WHERE device_id=? AND id=?", bindings: [.text(parts[0]), .text(parts[1])]).first,
              case .text(let source) = entry["source"] else { throw TransferFailure.missingRetryContent }
        func s(_ k: String) -> String? { if case .text(let v) = entry[k] { v } else { nil } }
        func i(_ k: String) -> Int64? { if case .integer(let v) = entry[k] { v } else { nil } }
        let payload: TransferPayload
        var prepared: PreparedSource?
        switch source {
        case "row_text":
            guard let text = row.text else { throw TransferFailure.missingRetryContent }
            payload = .text(text)
            prepared = (try? TransferService.prepare(payload, limits: limits).get())
        case "file", "owned_copy":
            guard let path = s("source_path"), let size = i("source_size"), let mtime = i("source_mtime_ns"), let dev = i("source_dev"),
                  let ino = i("source_ino"), let sha = s("source_sha256") else { throw TransferFailure.missingRetryContent }
            let url = URL(fileURLWithPath: path)
            payload = source == "file" ? .file(url) : .image(url, mime: row.mime ?? "image/png")
            prepared = PreparedSource(kind: source == "file" ? "file" : "image", size: size, sha256: sha, mime: row.mime ?? "application/octet-stream",
                                      name: source == "file" ? url.lastPathComponent : "Clipboard image", url: url,
                                      stat: SourceStat(size: size, mtimeNs: mtime, device: dev, inode: ino))
        case "folder":
            guard let path = s("source_path"), let file = s("manifest_path"),
                  let manifest = try? JSONDecoder().decode(FolderManifest.self, from: Data(contentsOf: URL(fileURLWithPath: file))) else {
                throw TransferFailure.missingRetryContent
            }
            let url = URL(fileURLWithPath: path)
            payload = .folder(url)
            prepared = PreparedSource(kind: "folder", size: manifest.totalSize, sha256: manifest.digest, mime: "inode/directory",
                                      name: url.lastPathComponent, url: url, manifest: manifest)
        default: throw TransferFailure.missingRetryContent
        }
        outgoing[key] = OutgoingItem(row: row, payload: payload, prepared: prepared, waits: true)
        results[key] = row
    }

    /// Items that waited their whole time fail as expired, and the platform hears of each.
    func expireWaiting(now: TimeInterval) async throws {
        let rows = try await history.store.query("SELECT device_id, id FROM queue WHERE expires_at<=?", bindings: [.real(now)])
        for entry in rows {
            guard case .text(let device) = entry["device_id"], case .text(let id) = entry["id"] else { continue }
            let key = device + "/" + id
            guard !sending.contains(key), var row = try await history.record(deviceID: device, id: id) else { continue }
            let name = try await history.store.devices().first(where: { $0.id == device })?.name ?? "the other device"
            row.status = "expired"
            row.error = "Not delivered: \(name) stayed away for 7 days."
            try await history.store.execute("DELETE FROM queue WHERE device_id=? AND id=?", bindings: [.text(device), .text(id)])
            row.waiting = nil
            try await history.save(row)
            if ["file", "folder"].contains(row.kind) { try await rememberForget(deviceID: device, id: id) }
            try await cleanOwnedCopy(row)
            outgoing[key] = nil
            results[key] = row
            await eventHandler?(.expired(row))
        }
    }
}

extension SourceStat {
    init(size: Int64, mtimeNs: Int64, device: Int64, inode: Int64) {
        self.size = size; self.mtimeNs = mtimeNs; self.device = device; self.inode = inode
    }
}
