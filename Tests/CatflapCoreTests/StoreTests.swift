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
        #expect(try await store.schemaVersion() == 1)
        let old = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        for (id, paired, sent) in [("first", old, old as Date?), ("second", newer, nil), ("third", old, newer as Date?)] {
            try await store.saveDevice(.init(id: id, name: id, clientPublicKey: "test", address: "test", pairSecret: Data([1]), build: "test", pairedAt: paired, lastSentAt: sent))
        }
        try await store.saveHistory(.init(id: "row", deviceID: "first", direction: "sent", kind: "text", size: 5, status: "ok", text: "hello"))
        try await store.setSetting("example", value: "saved")
        let reopened = try Store(paths: paths)
        #expect(try await reopened.schemaVersion() == 1)
        #expect(try await reopened.devices().map(\.id) == ["third", "first", "second"])
        #expect(try await reopened.history(search: "hello").count == 1)
        #expect(try await reopened.setting("example") == "saved")
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
