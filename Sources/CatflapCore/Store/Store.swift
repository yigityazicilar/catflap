import CSQLite
import Foundation

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { sqlite3_close(pointer) }
}

public actor Store {
    private let connection: SQLiteConnection
    private var db: OpaquePointer { connection.pointer }
    public let paths: AgentPaths
    public init(paths: AgentPaths) throws {
        self.paths = paths
        try AgentPaths.secureFile(paths.database)
        for suffix in ["-wal", "-shm", "-journal"] {
            let url = URL(fileURLWithPath: paths.database.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) { try AgentPaths.secureFile(url) }
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(paths.database.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            throw AgentError.storage
        }
        do {
            sqlite3_busy_timeout(connection, 5000)
            try Self.execute(connection, "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;")
            let version = try Self.version(connection)
            guard version <= 1 else { throw AgentError.storage }
            if version == 0 {
                try Self.execute(connection, """
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS devices (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, client_public_key TEXT NOT NULL,
                    address TEXT NOT NULL, pair_secret BLOB NOT NULL, build TEXT NOT NULL,
                    paired_at REAL NOT NULL, last_sent_at REAL
                );
                CREATE TABLE IF NOT EXISTS history (
                    id TEXT NOT NULL, device_id TEXT NOT NULL, timestamp REAL NOT NULL,
                    direction TEXT NOT NULL, kind TEXT NOT NULL, size INTEGER NOT NULL,
                    status TEXT NOT NULL, text TEXT, path TEXT, sha256 TEXT,
                    keep INTEGER NOT NULL DEFAULT 1, target_name TEXT,
                    PRIMARY KEY(device_id, id)
                );
                CREATE INDEX IF NOT EXISTS history_time ON history(timestamp DESC);
                CREATE TABLE IF NOT EXISTS clipboard (
                    id TEXT PRIMARY KEY, timestamp REAL NOT NULL, kind TEXT NOT NULL,
                    content BLOB, mime TEXT, kept INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value BLOB NOT NULL);
                PRAGMA user_version=1;
                COMMIT;
                """)
            }
        } catch {
            sqlite3_close(connection)
            throw AgentError.storage
        }
        self.connection = SQLiteConnection(connection)
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AgentError.storage }
    }
    private static func version(_ db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { throw AgentError.storage }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw AgentError.storage }
        return Int(sqlite3_column_int(statement, 0))
    }
    public func schemaVersion() throws -> Int { try Self.version(db) }

    public func execute(_ sql: String, bindings: [SQLValue] = []) throws {
        let access = SQLTransaction(db)
        defer { access.invalidate() }
        try access.execute(sql, bindings: bindings)
    }
    public func query(_ sql: String, bindings: [SQLValue] = []) throws -> [SQLRow] {
        let access = SQLTransaction(db)
        defer { access.invalidate() }
        return try access.query(sql, bindings: bindings)
    }
    /// The synchronous body cannot suspend, so no other store operation can interleave.
    public func transaction<T: Sendable>(_ body: @Sendable (SQLTransaction) throws -> T) throws -> T {
        try Self.execute(db, "BEGIN IMMEDIATE")
        let access = SQLTransaction(db)
        defer { access.invalidate() }
        do {
            let result = try body(access)
            try Self.execute(db, "COMMIT")
            return result
        } catch {
            try Self.execute(db, "ROLLBACK")
            throw error
        }
    }

    // Bound values keep arbitrary device names and history text out of SQL syntax.
    private func statement(_ sql: String, _ values: [String?] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw AgentError.storage }
        for (index, value) in values.enumerated() {
            let code: Int32
            if let value {
                code = value.withCString { sqlite3_bind_text(result, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            } else { code = sqlite3_bind_null(result, Int32(index + 1)) }
            guard code == SQLITE_OK else { sqlite3_finalize(result); throw AgentError.storage }
        }
        return result
    }
    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }
    private func update(_ sql: String, _ values: [String?]) throws {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw AgentError.storage }
    }
    public func saveDevice(_ device: DeviceRecord) throws {
        try update("""
        INSERT INTO devices VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
        name=excluded.name, client_public_key=excluded.client_public_key, address=excluded.address,
        pair_secret=excluded.pair_secret, build=excluded.build, paired_at=excluded.paired_at, last_sent_at=excluded.last_sent_at
        """, [device.id, device.name, device.clientPublicKey, device.address, device.pairSecret.base64EncodedString(),
              device.build, String(device.pairedAt.timeIntervalSince1970), device.lastSentAt.map { String($0.timeIntervalSince1970) }])
    }
    public func removeDevice(id: String) throws { try update("DELETE FROM devices WHERE id=?", [id]) }
    public func recordSend(to id: String, at date: Date = Date()) throws {
        try update("UPDATE devices SET last_sent_at=? WHERE id=?", [String(date.timeIntervalSince1970), id])
    }
    public func devices() throws -> [DeviceRecord] {
        let s = try statement("SELECT * FROM devices ORDER BY last_sent_at IS NULL, last_sent_at DESC, paired_at DESC, id ASC")
        defer { sqlite3_finalize(s) }
        var rows: [DeviceRecord] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW, let id = text(s, 0), let name = text(s, 1), let key = text(s, 2),
                  let address = text(s, 3), let encoded = text(s, 4), let secret = Data(base64Encoded: encoded), let build = text(s, 5)
            else { throw AgentError.storage }
            rows.append(.init(id: id, name: name, clientPublicKey: key, address: address, pairSecret: secret, build: build,
                              pairedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 6)),
                              lastSentAt: sqlite3_column_type(s, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 7))))
        }
    }
    public func saveHistory(_ row: HistoryRecord) throws {
        try update("""
        INSERT INTO history (id,device_id,timestamp,direction,kind,size,status,text,path) VALUES (?,?,?,?,?,?,?,?,?)
        ON CONFLICT(device_id,id) DO UPDATE SET status=excluded.status,text=excluded.text,path=excluded.path
        """, [row.id, row.deviceID, String(row.timestamp.timeIntervalSince1970), row.direction, row.kind,
              String(row.size), row.status, row.text, row.path])
    }
    public func history(search: String? = nil) throws -> [HistoryRecord] {
        let s = try statement("SELECT id,device_id,timestamp,direction,kind,size,status,text,path FROM history WHERE ? IS NULL OR instr(COALESCE(text,'') || COALESCE(path,''),?)>0 ORDER BY timestamp DESC,id ASC", [search, search])
        defer { sqlite3_finalize(s) }
        var rows: [HistoryRecord] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW, let id = text(s,0), let device = text(s,1), let direction = text(s,3),
                  let kind = text(s,4), let status = text(s,6) else { throw AgentError.storage }
            rows.append(.init(id: id, deviceID: device, timestamp: Date(timeIntervalSince1970: sqlite3_column_double(s,2)),
                              direction: direction, kind: kind, size: sqlite3_column_int64(s,5), status: status, text: text(s,7), path: text(s,8)))
        }
    }
    public func setSetting(_ key: String, value: String) throws {
        try update("INSERT INTO settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key,value])
    }
    public func setting(_ key: String) throws -> String? {
        let s = try statement("SELECT value FROM settings WHERE key=?", [key]); defer { sqlite3_finalize(s) }
        let code = sqlite3_step(s)
        guard code == SQLITE_ROW || code == SQLITE_DONE else { throw AgentError.storage }
        return code == SQLITE_ROW ? text(s,0) : nil
    }
}
