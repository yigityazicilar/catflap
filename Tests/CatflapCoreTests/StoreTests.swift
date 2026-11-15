import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

func storeTestPaths() throws -> AgentPaths {
    try AgentPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("cf-" + UUID().uuidString.prefix(8)))
}

func removeStoreTestPaths(_ paths: AgentPaths) {
    try? IdentityStore(paths: paths).erase()
    try? FileManager.default.removeItem(at: paths.directory)
}

struct StoreTests {
    @Test func testSchemaV1Migrates() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let store = try Store(paths: paths)
        #expect(try await store.schemaVersion() == 2)
        let old = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        for (id, paired, sent) in [("first", old, old as Date?), ("second", newer, nil), ("third", old, newer as Date?)] {
            try await store.saveDevice(.init(id: id, name: id, clientPublicKey: "test", address: "test", pairSecret: Data([1]), build: "test", pairedAt: paired, lastSentAt: sent))
        }
        try await store.saveHistory(.init(id: "row", deviceID: "first", direction: "sent", kind: "text", size: 5, status: "ok", text: "hello"))
        try await store.setSetting("example", value: "saved")
        let reopened = try Store(paths: paths)
        #expect(try await reopened.schemaVersion() == 2)
        #expect(try await reopened.devices().map(\.id) == ["third", "first", "second"])
        #expect(try await reopened.history(search: "hello").count == 1)
        #expect(try await reopened.setting("example") == "saved")
    }
    @Test func testSchemaV1MigratesToV2KeepingEveryRow() async throws {
        // A v1 file, made from v1's own DDL in a database the current store attaches.
        let scratch = try storeTestPaths(); defer { removeStoreTestPaths(scratch) }
        let maker = try Store(paths: scratch)
        let v1 = scratch.directory.appendingPathComponent("v1.sqlite")
        do { try await maker.execute("ATTACH DATABASE '\(v1.path)' AS old") } catch { Issue.record("attach failed"); throw error }
        for statement in [
            "CREATE TABLE old.devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, client_public_key TEXT NOT NULL, address TEXT NOT NULL, pair_secret BLOB NOT NULL, build TEXT NOT NULL, paired_at REAL NOT NULL, last_sent_at REAL)",
            "CREATE TABLE old.history (id TEXT NOT NULL, device_id TEXT NOT NULL, timestamp REAL NOT NULL, direction TEXT NOT NULL, kind TEXT NOT NULL, size INTEGER NOT NULL, status TEXT NOT NULL, text TEXT, path TEXT, sha256 TEXT, keep INTEGER NOT NULL DEFAULT 1, target_name TEXT, PRIMARY KEY(device_id, id))",
            "CREATE INDEX old.history_time ON history(timestamp DESC)",
            "CREATE TABLE old.clipboard (id TEXT PRIMARY KEY, timestamp REAL NOT NULL, kind TEXT NOT NULL, content BLOB, mime TEXT, kept INTEGER NOT NULL DEFAULT 0)",
            "CREATE TABLE old.settings (key TEXT PRIMARY KEY, value BLOB NOT NULL)",
            "INSERT INTO old.devices VALUES('first','first','k','a','AQ==','test',100,100), ('second','second','k','a','AQ==','test',200,NULL)",
            "INSERT INTO old.history(id,device_id,timestamp,direction,kind,size,status,text) VALUES('sent','first',150,'sent','text',5,'ok','hello')",
            "INSERT INTO old.history(id,device_id,timestamp,direction,kind,size,status) VALUES('cut','second',160,'received','file',9,'receiving')",
            "INSERT INTO old.clipboard VALUES('clip',170,'text',x'6869',NULL,1)",
            "INSERT INTO old.settings VALUES('example','saved')",
            "PRAGMA old.user_version=1",
        ] {
            do { try await maker.execute(statement) } catch { Issue.record("v1 fixture step failed: \(statement.prefix(40))"); throw error }
        }
        do { try await maker.execute("DETACH DATABASE old") } catch { Issue.record("detach failed"); throw error }
        let paths = try storeTestPaths(); defer { removeStoreTestPaths(paths) }
        try? FileManager.default.removeItem(at: paths.database)
        try FileManager.default.copyItem(at: v1, to: paths.database)
        let store: Store
        do { store = try Store(paths: paths) } catch { Issue.record("open failed"); throw error }
        #expect(try await store.schemaVersion() == 2)
        #expect(try await store.devices().map(\.id) == ["first", "second"])
        #expect(try await store.setting("example") == "saved")
        let sent = try #require(try await store.query("SELECT intent, text, updated_at FROM history WHERE id='sent'").first)
        #expect(sent["intent"] == .text("deliver") && sent["text"] == .text("hello") && sent["updated_at"] == .real(150))
        #expect(try await store.query("SELECT 1 FROM clipboard").count == 1)
        for table in ["queue", "parts", "device_state"] { #expect(try await store.query("SELECT COUNT(*) AS n FROM \(table)").first?["n"] == .integer(0)) }
        // A receive the old build left half done is reconciled by the old rule: failed.
        let service = TransferService(store: store, inbox: try TransferInbox(directory: paths.directory.appendingPathComponent("inbox")))
        do { try await service.reconcile() } catch { Issue.record("reconcile failed"); throw error }
        #expect(try await service.history.record(deviceID: "second", id: "cut")?.status == "failed")
    }
    @Test func testDataFilesAreOwnerOnly() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let store = try Store(paths: paths)
        _ = try IdentityStore(paths: paths).loadOrCreate()
        try await store.setSetting("test", value: "value")
        let files = try FileManager.default.contentsOfDirectory(at: paths.directory, includingPropertiesForKeys: nil)
        #expect(files.map { $0.resolvingSymlinksInPath() }.contains(paths.database.resolvingSymlinksInPath()))
        for file in files + [paths.directory] {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            let mode = try #require(attrs[.posixPermissions] as? NSNumber).intValue
            #expect(mode & 0o077 == 0)
            #expect((attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        }
        // Existing broad permissions are tightened; symlinked data files are rejected.
        #expect(chmod(paths.database.path, 0o644) == 0)
        try AgentPaths.secureFile(paths.database)
        let link = paths.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: paths.database)
        #expect(throws: AgentError.unsafePath) { try AgentPaths.secureFile(link) }
    }
}
