import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Folders (plan v4 feature 5): a manifest, checked whole before any payload, then the files
/// as one stream into a hidden staging folder that is published only when complete.
@Suite struct FolderTransferTests {
    static let b = LoopbackPair.receiverID

    /// `top/a.txt`, `top/sub/b.bin`, `top/sub/deeper/c.txt`, an empty `top/empty`, and with
    /// `odd` a symlink, a FIFO and an unreadable file.
    static func tree(in directory: URL, odd: Bool = false, big: Int = 2048) throws -> URL {
        let top = directory.appendingPathComponent("top")
        let fm = FileManager.default
        try fm.createDirectory(at: top.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        try fm.createDirectory(at: top.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: top.appendingPathComponent("a.txt"))
        try Data((0..<big).map { UInt8($0 % 253) }).write(to: top.appendingPathComponent("sub/b.bin"))
        try Data((0..<big).map { UInt8($0 % 241) }).write(to: top.appendingPathComponent("sub/deeper/c.txt"))
        if odd {
            try fm.createSymbolicLink(at: top.appendingPathComponent("link"), withDestinationURL: top.appendingPathComponent("a.txt"))
            #expect(mkfifo(top.appendingPathComponent("pipe").path, 0o600) == 0)
            let secret = top.appendingPathComponent("secret.txt")
            try Data("hidden".utf8).write(to: secret)
            #expect(chmod(secret.path, 0) == 0)
        }
        return top
    }
    static func files(under root: URL) -> [String: Data] {
        // Paths relative to the folder, compared with symlinks resolved on both sides: on macOS
        // the temporary folder is reached through /var, a link to /private/var.
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var found: [String: Data] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                found[parts.dropFirst(base.count).joined(separator: "/")] = try? Data(contentsOf: url)
            }
        }
        return found
    }

    @Test func testFolderArrivesWholeWithNestedDirectories() async throws {
        let p = try await LoopbackPair(); defer { p.cleanup() }
        let top = try Self.tree(in: p.sender.directory)
        let id = try await p.senderService.start(deviceID: Self.b, payload: .folder(top)).id
        #expect(try await waitUntil { try await p.row(id)?.status == "ok" })
        #expect(try p.inboxEntries() == ["top"])
        let arrived = p.receiver.inbox.directory.appendingPathComponent("top")
        #expect(Self.files(under: arrived) == Self.files(under: top))
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: arrived.appendingPathComponent("empty").path, isDirectory: &isFolder) && isFolder.boolValue)
        #expect(try posixMode(arrived.appendingPathComponent("sub")) == 0o700)
        #expect(try posixMode(arrived.appendingPathComponent("sub/b.bin")) == 0o600)
        let row = try #require(try await p.received().first)
        #expect(row.kind == "folder" && row.entries == 6)
    }

    @Test func testSymlinksSpecialAndUnreadableEntriesAreSkippedAndListed() async throws {
        let p = try await LoopbackPair(); defer { p.cleanup() }
        let top = try Self.tree(in: p.sender.directory, odd: true)
        defer { chmod(top.appendingPathComponent("secret.txt").path, 0o600) }
        let id = try await p.senderService.start(deviceID: Self.b, payload: .folder(top)).id
        #expect(try await waitUntil { try await p.row(id)?.status == "ok" })
        let skipped = try #require(try await p.row(id)?.skipped)
        #expect(Set(skipped.map { "\($0.path.joined(separator: "/")):\($0.reason)" }) == ["link:symlink", "pipe:special", "secret.txt:unreadable"])
        let arrived = Self.files(under: p.receiver.inbox.directory.appendingPathComponent("top"))
        #expect(Set(arrived.keys) == ["a.txt", "sub/b.bin", "sub/deeper/c.txt"])
    }

    @Test func testFolderIsPublishedOnlyWhenCompleteAndResumesAcrossEntries() async throws {
        let p = try await LoopbackPair(); defer { p.cleanup() }
        let top = try Self.tree(in: p.sender.directory, big: 64 * 1024)
        // The stream is a.txt (5), sub/b.bin (64 KiB), sub/deeper/c.txt (64 KiB), in manifest
        // order: the cut lands inside the third file.
        let total = Int64(5 + 2 * 64 * 1024), cut = Int64(5 + 64 * 1024 + 1000)
        p.connector.failNext(.cutAfterPayload(cut))
        let id = try await p.senderService.start(deviceID: Self.b, payload: .folder(top)).id
        #expect(try await waitUntil { try await p.received().first?.status == "interrupted" })
        // Nothing under its name; what arrived waits hidden.
        #expect(try p.inboxEntries().allSatisfy { $0.hasPrefix(".catflap-") })
        #expect(try await waitUntil { try await p.row(id)?.status == "failed" })
        _ = try await p.senderService.retry(deviceID: Self.b, id: id)
        #expect(try await waitUntil { try await p.row(id)?.status == "ok" })
        #expect(p.connector.links.last?.payloadBytes == total - cut)
        #expect(try p.inboxEntries() == ["top"])
        #expect(Self.files(under: p.receiver.inbox.directory.appendingPathComponent("top")) == Self.files(under: top))
    }

    @Test func testHostileManifestNamesStayInsideTheFolder() throws {
        let digest = String(repeating: "0", count: 64)
        func offer(_ entries: [ManifestEntry]) -> TransferOffer {
            TransferOffer(id: "x", kind: "folder", name: "f", size: entries.reduce(0) { $0 + ($1.size ?? 0) }, mime: "inode/directory", entries: entries.count)
        }
        func file(_ path: [String]) -> ManifestEntry { ManifestEntry(path: path, type: "file", size: 1, sha256: digest) }
        for bad in [[".."], ["."], [""], ["a/b"], ["a\\b"], ["a\u{0}b"]] {
            #expect(throws: (any Error).self, "\(bad)") { try FolderManifest.validate([file(bad)], offer: offer([file(bad)])) }
        }
        // A file under a folder the manifest never listed is refused too.
        #expect(throws: (any Error).self) { try FolderManifest.validate([file(["nowhere", "x"])], offer: offer([file(["nowhere", "x"])])) }
        #expect(throws: FolderLimitError.name) { try FolderManifest.validate([file([String(repeating: "n", count: 181)])], offer: offer([file([String(repeating: "n", count: 181)])])) }
        // Two names Unicode holds equal (NFC and NFD) are one entry listed twice: refused.
        let twins = [file(["caf\u{e9}"]), file(["cafe\u{301}"])]
        #expect(throws: (any Error).self) { try FolderManifest.validate(twins, offer: offer(twins)) }
        // Names that clash on a case-insensitive disk get a number; control characters go.
        // Nothing is overwritten.
        let entries = [file(["README"]), file(["readme"]), file(["bell\u{7}.txt"]), file(["bell.txt"])]
        try FolderManifest.validate(entries, offer: offer(entries))
        let names = FolderManifest.diskPaths(entries).map { $0.joined(separator: "/") }
        #expect(Set(names).count == names.count, "\(names)")
        #expect(Set(names.map { $0.lowercased().precomposedStringWithCanonicalMapping }).count == names.count, "\(names)")
        #expect(names.allSatisfy { !$0.unicodeScalars.contains { $0.value < 0x20 } }, "\(names)")
    }

    @Test func testManifestOverTheLimitsIsRefusedBeforePayload() async throws {
        for limit in ["entries", "depth"] {
            var small = TransferLimits()
            if limit == "entries" { small.folder.entries = 3 } else { small.folder.depth = 1 }
            let p = try await LoopbackPair(receiverLimits: small); defer { p.cleanup() }
            let top = try Self.tree(in: p.sender.directory)
            let id = try await p.senderService.start(deviceID: Self.b, payload: .folder(top)).id
            #expect(try await waitUntil { try await p.row(id)?.status == "failed" }, "\(limit)")
            #expect(try await p.row(id)?.error == TransferFailure.rejected(.folderLimits).errorDescription, "\(limit)")
            #expect(p.connector.links.last?.written.contains("payload") == false, "\(limit)")
            #expect(try p.inboxEntries().isEmpty, "\(limit)")
        }
    }

    @Test func testSenderRefusesAFolderOverItsOwnLimits() async throws {
        var small = TransferLimits(); small.folder.depth = 1
        let p = try await LoopbackPair(limits: small); defer { p.cleanup() }
        let top = try Self.tree(in: p.sender.directory)
        // The folder is listed while the row shows `preparing`; over a limit, it fails with
        // the limit's sentence and nothing is dialled.
        let id = try await p.senderService.start(deviceID: Self.b, payload: .folder(top)).id
        #expect(try await waitUntil { try await p.row(id)?.status == "failed" })
        #expect(try await p.row(id)?.error == FolderLimitError.depth.sentence)
        #expect(p.connector.links.isEmpty)
    }
}
