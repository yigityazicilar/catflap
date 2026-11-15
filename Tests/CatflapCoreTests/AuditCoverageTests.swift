import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// What the audit may say when it could not read everything, and what a finding may name.
@Suite struct AuditCoverageTests {
    private static let needle = "audit coverage sentinel"

    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + "-" + UUID().uuidString)
        _ = try AgentPaths(directory: url)
        return url
    }

    /// Runs `body` with `url` at mode 000 and gives the folder back its access afterwards,
    /// whether the body passed or not. The premise is checked first: a process that can still
    /// list the folder (root) would make the test say nothing.
    private func unreadable(_ url: URL, _ body: () throws -> Void) throws {
        #expect(chmod(url.path, 0) == 0)
        defer { _ = chmod(url.path, 0o700) }
        try #require((try? FileManager.default.contentsOfDirectory(atPath: url.path)) == nil,
                     "this process can still list a mode-000 folder, so the test cannot check anything")
        try body()
    }

    /// Whether the scan failed as incomplete, and what it said.
    private func scanFails(_ scanner: DiskAudit) -> (failed: Bool, message: String?) {
        do {
            let findings = try scanner.scan(needles: [.init(bytes: Data(Self.needle.utf8), kind: "extra", line: 1)])
            return (false, "findings: \(findings.count)")
        } catch DiskAuditError.incomplete {
            return (true, DiskAuditError.incomplete.localizedDescription)
        } catch {
            return (false, "another error")
        }
    }

    @Test func testUnreadableNestedFolderMakesTheAuditIncompleteNotClean() throws {
        let data = try folder("audit-data"); defer { try? FileManager.default.removeItem(at: data) }
        let hidden = data.appendingPathComponent("hidden")
        _ = try AgentPaths(directory: hidden)
        try AgentPaths.writePrivate(Data(Self.needle.utf8), to: hidden.appendingPathComponent("value"))
        let scanner = DiskAudit(directory: data, inbox: data.appendingPathComponent("no-inbox"))
        try unreadable(hidden) {
            let result = scanFails(scanner)
            #expect(result.failed, "an unreadable folder must not give a result: \(result.message ?? "")")
            #expect(result.message?.contains(Self.needle) != true)
            #expect(result.message?.contains(hidden.path) != true)
        }
        // With access back, the same scan finds the planted value.
        let findings = try scanner.scan(needles: [.init(bytes: Data(Self.needle.utf8), kind: "extra", line: 1)])
        #expect(findings.map(\.file) == ["data/hidden/value"])
    }

    @Test func testUnreadableRootsMakeTheAuditIncomplete() throws {
        let data = try folder("audit-data"); defer { try? FileManager.default.removeItem(at: data) }
        let inbox = try folder("audit-inbox"); defer { try? FileManager.default.removeItem(at: inbox) }
        try AgentPaths.writePrivate(Data(Self.needle.utf8), to: inbox.appendingPathComponent("received"))
        let scanner = DiskAudit(directory: data, inbox: inbox)
        try unreadable(inbox) {
            let result = scanFails(scanner)
            #expect(result.failed, "an unreadable inbox must not give a result: \(result.message ?? "")")
        }
        try unreadable(data) {
            let result = scanFails(scanner)
            #expect(result.failed, "an unreadable data folder must not give a result: \(result.message ?? "")")
        }
        // An inbox inside a folder this process cannot search is not a missing inbox.
        let parent = try folder("audit-parent"); defer { try? FileManager.default.removeItem(at: parent) }
        let buried = parent.appendingPathComponent("inbox")
        _ = try AgentPaths(directory: buried)
        try unreadable(parent) {
            let result = scanFails(DiskAudit(directory: data, inbox: buried))
            #expect(result.failed, "an inbox that cannot be reached must not give a result: \(result.message ?? "")")
        }
        #expect(try scanner.scan(needles: [.init(bytes: Data(Self.needle.utf8), kind: "extra", line: 1)]).map(\.file) == ["inbox/received"])
    }

    @Test func testMissingOptionalInboxIsStillAComplete() throws {
        let data = try folder("audit-data"); defer { try? FileManager.default.removeItem(at: data) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("audit-missing-" + UUID().uuidString)
        #expect(try DiskAudit(directory: data, inbox: missing).scan(needles: [.init(bytes: Data(Self.needle.utf8), kind: "extra")]) == [])
    }

    /// The redaction marker, pieces of it and short strings: none of them may appear in a
    /// finding's file field, whatever the file is called. A name that cannot be shown without
    /// one is left out.
    @Test func testNoNeedleSurvivesInAFindingsFileName() throws {
        let data = try folder("audit-data"); defer { try? FileManager.default.removeItem(at: data) }
        let needles = ["<redacted>", "redacted", "<", ">", "red", "ted>", "<re", "d", "a", "/", " ", "da"]
        for (index, needle) in needles.enumerated() {
            // A file named with the needle, holding it, so it is a finding.
            let name = "file-\(index)-" + needle.replacingOccurrences(of: "/", with: "_") + ".txt"
            try AgentPaths.writePrivate(Data(("x" + needle + "x").utf8), to: data.appendingPathComponent(name))
        }
        let scanner = DiskAudit(directory: data, inbox: data.appendingPathComponent("no-inbox"))
        let findings = try scanner.scan(needles: needles.enumerated().map { .init(bytes: Data($1.utf8), kind: "extra", line: $0 + 1) })
        #expect(!findings.isEmpty)
        for finding in findings {
            for needle in needles {
                #expect(!finding.file.contains(needle), "needle \(needles.firstIndex(of: needle)! + 1) is in a file field")
            }
            // A name left out is told apart by its index; a shown one needs none.
            #expect((finding.file.isEmpty) == (finding.fileIndex != nil))
        }
        // Each planted file is still told apart from the others.
        let planted = Set(findings.filter { $0.kind == "extra" }.compactMap(\.fileIndex))
        #expect(planted.count >= needles.count)
        // Without a needle in it, a name is shown, with any marker the redaction made.
        let plain = try DiskAudit(directory: data, inbox: data.appendingPathComponent("no-inbox"))
            .scan(needles: [.init(bytes: Data("file-0".utf8), kind: "extra", line: 1), .init(bytes: Data("x<redacted>x".utf8), kind: "extra", line: 2)])
        #expect(plain.contains { $0.file == "data/<redacted>-<redacted>.txt" && $0.fileIndex == nil })
        let output = try ControlJSON.text(findings)
        #expect(!output.contains("redacted"))
    }
}
