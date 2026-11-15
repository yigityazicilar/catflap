import Foundation

public enum ClipboardKind: String, Codable, Sendable { case text, url, image, files }
public struct ClipboardContent: Sendable {
    public let kind: ClipboardKind
    public let data: Data
    public let mime: String?
    public init(kind: ClipboardKind, data: Data, mime: String? = nil) {
        self.kind = kind; self.data = data; self.mime = mime
    }
    public static func text(_ value: String) -> Self { .init(kind: .text, data: Data(value.utf8), mime: "text/plain") }
}
public struct ClipboardItem: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let kind: ClipboardKind
    /// The whole item, or in a list preview (`truncated`) its first bytes: at most
    /// `ClipboardHistory.previewLimit` of a text, cut between characters, and none of an image.
    public let content: Data
    public let mime: String?
    public let kept: Bool
    /// The whole item's size, also in a preview.
    public let size: Int
    /// True when `content` is not the whole item; `clip.get` returns it whole.
    public let truncated: Bool
    public var text: String? { kind == .image ? nil : String(data: content, encoding: .utf8) }
    enum CodingKeys: String, CodingKey { case id, timestamp, kind, content, mime, kept, size, truncated }
    init(id: String, timestamp: Date, kind: ClipboardKind, content: Data, mime: String?, kept: Bool, size: Int? = nil, truncated: Bool = false) {
        self.id = id; self.timestamp = timestamp; self.kind = kind; self.content = content; self.mime = mime; self.kept = kept
        self.size = size ?? content.count; self.truncated = truncated
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); timestamp = try c.decode(Date.self, forKey: .timestamp)
        kind = try c.decode(ClipboardKind.self, forKey: .kind); content = try c.decode(Data.self, forKey: .content)
        mime = try c.decodeIfPresent(String.self, forKey: .mime); kept = try c.decode(Bool.self, forKey: .kept)
        // An item from before previews existed is whole.
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? content.count
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}
public struct ClipboardIngestResult: Codable, Sendable {
    public let status: String
    public let id: String?
    public let canKeep: Bool
    public let message: String?
    enum CodingKeys: String, CodingKey { case status, id, message; case canKeep = "can_keep" }
    init(_ status: String, id: String? = nil, canKeep: Bool = false, message: String? = nil) {
        self.status = status; self.id = id; self.canKeep = canKeep; self.message = message
    }
}
public enum ClipboardFailure: String, Error, LocalizedError {
    case missing = "Clipboard item not found."
    case noPending = "No filtered item is available to Keep."
    case invalid = "Invalid clipboard content."
    // What `clip send --latest` says when it sends nothing.
    case latestEmpty = "Nothing has been copied since Catflap started."
    case latestReading = "The last copy is still being read. Try again in a moment."
    case latestPaused = "Clipboard history is paused, so there is no recorded copy to send."
    case latestCopiedWhilePaused = "The last copy was made while clipboard history was paused."
    case latestFiltered = "The last copy was skipped because it looks like a secret. Keep it in Catflap to send it."
    case latestMarked = "The last copy came from a password manager and was not recorded."
    case latestOversize = "The last copy was too large to record."
    case latestUnreadable = "The last copy was not something Catflap records."
    case latestDeleted = "The last copy was deleted from clipboard history."
    case latestNoDevice = "No paired device. Pair one first with `catflap pair start`."
    public var errorDescription: String? { rawValue }
}

