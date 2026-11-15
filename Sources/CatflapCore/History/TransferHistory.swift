import Foundation

/// An entry a folder's sender left out, and why: `symlink`, `special` or `unreadable`.
public struct SkippedEntry: Codable, Sendable, Equatable {
    public let path: [String]
    public let reason: String
    public init(path: [String], reason: String) { self.path = path; self.reason = reason }
}
/// Bytes done of a transfer under way or interrupted.
public struct TransferProgress: Codable, Sendable, Equatable {
    public var doneBytes: Int64
    public var totalBytes: Int64
    enum CodingKeys: String, CodingKey { case doneBytes = "done_bytes", totalBytes = "total_bytes" }
    public init(doneBytes: Int64, totalBytes: Int64) { self.doneBytes = doneBytes; self.totalBytes = totalBytes }
}
/// A sent item waiting for its device: when it was queued, how often it was tried, when the
/// next try is due and when it gives up.
public struct WaitingInfo: Codable, Sendable, Equatable {
    public var queuedAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date
    public var expiresAt: Date
    /// The last attempt handed `done` over and heard nothing back: the device may have it.
    public var unconfirmed: Bool
    enum CodingKeys: String, CodingKey {
        case attempts, unconfirmed
        case queuedAt = "queued_at", nextAttemptAt = "next_attempt_at", expiresAt = "expires_at"
    }
}

