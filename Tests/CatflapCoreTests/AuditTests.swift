import CatflapCore
import Foundation
import Testing

@Suite struct AuditTests {
    private func peer() -> DeviceRecord {
        .init(id: "peer", name: "peer", clientPublicKey: "public-" + UUID().uuidString,
              address: "address-" + UUID().uuidString, pairSecret: Data(UUID().uuidString.utf8), build: "test")
    }
    private func needles(_ device: DeviceRecord) -> [AuditNeedle] {
        [.init(bytes: Data(device.clientPublicKey.utf8), kind: "key"),
         .init(bytes: Data(device.address.utf8), kind: "address"),
         .init(bytes: Data(device.pairSecret.base64EncodedString().utf8), kind: "pair_secret"),
         .init(bytes: device.pairSecret, kind: "pair_secret")]
    }
    @Test func testAuditFindsAPlantedAddressInTheWriteAheadLog() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let device = peer()
        try await f.store.saveDevice(device)
        _ = try await f.store.query("PRAGMA wal_checkpoint(TRUNCATE)")
        try await f.store.saveHistory(.init(id: "planted", deviceID: device.id, direction: "sent", kind: "text", size: 1, status: "ok", text: device.address))
        try await f.store.execute("DELETE FROM history WHERE id=?", bindings: [.text("planted")])
        let scanner = DiskAudit(directory: f.directory, inbox: f.directory.appendingPathComponent("inbox"))
        let findings = try scanner.scan(needles: needles(device), devices: [device])
        let foundInLog = findings.contains { $0.file == "data/store.sqlite-wal" && $0.kind == "address" }
        #expect(foundInLog)
        if !foundInLog {
            // Where the planted value went, and how this SQLite is set up. Never the value.
            var facts: [String] = []
            let names = (try? FileManager.default.contentsOfDirectory(atPath: f.directory.path)) ?? []
            for name in names.sorted() {
                let data = (try? Data(contentsOf: f.directory.appendingPathComponent(name))) ?? Data()
                var count = 0, start = data.startIndex
                while start < data.endIndex, let range = data.range(of: Data(device.address.utf8), in: start..<data.endIndex) {
                    count += 1; start = range.upperBound
                }
                facts.append("\(name) \(data.count) bytes, value \(count)x")
            }
            for statement in ["SELECT sqlite_version()", "PRAGMA journal_mode", "PRAGMA secure_delete",
                              "PRAGMA wal_autocheckpoint", "PRAGMA page_size"] {
                let rows = (try? await f.store.query(statement)) ?? []
                facts.append("\(statement): \(rows.map { $0.values.map { String(describing: $0) }.joined(separator: ",") })")
            }
            facts.append("findings: \(findings.map { "\($0.file) \($0.kind)" })")
            Issue.record(Comment(rawValue: facts.joined(separator: "; ")))
        }
        let output = try ControlJSON.text(findings)
        let redacted = !output.contains(device.address) && !output.contains(device.clientPublicKey)
        #expect(redacted)
    }
    @Test func testPairedDeviceRowAloneIsNotAFindingBeforeCheckpoint() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let device = peer()
        try await f.store.saveDevice(device)
        let scanner = DiskAudit(directory: f.directory, inbox: f.directory.appendingPathComponent("inbox"))
        #expect(try scanner.scan(needles: needles(device), devices: [device]) == [])
        _ = try await f.store.query("PRAGMA wal_checkpoint(TRUNCATE)")
        #expect(try scanner.scan(needles: needles(device), devices: [device]) == [])
    }
    @Test func testAuditStreamsLargeInboxAndReportsOnlyOffsets() throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let inbox = f.directory.appendingPathComponent("inbox")
        _ = try AgentPaths(directory: inbox)
        let file = inbox.appendingPathComponent("large.bin")
        try AgentPaths.secureFile(file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        // Sparse file crosses the large-file threshold, with needles straddling scan windows.
        try handle.truncate(atOffset: 66 * 1024 * 1024)
        let needle = Data("fixture-leak-needle".utf8)
        for offset: UInt64 in [1024 * 1024 - 4, 65 * 1024 * 1024 - 3, 66 * 1024 * 1024 - 18] {
            try handle.seek(toOffset: offset); try handle.write(contentsOf: needle)
        }
        #if os(Linux)
        try AgentPaths.writePrivate(needle, to: f.directory.appendingPathComponent("keys.json"))
        #endif
        let scanner = DiskAudit(directory: f.directory, inbox: inbox)
        let findings = try scanner.scan(needles: [.init(bytes: needle, kind: "extra", line: 7)])
        #expect(findings.count == 3)
        #expect(findings.allSatisfy { $0.line == 7 && $0.kind == "extra" && $0.file.hasSuffix("large.bin") })
        #expect(Set(findings.map(\.offset)) == Set([UInt64(1024 * 1024 - 4), UInt64(65 * 1024 * 1024 - 3), UInt64(66 * 1024 * 1024 - 18)]))
    }
    @Test func testDeviceRunSplitAcrossScanWindowIsExempt() throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let device = peer()
        let file = f.directory.appendingPathComponent("store.sqlite-wal")
        var bytes = Data(repeating: 0, count: 1024 * 1024 - 12)
        bytes += Data((device.clientPublicKey + device.address + device.pairSecret.base64EncodedString()).utf8)
        try AgentPaths.writePrivate(bytes, to: file)
        #expect(try DiskAudit(directory: f.directory, inbox: f.directory.appendingPathComponent("inbox")).scan(needles: needles(device), devices: [device]).isEmpty)
    }
    /// On macOS the temporary folder is reached through a link (/var is /private/var), and the
    /// file enumerator hands back the other spelling: names must stay relative to the folder
    /// (the write-ahead-log test above covers that there). On Linux the enumerator does not
    /// follow a link given as its root at all, so a linked data folder must still be scanned,
    /// with the same names and the paired-device row still recognised.
    @Test func testFolderReachedThroughALinkKeepsNamesAndExemptions() async throws {
        let f = try ClipboardFixture(); defer { f.cleanup() }
        let device = peer()
        try await f.store.saveDevice(device)
        try await f.store.saveHistory(.init(id: "planted", deviceID: device.id, direction: "sent", kind: "text", size: 1, status: "ok", text: device.address))
        let link = f.directory.deletingLastPathComponent().appendingPathComponent("link-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.directory)
        defer { try? FileManager.default.removeItem(at: link) }
        let findings = try DiskAudit(directory: link, inbox: link.appendingPathComponent("inbox")).scan(needles: needles(device), devices: [device])
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { ["data/store.sqlite", "data/store.sqlite-wal"].contains($0.file) }, "names: \(Set(findings.map(\.file)).sorted())")
        // Only the planted history copy is a finding; the device row is its proper home.
        #expect(findings.allSatisfy { $0.kind == "address" })
    }
}
