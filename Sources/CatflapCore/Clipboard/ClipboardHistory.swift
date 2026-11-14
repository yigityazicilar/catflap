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
    public let content: Data
    public let mime: String?
    public let kept: Bool
    public var text: String? { kind == .image ? nil : String(data: content, encoding: .utf8) }
    public var size: Int { content.count }
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
    public var errorDescription: String? { rawValue }
}

public actor ClipboardHistory {
    public static let imageLimit = 20_000_000
    public static let textLimit = 4 * 1024 * 1024
    public static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    public let store: Store
    private var paused: Bool
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
        if SecretFilter.isMarked(offeredTypes: offeredTypes, passwordManagerFrontmost: passwordManagerFrontmost) {
            return .init("marked")
        }
        if paused { return .init("paused") }
        if let declaredSize, declaredSize < 0 || declaredSize > Self.limit(kind) { return .init("oversize") }
        let content = try await read()
        // A newer copy or pause must not resurrect this copy after an asynchronous read.
        guard ticket == generation, !paused else { return .init("superseded") }
        guard content.data.count <= Self.limit(content.kind) else { return .init("oversize") }
        try Self.validate(content)
        if content.kind != .image, SecretFilter.rejects(String(decoding: content.data, as: UTF8.self)) {
            let id = UUID().uuidString
            pending = (id, content)
            return .init("filtered", id: id, canKeep: true, message: "Skipped, looks like a secret")
        }
        let id = try await save(content, kept: false, now: now)
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
        let saved = try await save(candidate.content, kept: true, now: now)
        return .init("stored", id: saved)
    }
    public func setPaused(_ value: Bool) async throws {
        try await store.setSetting("clipboard_paused", value: value ? "true" : "false")
        paused = value; generation &+= 1; pending = nil
    }
    public func isPaused() -> Bool { paused }
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
    private func save(_ content: ClipboardContent, kept: Bool, now: Date) async throws -> String {
        try await store.transaction { tx in
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
        return try rows.map { row in
            guard case .text(let id) = row["id"], case .real(let time) = row["timestamp"],
                  case .text(let kind) = row["kind"], let parsed = ClipboardKind(rawValue: kind),
                  case .blob(let data) = row["content"], case .integer(let kept) = row["kept"] else { throw AgentError.storage }
            let mime: String?
            if case .text(let value) = row["mime"] { mime = value } else { mime = nil }
            return ClipboardItem(id: id, timestamp: Date(timeIntervalSince1970: time), kind: parsed, content: data, mime: mime, kept: kept != 0)
        }.filter { item in search.map { item.text?.localizedCaseInsensitiveContains($0) == true } ?? true }
    }
    public func item(id: String) async throws -> ClipboardItem {
        guard let item = try await items().first(where: { $0.id == id }) else { throw ClipboardFailure.missing }
        return item
    }
}
