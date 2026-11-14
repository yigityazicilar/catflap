import CatflapCore
import Foundation
import Testing

private func clipOffPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}
private final class ClipAgents: @unchecked Sendable {
    let first: AgentHarness
    let second: AgentHarness
    init() throws { first = try AgentHarness(); second = try AgentHarness() }
    func stop() { first.stop(); second.stop() }
}
@Suite(.timeLimit(.minutes(5))) struct ClipE2E {
    @Test func testAddedItemIsSentAndFoundInPeerHistory() async throws {
        let agents = try ClipAgents(); defer { agents.stop() }
        for agent in [agents.first, agents.second] {
            let store = try Store(paths: AgentPaths(directory: agent.dataDirectory))
            try await store.setSetting("inbox", value: agent.dataDirectory.appendingPathComponent("inbox").path)
        }
        try await clipOffPool { try agents.first.start(); try agents.second.start() }
        var pairing = try await clipOffPool { try agents.first.command(["pair", "start"]) }.decode(PairingStatus.self)
        let startDeadline = ContinuousClock.now + .seconds(60)
        while pairing.state == .starting && ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(200))
            pairing = try await clipOffPool { try agents.first.command(["pair", "status"]) }.decode(PairingStatus.self)
        }
        let code = try #require(pairing.code)
        #expect(try await clipOffPool { try agents.second.command(["pair", "join", code]) }.code == 0)
        for first in [true, false] {
            let deadline = ContinuousClock.now + .seconds(60)
            var confirmed = false
            while ContinuousClock.now < deadline {
                let state = try await clipOffPool { try (first ? agents.first : agents.second).command(["pair", "status"]) }.decode(PairingStatus.self)
                if state.state == .confirm { confirmed = true; break }
                try await Task.sleep(for: .milliseconds(200))
            }
            try #require(confirmed)
            #expect(try await clipOffPool { try (first ? agents.first : agents.second).command(["pair", "confirm"]) }.code == 0)
        }
        for first in [true, false] {
            let deadline = ContinuousClock.now + .seconds(60)
            var state: PairingStatus
            repeat {
                state = try await clipOffPool { try (first ? agents.first : agents.second).command(["pair", "status"]) }.decode(PairingStatus.self)
                if !state.isActive { break }
                try await Task.sleep(for: .milliseconds(200))
            } while ContinuousClock.now < deadline
            try #require(state.state == .paired)
        }
        let content = "clipboard integration note"
        let added = try await clipOffPool { try agents.first.command(["clip", "add", "--text", content]) }.decode(ClipboardIngestResult.self)
        let id = try #require(added.id)
        #expect(added.status == "stored")
        let sent = try await clipOffPool { try agents.first.command(["clip", "send", id], timeout: 90) }
        #expect(sent.code == 0)
        #expect(try sent.decode(TransferRecord.self).status == "ok")
        let received = try await clipOffPool { try agents.second.command(["history", "--search", content]) }.decode([TransferRecord].self)
        #expect(received.count == 1 && received[0].text == content && received[0].direction == "received")
        let listed = try await clipOffPool { try agents.first.command(["clip", "list", "--search", "integration"]) }.decode([ClipboardItem].self)
        #expect(listed.count == 1 && listed[0].id == id)
        try await clipOffPool { try agents.first.restart() }
        #expect(try await clipOffPool { try agents.first.command(["clip", "list"]) }.decode([ClipboardItem].self).first?.id == id)
        // The send-clipboard shortcut: the newest copy, to the most recently used device.
        let newest = "latest clipboard note"
        #expect(try await clipOffPool { try agents.first.command(["clip", "add", "--text", newest]) }.decode(ClipboardIngestResult.self).status == "stored")
        let latestSent = try await clipOffPool { try agents.first.command(["clip", "send", "--latest"], timeout: 90) }
        #expect(latestSent.code == 0)
        #expect(try latestSent.decode(TransferRecord.self).status == "ok")
        let latestReceived = try await clipOffPool { try agents.second.command(["history", "--search", newest]) }.decode([TransferRecord].self)
        #expect(latestReceived.count == 1 && latestReceived[0].text == newest)
        #expect(try await clipOffPool { try agents.first.command(["clip", "pause", "on"]) }.code == 0)
        let paused = try await clipOffPool { try agents.first.command(["clip", "add", "--text", "paused note"]) }.decode(ClipboardIngestResult.self)
        #expect(paused.status == "paused")
        #expect(try await clipOffPool { try agents.first.command(["clip", "pause", "off"]) }.code == 0)
        let marked = try await clipOffPool { try agents.first.command(["clip", "add", "--offered-type", "x-kde-passwordManagerHint", "--file", "does-not-exist"]) }.decode(ClipboardIngestResult.self)
        #expect(marked.status == "marked" && !marked.canKeep)
        let filtered = try await clipOffPool { try agents.first.command(["clip", "add", "--text", "ghp_" + String(repeating: "z", count: 36)]) }.decode(ClipboardIngestResult.self)
        #expect(filtered.status == "filtered" && filtered.canKeep)
        // A skipped copy is refused, never replaced by the older item before it.
        let refused = try await clipOffPool { try agents.first.command(["clip", "send", "--latest"], timeout: 30) }
        #expect(refused.code == 1)
        let refusal = try JSONSerialization.jsonObject(with: refused.output) as? [String: Any]
        #expect(refusal?["error"] as? String == ClipboardFailure.latestFiltered.rawValue)
        #expect(try await clipOffPool { try agents.second.command(["history"]) }.decode([TransferRecord].self).count == 2)
        #expect(try await clipOffPool { try agents.first.command(["clip", "keep", filtered.id!]) }.code == 0)
        #expect(try await clipOffPool { try agents.first.command(["clip", "delete", id]) }.code == 0)
        let imageFile = agents.first.dataDirectory.appendingPathComponent("capture.png")
        try AgentPaths.writePrivate(Data([137, 80, 78, 71, 13, 10, 26, 10]), to: imageFile)
        let image = try await clipOffPool { try agents.first.command(["clip", "add", "--kind", "image", "--file", imageFile.path]) }.decode(ClipboardIngestResult.self)
        let imageID = try #require(image.id)
        let imageSent = try await clipOffPool { try agents.first.command(["clip", "send", imageID], timeout: 90) }.decode(TransferRecord.self)
        #expect(imageSent.status == "ok" && imageSent.kind == "file")
        let outbox = agents.first.dataDirectory.appendingPathComponent("outbox")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outbox.path).isEmpty)
        let reference = try await clipOffPool { try agents.first.command(["clip", "add", "--kind", "files", "--file", imageFile.path]) }.decode(ClipboardIngestResult.self)
        let referenceID = try #require(reference.id)
        let referenceSent = try await clipOffPool { try agents.first.command(["clip", "send", referenceID], timeout: 90) }.decode(TransferRecord.self)
        #expect(referenceSent.status == "ok" && referenceSent.kind == "file")
        let audit = try await clipOffPool { try agents.first.command(["audit"], timeout: 60) }
        #expect(audit.code == 0)
        #expect(try audit.decode([AuditFinding].self).isEmpty)
        let extra = agents.first.dataDirectory.appendingPathComponent("audit-input.txt")
        try AgentPaths.writePrivate(Data("clipboard integration note\n".utf8), to: extra)
        let leaked = try await clipOffPool { try agents.first.command(["audit", "--also", extra.path], timeout: 60) }
        #expect(leaked.code == 1)
        let findings = try leaked.decode([AuditFinding].self)
        #expect(findings.contains { $0.kind == "extra" && $0.line == 1 })
        let valuesRedacted = leaked.output.range(of: Data(content.utf8)) == nil
        #expect(valuesRedacted)
    }
}
