import Foundation

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
    public var canRetry: Bool { direction == "sent" && ["failed", "unconfirmed"].contains(status) }
    enum CodingKeys: String, CodingKey {
        case id, timestamp, direction, kind, size, status, text, path, sha256, keep, error
        case deviceID = "device_id", targetName = "target_name", canRetry = "can_retry"
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
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(deviceID, forKey: .deviceID); try c.encode(timestamp, forKey: .timestamp)
        try c.encode(direction, forKey: .direction); try c.encode(kind, forKey: .kind); try c.encode(size, forKey: .size); try c.encode(status, forKey: .status)
        try c.encodeIfPresent(text, forKey: .text); try c.encodeIfPresent(path, forKey: .path); try c.encodeIfPresent(sha256, forKey: .sha256)
        try c.encode(keep, forKey: .keep); try c.encodeIfPresent(targetName, forKey: .targetName); try c.encodeIfPresent(error, forKey: .error); try c.encode(canRetry, forKey: .canRetry)
    }
}

public struct TransferHistory: Sendable {
    public let store: Store
    public init(store: Store) { self.store = store }
    public func save(_ r: TransferRecord) async throws {
        // A "don't keep" row holds nothing taken from the content once the transfer is over:
        // no text, no path or file name, and no hash, which would let a short text be guessed.
        // While a receive is under way the name and hash stay, for the startup check.
        let underWay = r.status == "sending" || r.status == "receiving"
        let derived = r.keep || underWay
        try await store.execute("""
        INSERT INTO history(id,device_id,timestamp,direction,kind,size,status,text,path,sha256,keep,target_name)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id,id) DO UPDATE SET
        status=excluded.status,text=excluded.text,path=excluded.path,sha256=excluded.sha256,keep=excluded.keep,target_name=excluded.target_name
        """, bindings: [.text(r.id), .text(r.deviceID), .real(r.timestamp.timeIntervalSince1970), .text(r.direction), .text(r.kind), .integer(r.size), .text(r.status), r.keep ? r.text.sql : .null, r.keep ? r.path.sql : .null, derived ? r.sha256.sql : .null, .integer(r.keep ? 1 : 0), derived ? r.targetName.sql : .null])
    }
    public func rows(search: String? = nil) async throws -> [TransferRecord] {
        let rows = try await store.query("SELECT * FROM history WHERE ? IS NULL OR instr(lower(COALESCE(text,'') || COALESCE(path,'') || COALESCE(target_name,'')),lower(?))>0 ORDER BY timestamp DESC,id", bindings: [search.sql, search.sql])
        return try rows.map(Self.record)
    }
    public func record(deviceID: String, id: String) async throws -> TransferRecord? {
        try await store.query("SELECT * FROM history WHERE device_id=? AND id=?", bindings: [.text(deviceID), .text(id)]).first.map(Self.record)
    }
    private static func record(_ row: SQLRow) throws -> TransferRecord {
        func s(_ key: String) -> String? { if case .text(let v) = row[key] { return v }; return nil }
        guard let id = s("id"), let device = s("device_id"), let direction = s("direction"), let kind = s("kind"), let status = s("status"), case .integer(let size) = row["size"] else { throw AgentError.storage }
        var r = TransferRecord(id: id, deviceID: device, direction: direction, kind: kind, size: size, status: status)
        if case .real(let t) = row["timestamp"] { r.timestamp = Date(timeIntervalSince1970: t) }
        r.text = s("text"); r.path = s("path"); r.sha256 = s("sha256"); r.targetName = s("target_name")
        if case .integer(let keep) = row["keep"] { r.keep = keep != 0 }
        return r
    }
}
private extension Optional where Wrapped == String {
    var sql: SQLValue { map(SQLValue.text) ?? .null }
}