public actor ClipboardHistory {
    public static let imageLimit = 20_000_000
    public static let textLimit = 4 * 1024 * 1024
    public static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    public let store: Store
    private var paused: Bool
    /// What became of the newest copy this agent has seen, for `clip send --latest`. Nil
    /// until a copy arrives after the agent starts. `reading` while its outcome is not known
    /// yet: its contents are being read, or have not arrived.
    private enum Latest { case stored(String), skipped(ClipboardFailure), reading }
    private var latest: Latest?
    private var generation: UInt64 = 0
    private var pending: (id: String, content: ClipboardContent)?
    public init(store: Store, paused: Bool = false) { self.store = store; self.paused = paused }
    public static func open(store: Store) async throws -> ClipboardHistory {
        let history = ClipboardHistory(store: store, paused: try await store.setting("clipboard_paused") == "true")
        try await history.retain()
        return history
    }
    /// Capture adapters MUST offer all raw types before requesting any bytes. This closure is
    /// never called for a marker, a frontmost password manager, a paused capture or a known oversize.
    /// The adapter also bounds its read to the corresponding limit when the size is unknown.
    public func ingest(offeredTypes: [String], passwordManagerFrontmost: Bool = false,
                       declaredSize: Int? = nil, kind: ClipboardKind = .text, now: Date = Date(),
                       read: @Sendable () async throws -> ClipboardContent) async throws -> ClipboardIngestResult {
        generation &+= 1
        let ticket = generation
        pending = nil
        // From here until its outcome is known, this copy is the newest one.
        latest = .reading
        if SecretFilter.isMarked(offeredTypes: offeredTypes, passwordManagerFrontmost: passwordManagerFrontmost) {
            latest = .skipped(.latestMarked)
            return .init("marked")
        }
        if paused { latest = .skipped(.latestCopiedWhilePaused); return .init("paused") }
        if let declaredSize, declaredSize < 0 || declaredSize > Self.limit(kind) {
            latest = .skipped(.latestOversize)
            return .init("oversize")
        }
        let content: ClipboardContent
        do { content = try await read() }
        catch {
            if ticket == generation { latest = .skipped(.latestUnreadable) }
            throw error
        }
        // A newer copy or pause must not resurrect this copy after an asynchronous read.
        guard ticket == generation, !paused else { return .init("superseded") }
        guard content.data.count <= Self.limit(content.kind) else {
            latest = .skipped(.latestOversize)
            return .init("oversize")
        }
        do { try Self.validate(content) }
        catch { latest = .skipped(.latestUnreadable); throw error }
        if content.kind != .image, SecretFilter.rejects(String(decoding: content.data, as: UTF8.self)) {
            let id = UUID().uuidString
            pending = (id, content)
            latest = .skipped(.latestFiltered)
            return .init("filtered", id: id, canKeep: true, message: "Skipped, looks like a secret")
        }
        let id = try await save(content, kept: false, now: now)
        // Another copy may have arrived while this one was written; its outcome stands.
        guard let id else {
            if ticket == generation { latest = .skipped(.latestCopiedWhilePaused) }
            return .init("paused")
        }
        if ticket == generation { latest = .stored(id) }
        return .init("stored", id: id)
    }
    private static func limit(_ kind: ClipboardKind) -> Int { kind == .image ? imageLimit : textLimit }
    private static func validate(_ content: ClipboardContent) throws {
        guard !content.data.isEmpty else { throw ClipboardFailure.invalid }
        if content.kind == .image {
            guard ["image/png", "image/jpeg"].contains(content.mime) else { throw ClipboardFailure.invalid }
        } else {
            guard let text = String(data: content.data, encoding: .utf8) else { throw ClipboardFailure.invalid }
            if content.kind == .url {
                guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) else { throw ClipboardFailure.invalid }
            }
            if content.kind == .files {
                let paths = text.split(separator: "\n")
                guard !paths.isEmpty, paths.allSatisfy({ URL(string: String($0))?.isFileURL == true }) else { throw ClipboardFailure.invalid }
            }
        }
    }
    public func keep(id: String, now: Date = Date()) async throws -> ClipboardIngestResult {
        guard let candidate = pending, candidate.id == id else { throw ClipboardFailure.noPending }
        pending = nil
        // Only the newest copy can be pending, so a kept copy is the newest one.
        let ticket = generation
        guard let saved = try await save(candidate.content, kept: true, now: now) else { return .init("paused") }
        if ticket == generation { latest = .stored(saved) }
        return .init("stored", id: saved)
    }
    public func setPaused(_ value: Bool) async throws {
        try await store.setSetting("clipboard_paused", value: value ? "true" : "false")
        guard value != paused else { return }
        paused = value; generation &+= 1; pending = nil
        // A copy that was being read when history paused is not recorded.
        if value, case .reading = latest { latest = .skipped(.latestCopiedWhilePaused) }
    }
    /// A capture adapter calls this when it sees a new copy whose contents have not arrived
    /// yet, and then ingests it, or ingests nothing for it, which settles it. Until then
    /// `latestItem` waits for it instead of returning the copy before it, and that copy's
    /// Keep is gone, as for any new copy.
    public func noteChange() {
        generation &+= 1; pending = nil
        latest = paused ? .skipped(.latestCopiedWhilePaused) : .reading
    }
    public func isPaused() -> Bool { paused }
    /// The item `clip send --latest` sends: the newest copy, and only if history recorded it.
    /// A copy that was skipped, made while paused, or deleted since is refused with the reason,
    /// so the send-clipboard shortcut never sends an older item in its place. A copy whose
    /// outcome is not known yet is waited for, up to `wait`. After a start the agent does not
    /// know what the clipboard holds, so until a copy arrives it sends nothing.
    public func latestItem(wait: Duration = .seconds(5)) async throws -> ClipboardItem {
        let deadline = ContinuousClock.now.advanced(by: wait)
        while !paused, case .reading = latest {
            guard ContinuousClock.now < deadline else { throw ClipboardFailure.latestReading }
            try await Task.sleep(for: .milliseconds(10))
        }
        if paused { throw ClipboardFailure.latestPaused }
        switch latest {
        case .reading: throw ClipboardFailure.latestReading
        case .skipped(let reason): throw reason
        case .stored(let id):
            do { return try await item(id: id) }
            catch ClipboardFailure.missing { throw ClipboardFailure.latestDeleted }
        case nil: throw ClipboardFailure.latestEmpty
        }
    }
    public func delete(id: String) async throws {
        try await store.execute("DELETE FROM clipboard WHERE id=?", bindings: [.text(id)])
    }
    public func retain(now: Date = Date()) async throws {
        try await store.transaction { tx in try Self.prune(tx, now: now) }
    }
    private static func prune(_ tx: SQLTransaction, now: Date) throws {
        try tx.execute("DELETE FROM clipboard WHERE timestamp < ?", bindings: [.real(now.timeIntervalSince1970 - lifetime)])
        try tx.execute("DELETE FROM clipboard WHERE id NOT IN (SELECT id FROM clipboard ORDER BY timestamp DESC,rowid DESC LIMIT 500)")
    }
    /// Writes the copy, unless capture is paused by the time this transaction runs; then it
    /// returns nil. The pause is read here, in the same transaction as the write, because
    /// `setPaused` sets its flag only after its own write: a copy that passed the flag check
    /// in `ingest` or `keep` while that write was queued would otherwise be stored after the
    /// pause had returned. Transactions run one at a time, so the write is either before the
    /// pause is written or sees it.
    private func save(_ content: ClipboardContent, kept: Bool, now: Date) async throws -> String? {
        try await store.transaction { tx in
            let paused = try tx.query("SELECT value FROM settings WHERE key='clipboard_paused'")
            if paused.first?["value"] == .text("true") { return nil }
            let duplicate = try tx.query("SELECT id FROM clipboard WHERE kind=? AND content=? AND mime IS ? LIMIT 1",
                bindings: [.text(content.kind.rawValue), .blob(content.data), content.mime.map(SQLValue.text) ?? .null])
            let id: String
            if case .text(let existing) = duplicate.first?["id"] { id = existing }
            else { id = UUID().uuidString }
            try tx.execute("""
                INSERT INTO clipboard(id,timestamp,kind,content,mime,kept) VALUES(?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET timestamp=excluded.timestamp,kept=MAX(clipboard.kept,excluded.kept)
                """, bindings: [.text(id), .real(now.timeIntervalSince1970), .text(content.kind.rawValue), .blob(content.data), content.mime.map(SQLValue.text) ?? .null, .integer(kept ? 1 : 0)])
            try Self.prune(tx, now: now)
            return id
        }
    }
    public func items(search: String? = nil, now: Date = Date()) async throws -> [ClipboardItem] {
        try await retain(now: now)
        let rows = try await store.query("SELECT * FROM clipboard ORDER BY timestamp DESC,rowid DESC")
        return try rows.map(Self.item).filter { item in search.map { item.text?.localizedCaseInsensitiveContains($0) == true } ?? true }
    }
    /// The list `clip.list` sends: every item without an image's body and with at most
    /// `previewLimit` bytes of a text, so a full history fits in one control reply whatever
    /// it holds. No image body is read for it. A search still matches a text's whole content.
    public func previews(search: String? = nil, now: Date = Date()) async throws -> [ClipboardItem] {
        try await retain(now: now)
        // One byte past the limit shows whether, and where, the cut falls inside a character.
        let rows = try await store.query("""
            SELECT id,timestamp,kind,mime,kept,length(content) AS size,
                   CASE WHEN kind='image' THEN NULL ELSE substr(content,1,?) END AS content
            FROM clipboard ORDER BY timestamp DESC,rowid DESC
            """, bindings: [.integer(Int64(Self.previewLimit + 1))])
        var result: [ClipboardItem] = []
        for row in rows {
            guard case .text(let id) = row["id"], case .real(let time) = row["timestamp"],
                  case .text(let kind) = row["kind"], let parsed = ClipboardKind(rawValue: kind),
                  case .integer(let size) = row["size"], case .integer(let kept) = row["kept"] else { throw AgentError.storage }
            let mime: String?
            if case .text(let value) = row["mime"] { mime = value } else { mime = nil }
            var content = Data()
            if case .blob(let head) = row["content"] { content = head }
            var truncated = parsed == .image || Int(size) > content.count
            if content.count > Self.previewLimit {
                // UTF-8 continuation bytes are 10xxxxxx: back up to the start of a character.
                var cut = Self.previewLimit
                while cut > 0 && content[content.startIndex + cut] & 0xC0 == 0x80 { cut -= 1 }
                content = content.prefix(cut)
                truncated = true
            }
            if let search {
                guard parsed != .image else { continue }
                let text: String
                if truncated { text = try await self.text(id: id) ?? "" } else { text = String(decoding: content, as: UTF8.self) }
                guard text.localizedCaseInsensitiveContains(search) else { continue }
            }
            result.append(ClipboardItem(id: id, timestamp: Date(timeIntervalSince1970: time), kind: parsed, content: content,
                                        mime: mime, kept: kept != 0, size: Int(size), truncated: truncated))
        }
        return result
    }
    /// At most this many bytes of a text are in `previews`. The Linux panel searches the list
    /// it gets, so a match further into a long text is found by `clip list --search` only.
    public static let previewLimit = 8 * 1024
    private func text(id: String) async throws -> String? {
        guard case .blob(let data) = try await store.query("SELECT content FROM clipboard WHERE id=?", bindings: [.text(id)]).first?["content"] else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func item(_ row: SQLRow) throws -> ClipboardItem {
        guard case .text(let id) = row["id"], case .real(let time) = row["timestamp"],
              case .text(let kind) = row["kind"], let parsed = ClipboardKind(rawValue: kind),
              case .blob(let data) = row["content"], case .integer(let kept) = row["kept"] else { throw AgentError.storage }
        let mime: String?
        if case .text(let value) = row["mime"] { mime = value } else { mime = nil }
        return ClipboardItem(id: id, timestamp: Date(timeIntervalSince1970: time), kind: parsed, content: data, mime: mime, kept: kept != 0)
    }
    /// One whole item, read on its own.
    public func item(id: String) async throws -> ClipboardItem {
        try await retain()
        guard let row = try await store.query("SELECT * FROM clipboard WHERE id=?", bindings: [.text(id)]).first else { throw ClipboardFailure.missing }
        return try Self.item(row)
    }
}