/// One transfer, as history keeps it and as the control commands show it.
///
/// Status, sent: `sending`, `waiting`, `ok`, `failed`, `unconfirmed`, `cancelled`, `expired`.
/// Received: `receiving`, `interrupted`, `ok`, `failed`, `cancelled`, `expired`. `phase` is
/// display detail of a transfer under way: `preparing`, `connecting`, `resuming`, `streaming`,
/// `confirming`, `verifying`.
public struct TransferRecord: Codable, Sendable {
    public var id: String
    public var deviceID: String
    public var timestamp: Date = Date()
    public var direction: String
    public var kind: String
    public var size: Int64
    public var status: String
    public var text: String?
    public var path: String?
    public var sha256: String?
    public var keep: Bool = true
    public var targetName: String?
    public var error: String?
    /// The batch a send to several devices or of several files belongs to; sent rows only.
    public var sendID: String?
    public var mime: String?
    public var intent: String = "deliver"
    public var clipKind: String?
    /// Names a receive's part file. Never shown: it stays between the store and the disk.
    public var recoveryID: String?
    public var entries: Int?
    public var skipped: [SkippedEntry]?
    public var updatedAt: Date?
    public var phase: String?
    public var resumedFrom: Int64?
    public var progress: TransferProgress?
    public var waiting: WaitingInfo?
    public var partExpiresAt: Date?
    /// In a list: at most 200 characters of a kept text, in place of the text.
    public var preview: String?
    var linkOpenable: Bool?
    public var openable: Bool { linkOpenable ?? (direction == "received" && status == "ok" && text.flatMap(LinkNormalizer.normalize) != nil) }
    public var canRetry: Bool { direction == "sent" && ["failed", "unconfirmed", "expired", "cancelled"].contains(status) }
    public var canCancel: Bool {
        direction == "sent" ? ["sending", "waiting"].contains(status) : status == "interrupted"
    }
    enum CodingKeys: String, CodingKey {
        case id, timestamp, direction, kind, size, status, text, path, sha256, keep, error, mime, intent, entries, skipped, phase, progress, waiting, preview
        case deviceID = "device_id", targetName = "target_name", canRetry = "can_retry", canCancel = "can_cancel"
        case openable
        case sendID = "send_id", clipKind = "clip_kind", updatedAt = "updated_at", resumedFrom = "resumed_from", partExpiresAt = "part_expires_at"
    }
    public init(id: String, deviceID: String, direction: String, kind: String, size: Int64, status: String, keep: Bool = true) {
        self.id = id; self.deviceID = deviceID; self.direction = direction; self.kind = kind; self.size = size; self.status = status; self.keep = keep
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); deviceID = try c.decode(String.self, forKey: .deviceID)
        timestamp = try c.decode(Date.self, forKey: .timestamp); direction = try c.decode(String.self, forKey: .direction)
        kind = try c.decode(String.self, forKey: .kind); size = try c.decode(Int64.self, forKey: .size); status = try c.decode(String.self, forKey: .status)
        text = try c.decodeIfPresent(String.self, forKey: .text); path = try c.decodeIfPresent(String.self, forKey: .path)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256); keep = try c.decode(Bool.self, forKey: .keep)
        targetName = try c.decodeIfPresent(String.self, forKey: .targetName); error = try c.decodeIfPresent(String.self, forKey: .error)
        sendID = try c.decodeIfPresent(String.self, forKey: .sendID); mime = try c.decodeIfPresent(String.self, forKey: .mime)
        intent = try c.decodeIfPresent(String.self, forKey: .intent) ?? "deliver"; clipKind = try c.decodeIfPresent(String.self, forKey: .clipKind)
        entries = try c.decodeIfPresent(Int.self, forKey: .entries); skipped = try c.decodeIfPresent([SkippedEntry].self, forKey: .skipped)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt); phase = try c.decodeIfPresent(String.self, forKey: .phase)
        resumedFrom = try c.decodeIfPresent(Int64.self, forKey: .resumedFrom); progress = try c.decodeIfPresent(TransferProgress.self, forKey: .progress)
        waiting = try c.decodeIfPresent(WaitingInfo.self, forKey: .waiting); partExpiresAt = try c.decodeIfPresent(Date.self, forKey: .partExpiresAt)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        linkOpenable = try c.decodeIfPresent(Bool.self, forKey: .openable)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(openable, forKey: .openable)
        try c.encode(id, forKey: .id); try c.encode(deviceID, forKey: .deviceID); try c.encode(timestamp, forKey: .timestamp)
        try c.encode(direction, forKey: .direction); try c.encode(kind, forKey: .kind); try c.encode(size, forKey: .size); try c.encode(status, forKey: .status)
        try c.encodeIfPresent(text, forKey: .text); try c.encodeIfPresent(path, forKey: .path); try c.encodeIfPresent(sha256, forKey: .sha256)
        try c.encode(keep, forKey: .keep); try c.encodeIfPresent(targetName, forKey: .targetName); try c.encodeIfPresent(error, forKey: .error); try c.encode(canRetry, forKey: .canRetry)
        try c.encode(canCancel, forKey: .canCancel); try c.encodeIfPresent(sendID, forKey: .sendID); try c.encodeIfPresent(mime, forKey: .mime)
        try c.encode(intent, forKey: .intent); try c.encodeIfPresent(clipKind, forKey: .clipKind); try c.encodeIfPresent(entries, forKey: .entries)
        try c.encodeIfPresent(skipped, forKey: .skipped); try c.encodeIfPresent(updatedAt, forKey: .updatedAt); try c.encodeIfPresent(phase, forKey: .phase)
        try c.encodeIfPresent(resumedFrom, forKey: .resumedFrom); try c.encodeIfPresent(progress, forKey: .progress); try c.encodeIfPresent(waiting, forKey: .waiting)
        try c.encodeIfPresent(partExpiresAt, forKey: .partExpiresAt); try c.encodeIfPresent(preview, forKey: .preview)
    }
    /// The row without its body, for lists.
    public var listed: TransferRecord {
        var row = self
        row.linkOpenable = openable
        if let text { row.preview = String(text.prefix(200)) }
        row.text = nil
        return row
    }
}

