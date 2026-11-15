import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// `catflap audit` scans the inbox the running receiver writes to, and the folder chosen for
/// the next start as well, each under its own label; and it refuses to call a scan it could
/// not finish clean.
@Suite(.timeLimit(.minutes(10))) struct AuditInboxE2E {
    @Test func testLiveAndPendingInboxesAreBothScannedBeforeAndAfterRestart() async throws {
        let agent = try AgentHarness(); defer { agent.stop() }
        let outside = agent.dataDirectory.deletingLastPathComponent()
        let old = outside.appendingPathComponent("audit-old-inbox-" + UUID().uuidString)
        let new = outside.appendingPathComponent("audit-new-inbox-" + UUID().uuidString)
        let extras = outside.appendingPathComponent("audit-extras-" + UUID().uuidString)
        defer { for url in [old, new, extras] { try? FileManager.default.removeItem(at: url) } }
        for folder in [old, new] { _ = try AgentPaths(directory: folder) }
        let store = try Store(paths: AgentPaths(directory: agent.dataDirectory))
        try await store.setSetting("inbox", value: old.path)
        try await onThread { try agent.start() }
        // Line 1 is only in the old inbox, line 2 only in the new one.
        try AgentPaths.writePrivate(Data("old inbox audit sentinel".utf8), to: old.appendingPathComponent("received-old.txt"))
        try AgentPaths.writePrivate(Data("new inbox audit sentinel".utf8), to: new.appendingPathComponent("received-new.txt"))
        try AgentPaths.writePrivate(Data("old inbox audit sentinel\nnew inbox audit sentinel\n".utf8), to: extras)
        // Chosen while running: it applies at once, so the old inbox, which holds no part of a receive, is no longer scanned.
        try await store.setSetting("inbox", value: new.path)

        func audit() async throws -> CommandResult { try await onThread { try agent.command(["audit", "--also", extras.path], timeout: 120) } }
        func lines(_ findings: [AuditFinding]) -> [String] { findings.compactMap { finding in finding.line.map { "\($0) \(finding.file)" } }.sorted() }

        let before = try await audit()
        #expect(before.code == 1)
        #expect(lines(try before.decode([AuditFinding].self)) == ["2 inbox/received-new.txt"])
        try await onThread { try agent.restart() }
        let after = try await audit()
        #expect(after.code == 1)
        #expect(lines(try after.decode([AuditFinding].self)) == ["2 inbox/received-new.txt"])

        // An unreadable folder in the live inbox: an error, never a clean or partial result.
        let hidden = new.appendingPathComponent("hidden")
        _ = try AgentPaths(directory: hidden)
        #expect(chmod(hidden.path, 0) == 0)
        defer { _ = chmod(hidden.path, 0o700) }
        try #require((try? FileManager.default.contentsOfDirectory(atPath: hidden.path)) == nil, "this process can read a mode-000 folder")
        let incomplete = try await audit()
        #expect(incomplete.code == 1)
        let object = try #require(jsonObject(incomplete.output), "not one JSON error: \(incomplete.output.count) bytes")
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? String)
        #expect(error.localizedCaseInsensitiveContains("incomplete"))
        #expect(!String(decoding: incomplete.output, as: UTF8.self).contains("sentinel"))
        #expect(!String(decoding: incomplete.output, as: UTF8.self).contains(new.lastPathComponent))
        _ = chmod(hidden.path, 0o700)
        #expect(try await audit().code == 1)
    }
}
