import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// `catflap audit` covers what transfers leave on disk: parts of interrupted receives (also in
/// an inbox that is no longer the current one), staged folders, kept image copies and the
/// listings of waiting folder sends.
@Suite struct AuditTransferTests {
    static let needle = "transfer audit sentinel"
    static let rid = String(repeating: "ab", count: 16)

    static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + "-" + UUID().uuidString)
        _ = try AgentPaths(directory: url)
        return url
    }

    @Test func testAuditCoversPartFilesAndOutboxCopies() throws {
        let data = try Self.folder("audit-data"), inbox = try Self.folder("audit-inbox"), old = try Self.folder("audit-old-inbox")
        defer { for url in [data, inbox, old] { try? FileManager.default.removeItem(at: url) } }
        let secret = Data(("before " + Self.needle + " after").utf8)
        for sub in ["sent-images", "outbox"] { _ = try AgentPaths(directory: data.appendingPathComponent(sub)) }
        try AgentPaths.writePrivate(secret, to: data.appendingPathComponent("sent-images/copy.png"))
        try AgentPaths.writePrivate(secret, to: data.appendingPathComponent("outbox/send.manifest"))
        try AgentPaths.writePrivate(secret, to: old.appendingPathComponent(".catflap-\(Self.rid).part"))
        let staged = old.appendingPathComponent(".catflap-\(Self.rid).staging/inner")
        _ = try AgentPaths(directory: staged)
        try AgentPaths.writePrivate(secret, to: staged.appendingPathComponent("file.txt"))
        let scanner = DiskAudit(directory: data, inbox: inbox, extraRoots: [(old, "part-inbox-1")])
        let findings = try scanner.scan(needles: [.init(bytes: Data(Self.needle.utf8), kind: "extra", line: 1)])
        let files = Set(findings.map(\.file))
        #expect(files.contains("data/sent-images/copy.png"), "\(files)")
        #expect(files.contains("data/outbox/send.manifest"), "\(files)")
        #expect(files.contains("part-inbox-1/.catflap-\(Self.rid).part"), "\(files)")
        #expect(files.contains("part-inbox-1/.catflap-\(Self.rid).staging/inner/file.txt"), "\(files)")
    }

    @Test func testAuditFailsIncompleteWhenAPartFolderIsUnreadable() throws {
        let data = try Self.folder("audit-data"), inbox = try Self.folder("audit-inbox"), old = try Self.folder("audit-old-inbox")
        defer { _ = chmod(old.path, 0o700); for url in [data, inbox, old] { try? FileManager.default.removeItem(at: url) } }
        try AgentPaths.writePrivate(Data(Self.needle.utf8), to: old.appendingPathComponent(".catflap-\(Self.rid).part"))
        #expect(chmod(old.path, 0) == 0)
        try #require((try? FileManager.default.contentsOfDirectory(atPath: old.path)) == nil, "this process can still list a mode-000 folder")
        let scanner = DiskAudit(directory: data, inbox: inbox, extraRoots: [(old, "part-inbox-1")])
        #expect(throws: DiskAuditError.incomplete) {
            _ = try scanner.scan(needles: [.init(bytes: Data(Self.needle.utf8), kind: "extra", line: 1)])
        }
    }

    /// The audit asks the transfer service where parts are, so an inbox changed after a
    /// receive was cut off is still scanned.
    @Test func testPartDirectoriesNameTheInboxAReceiveStartedIn() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        var input = try offerFrame(id: "cut", name: "cut.bin", size: 100, sha256: transferHash(Data(count: 100)))
        input.append(Data(count: 30))
        await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(input)))
        let elsewhere = f.directory.appendingPathComponent("new-inbox")
        try await f.store.setSetting("inbox", value: elsewhere.path)
        let folders = try await f.service.partDirectories().map { $0.resolvingSymlinksInPath().path }
        #expect(folders == [f.inbox.directory.resolvingSymlinksInPath().path])
    }
}