/// Which rows `transfers.list` returns.
public struct TransferQuery: Sendable {
    /// Any of `waiting`, `active` (sending, receiving, interrupted), `done`; empty for all.
    public var groups: Set<String> = []
    public var deviceID: String?
    public var direction: String?
    public var search: String?
    public var limit = 200
    public var before: Date?
    public init() {}
}
public struct TransferPage: Codable, Sendable {
    public let items: [TransferRecord]
    public let nextBefore: String?
    enum CodingKeys: String, CodingKey { case items, nextBefore = "next_before" }
}

public struct TransferHistory: Sendable {
    public let store: Store
    public init(store: Store) { self.store = store }
    public func save(_ r: TransferRecord) async throws {
        // A "don't keep" row holds nothing taken from the content: no text, no path or file
        // name, and no hash, which would let a short text be guessed. A receive under way is
        // found again by its recovery id, so it needs none of them either.
        let keep = r.keep
        let skipped = try r.skipped.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try await store.execute("""
        INSERT INTO history(id,device_id,timestamp,direction,kind,size,status,text,path,sha256,keep,target_name,
                            send_id,mime,intent,clip_kind,recovery_id,error,entries,skipped,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id,id) DO UPDATE SET
        status=excluded.status,text=excluded.text,path=excluded.path,sha256=excluded.sha256,keep=excluded.keep,target_name=excluded.target_name,
        send_id=excluded.send_id,mime=excluded.mime,intent=excluded.intent,clip_kind=excluded.clip_kind,recovery_id=excluded.recovery_id,
        error=excluded.error,entries=excluded.entries,skipped=excluded.skipped,updated_at=excluded.updated_at,size=excluded.size,kind=excluded.kind
        """, bindings: [.text(r.id), .text(r.deviceID), .real(r.timestamp.timeIntervalSince1970), .text(r.direction), .text(r.kind), .integer(r.size),
                        .text(r.status), keep ? r.text.sql : .null, keep ? r.path.sql : .null, keep ? r.sha256.sql : .null, .integer(keep ? 1 : 0),
                        keep ? r.targetName.sql : .null, r.sendID.sql, r.mime.sql, .text(r.intent), r.clipKind.sql, r.recoveryID.sql, r.error.sql,
                        r.entries.map { .integer(Int64($0)) } ?? .null, keep ? skipped.sql : .null, .real(Date().timeIntervalSince1970)])
    }
    private static let select = """
    SELECT h.*, q.queued_at AS q_queued_at, q.attempts AS q_attempts, q.next_attempt_at AS q_next, q.expires_at AS q_expires,
           q.unconfirmed AS q_unconfirmed, q.sent_bytes AS q_sent, p.synced_bytes AS p_synced, p.expires_at AS p_expires
    FROM history h LEFT JOIN queue q ON q.device_id=h.device_id AND q.id=h.id LEFT JOIN parts p ON p.device_id=h.device_id AND p.id=h.id
    """
    public func rows(search: String? = nil) async throws -> [TransferRecord] {
        let rows = try await store.query(Self.select + " WHERE ? IS NULL OR instr(lower(COALESCE(h.text,'') || COALESCE(h.path,'') || COALESCE(h.target_name,'')),lower(?))>0 ORDER BY h.timestamp DESC,h.id", bindings: [search.sql, search.sql])
        return try rows.map(Self.record)
    }
    public func record(deviceID: String, id: String) async throws -> TransferRecord? {
        try await store.query(Self.select + " WHERE h.device_id=? AND h.id=?", bindings: [.text(deviceID), .text(id)]).first.map(Self.record)
    }
    public func rows(sendID: String) async throws -> [TransferRecord] {
        try await store.query(Self.select + " WHERE h.send_id=? ORDER BY h.device_id,h.id", bindings: [.text(sendID)]).map(Self.record)
    }
    /// One page, newest first. `limit` is at most 500.
    public func page(_ query: TransferQuery) async throws -> TransferPage {
        var clauses: [String] = [], bindings: [SQLValue] = []
        if let device = query.deviceID { clauses.append("h.device_id=?"); bindings.append(.text(device)) }
        if let direction = query.direction { clauses.append("h.direction=?"); bindings.append(.text(direction)) }
        if let search = query.search {
            clauses.append("instr(lower(COALESCE(h.text,'') || COALESCE(h.path,'') || COALESCE(h.target_name,'')),lower(?))>0"); bindings.append(.text(search))
        }
        if let before = query.before { clauses.append("h.timestamp<?"); bindings.append(.real(before.timeIntervalSince1970)) }
        var statuses: [String] = []
        if query.groups.contains("waiting") { statuses += ["waiting"] }
        if query.groups.contains("active") { statuses += ["sending", "receiving", "interrupted"] }
        if query.groups.contains("done") { statuses += ["ok", "failed", "unconfirmed", "cancelled", "expired"] }
        if !statuses.isEmpty {
            clauses.append("h.status IN (" + statuses.map { _ in "?" }.joined(separator: ",") + ")"); bindings += statuses.map(SQLValue.text)
        }
        let limit = max(1, min(query.limit, 500))
        let sql = Self.select + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")) + " ORDER BY h.timestamp DESC,h.id LIMIT ?"
        let rows = try await store.query(sql, bindings: bindings + [.integer(Int64(limit + 1))]).map(Self.record)
        let items = Array(rows.prefix(limit)).map(\.listed)
        let next = rows.count > limit ? items.last.map { TransferCursor.format($0.timestamp) } : nil
        return TransferPage(items: items, nextBefore: next)
    }
    private static func record(_ row: SQLRow) throws -> TransferRecord {
        func s(_ key: String) -> String? { if case .text(let v) = row[key] { return v }; return nil }
        func i(_ key: String) -> Int64? { if case .integer(let v) = row[key] { return v }; return nil }
        func d(_ key: String) -> Date? {
            switch row[key] { case .real(let v): Date(timeIntervalSince1970: v); case .integer(let v): Date(timeIntervalSince1970: Double(v)); default: nil }
        }
        guard let id = s("id"), let device = s("device_id"), let direction = s("direction"), let kind = s("kind"), let status = s("status"), let size = i("size") else { throw AgentError.storage }
        var r = TransferRecord(id: id, deviceID: device, direction: direction, kind: kind, size: size, status: status)
        if let t = d("timestamp") { r.timestamp = t }
        r.text = s("text"); r.path = s("path"); r.sha256 = s("sha256"); r.targetName = s("target_name")
        if let keep = i("keep") { r.keep = keep != 0 }
        r.sendID = s("send_id"); r.mime = s("mime"); r.intent = s("intent") ?? "deliver"; r.clipKind = s("clip_kind")
        r.recoveryID = s("recovery_id"); r.error = s("error"); r.entries = i("entries").map(Int.init); r.updatedAt = d("updated_at")
        if let skipped = s("skipped") { r.skipped = try? JSONDecoder().decode([SkippedEntry].self, from: Data(skipped.utf8)) }
        if let queued = d("q_queued_at"), let next = d("q_next"), let expires = d("q_expires") {
            r.waiting = WaitingInfo(queuedAt: queued, attempts: Int(i("q_attempts") ?? 0), nextAttemptAt: next, expiresAt: expires, unconfirmed: (i("q_unconfirmed") ?? 0) != 0)
            if let sent = i("q_sent"), sent > 0 { r.progress = TransferProgress(doneBytes: sent, totalBytes: size) }
        }
        if let synced = i("p_synced") {
            r.progress = TransferProgress(doneBytes: synced, totalBytes: size)
            if status == "interrupted" { r.partExpiresAt = d("p_expires") }
        }
        return r
    }
}

/// The `before` cursor of `transfers.list`: an ISO-8601 time with fractional seconds.
public enum TransferCursor {
    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    public static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

extension Optional where Wrapped == String {
    var sql: SQLValue { map(SQLValue.text) ?? .null }
}
