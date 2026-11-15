import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

/// A kept clipboard image that was sent can be sent again from its history row, after the
/// outbox is cleaned, its clipboard row is deleted and the agent restarts; a don't-keep one
/// leaves nothing behind. The copy kept for it goes when its rows go.
@Suite(.timeLimit(.minutes(10))) struct SentImageE2E {
    @Test func testKeptSentImageStaysResendableAndGoesWithItsRows() async throws {
        let agents = try PairedAgents(); defer { agents.stop() }
        try await agents.startAndPair()
        let first = agents.first, second = agents.second
        var image = Data([137, 80, 78, 71, 13, 10, 26, 10])
        image.append(Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }))
        let source = first.dataDirectory.deletingLastPathComponent().appendingPathComponent("sent-image-\(UUID().uuidString).png")
        try AgentPaths.writePrivate(image, to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let added = try await onThread { try first.command(["clip", "add", "--kind", "image", "--file", source.path]) }.decode(ClipboardIngestResult.self)
        let imageID = try #require(added.id)
        let sent = try await onThread { try first.command(["clip", "send", imageID], timeout: 120) }.decode(TransferRecord.self)
        #expect(sent.status == "ok" && sent.kind == "file" && sent.keep)
        // The outbox holds nothing once the send is confirmed.
        let outbox = first.dataDirectory.appendingPathComponent("outbox")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []).isEmpty)
        // The clipboard row goes; the history row still names a readable private copy.
        #expect(try await onThread { try first.command(["clip", "delete", imageID]) }.code == 0)
        try await onThread { try first.restart() }
        let rows = try await onThread { try first.command(["history"]) }.decode([TransferRecord].self)
        let row = try #require(rows.first { $0.id == sent.id && $0.direction == "sent" })
        let path = try #require(row.path, "a kept sent image has no path in its history row")
        #expect(FileManager.default.fileExists(atPath: path), "the kept sent image's file is gone")
        #expect(canonical(path).hasPrefix(canonical(first.dataDirectory.path) + "/"), "the kept copy is outside the data folder")
        var info = stat()
        #expect(lstat(path, &info) == 0 && info.st_mode & 0o777 == 0o600, "the kept copy is not private")
        // Send it again from that row, as the panels do.
        let again = try await onThread { try first.command(["send", "--file", path], timeout: 120) }
        #expect(again.code == 0)
        let resent = try again.decode(TransferRecord.self)
        #expect(resent.status == "ok")
        let received = try await onThread { try second.command(["history"]) }.decode([TransferRecord].self)
        for id in [sent.id, resent.id] {
            let arrived = try #require(received.first { $0.id == id && $0.direction == "received" })
            #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(arrived.path))) == image)
        }

        // Don't keep: no path, no kept copy, and the outbox is emptied after delivery.
        let kept = try FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        var other = image; other.append(1)
        try AgentPaths.writePrivate(other, to: source)
        let secondID = try #require(try await onThread { try first.command(["clip", "add", "--kind", "image", "--file", source.path]) }.decode(ClipboardIngestResult.self).id)
        let unkept = try await onThread { try first.command(["clip", "send", secondID, "--dont-keep"], timeout: 120) }.decode(TransferRecord.self)
        #expect(unkept.status == "ok" && !unkept.keep && unkept.path == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) == kept)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []).isEmpty)

        // When the rows that name the copy are deleted, as the panels delete them, it goes.
        let store = try Store(paths: AgentPaths(directory: first.dataDirectory))
        for id in [sent.id, resent.id] {
            try await store.execute("DELETE FROM history WHERE direction='sent' AND id=?", bindings: [.text(id)])
        }
        #expect(try await onThread { try first.command(["clip", "list"]) }.code == 0)
        #expect(!FileManager.default.fileExists(atPath: path), "the kept copy outlived its history rows")
        try await onThread { try first.restart() }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
