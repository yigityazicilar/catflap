import CSQLite
import Foundation
import Testing
@testable import CatflapCore

@Suite struct StoreV3Tests {
    private func fixture(_ paths: AgentPaths, version: Int = 2) throws {
        var db: OpaquePointer?
        guard sqlite3_open(paths.database.path, &db) == SQLITE_OK, let db else { throw AgentError.storage }
        defer { sqlite3_close(db) }
        // The released-to-builders v1 layout and its original additive v2 migration.
        let v1 = """
        CREATE TABLE devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, client_public_key TEXT NOT NULL, address TEXT NOT NULL, pair_secret BLOB NOT NULL, build TEXT NOT NULL, paired_at REAL NOT NULL, last_sent_at REAL);
        CREATE TABLE history (id TEXT NOT NULL, device_id TEXT NOT NULL, timestamp REAL NOT NULL, direction TEXT NOT NULL, kind TEXT NOT NULL, size INTEGER NOT NULL, status TEXT NOT NULL, text TEXT, path TEXT, sha256 TEXT, keep INTEGER NOT NULL DEFAULT 1, target_name TEXT, PRIMARY KEY(device_id,id));
        CREATE INDEX history_time ON history(timestamp DESC);
        CREATE TABLE clipboard (id TEXT PRIMARY KEY, timestamp REAL NOT NULL, kind TEXT NOT NULL, content BLOB, mime TEXT, kept INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE settings (key TEXT PRIMARY KEY, value BLOB NOT NULL);
        PRAGMA user_version=1;
        """
        for sql in [v1, Store.migrationToV2, """
        INSERT INTO history(id,device_id,timestamp,direction,kind,size,status,text,intent) VALUES('row','peer',100,'received','text',4,'ok','note','deliver');
        INSERT INTO clipboard VALUES('clip',100,'text',x'6e6f7465',NULL,1);
        INSERT INTO settings VALUES('clipboard.filter_secrets','false');
        INSERT INTO settings VALUES('clipboard.follow_to','peer');
        INSERT INTO settings VALUES('clipboard.follow_permission.peer','refused');
        INSERT INTO settings VALUES('links.open_policy.peer','always');
        PRAGMA user_version=\(version);
        """] {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AgentError.storage }
        }
    }
    @Test func realV2UpgradesPreservingDataAndSettingsAndReopensIdempotently() async throws {
        let paths = try storeTestPaths(); defer { removeStoreTestPaths(paths) }
        try fixture(paths)
        for _ in 0..<2 {
            let store = try Store(paths: paths)
            #expect(try await store.schemaVersion() == 3)
            #expect(try await store.query("SELECT name FROM sqlite_master WHERE type='table' AND name='clipboard_origins'").count == 1)
            #expect(try await store.history().count == 1)
            #expect(try await store.query("SELECT content FROM clipboard").first?["content"] == .blob(Data("note".utf8)))
            for (key, value) in [("clipboard.filter_secrets", "false"), ("clipboard.follow_to", "peer"), ("clipboard.follow_permission.peer", "refused"), ("links.open_policy.peer", "always")] {
                #expect(try await store.setting(key) == value)
            }
        }
    }
    @Test func freshDatabaseHasOriginTableBeforeAnyHistoryCallAndStatusReportsV3() async throws {
        let paths = try storeTestPaths(); defer { removeStoreTestPaths(paths) }
        let runtime = try AgentRuntime(paths: paths)
        let store = await runtime.store
        #expect(try await store.schemaVersion() == 3)
        #expect(try await store.query("SELECT name FROM sqlite_master WHERE type='table' AND name='clipboard_origins'").count == 1)
        let reply = await runtime.handle(.init("status"))
        let status = try ControlJSON.decoder.decode(AgentStatus.self, from: reply.payload)
        #expect(status.schemaVersion == 3)
    }
    @Test func futureAndCorruptDatabasesAreRefused() throws {
        let future = try storeTestPaths(); defer { removeStoreTestPaths(future) }
        try fixture(future, version: 4)
        #expect(throws: AgentError.storage) { _ = try Store(paths: future) }
        let corrupt = try storeTestPaths(); defer { removeStoreTestPaths(corrupt) }
        try Data("not a database".utf8).write(to: corrupt.database)
        #expect(throws: AgentError.storage) { _ = try Store(paths: corrupt) }
    }
}
