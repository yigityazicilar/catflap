import CatflapCore
import Foundation
import Testing

@Suite struct FollowAgentsE2E {
    struct DesktopState: Decodable { let writes: Int; let opens: Int; let last_url: String? }
    private func call<T: Decodable>(_ agent: AgentHarness, _ command: String, _ arguments: [String: String] = [:], as type: T.Type) async throws -> T {
        let reply = try await ControlClient.requestAsync(.init(command, arguments: arguments), socket: agent.dataDirectory.appendingPathComponent("control.sock"))
        guard reply.ok else { throw AgentError.invalidRequest }
        return try ControlJSON.decoder.decode(type, from: reply.payload)
    }
    private func desktop(_ agent: AgentHarness) async throws -> DesktopState { try await call(agent, "follow.test.state", as: DesktopState.self) }
    private func sent(_ agent: AgentHarness) async throws -> [TransferRecord] {
        try await call(agent, "transfers.list", ["direction": "sent"], as: TransferPage.self).items
    }
    private func copyAndDeliver(_ agent: AgentHarness, label: String) async throws {
        let before = try await sent(agent).count
        let added = try await onThread { try agent.command(["clip", "add", "--text", "ordinary follow note " + label]) }
        try #require(added.code == 0)
        // Hang guard only. The asserted event is a committed receive acknowledged by the peer.
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            let rows = try await sent(agent)
            if rows.count > before, let latest = rows.first {
                if latest.status == "ok" { return }
                if ["failed", "unconfirmed"].contains(latest.status) { Issue.record("follow delivery did not complete: \(latest.status)"); return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("follow delivery did not reach its acknowledgement")
    }
    private func waitForOpenReceipt(_ sender: AgentHarness, device: String, id: String) async throws {
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            let row: TransferRecord = try await call(sender, "transfers.get", ["device_id": device, "id": id], as: TransferRecord.self)
            if row.status == "ok" { return }
            if ["failed", "unconfirmed"].contains(row.status) { throw AgentError.invalidRequest }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AgentError.invalidRequest
    }
    @Test func remoteOpenToUsesAskAnswerRefusalAndAlwaysWithTwoRealAgents() async throws {
        let agents = try PairedAgents(environment: ["CATFLAP_TEST_FOLLOW_PLATFORM": "1"])
        defer { agents.stop() }
        try await agents.startAndPair()
        let a = agents.first, b = agents.second
        let destination = try #require(try await onThread { try a.command(["devices"]) }.decode([DeviceSummary].self).first?.id)
        let source = try #require(try await onThread { try b.command(["devices"]) }.decode([DeviceSummary].self).first?.id)
        for (suffix, allow) in [("allowed", true), ("refused", false)] {
            let output = try await onThread { try a.command(["open", "--to", destination, "--url", "HTTPS://EXAMPLE.ORG:443/" + suffix, "--dont-keep"]) }
            try #require(output.code == 0)
            let batch = try output.decode(TransferBatch.self)
            let row = try #require(batch.transfers.first)
            try await waitForOpenReceipt(a, device: destination, id: row.id)
            let prompts: [FollowPrompt] = try await call(b, "follow.prompts", as: [FollowPrompt].self)
            let prompt = try #require(prompts.first(where: { $0.kind == "open" }))
            #expect(prompt.url == "https://example.org/" + suffix)
            #expect(try await desktop(b).opens == (suffix == "allowed" ? 0 : 1))
            #expect(try await onThread { try b.command(["follow", "--answer", prompt.id, allow ? "--allow" : "--refuse"]) }.code == 0)
            #expect(try await desktop(b).opens == 1)
        }
        #expect(try await onThread { try b.command(["follow", "--device", source, "--open-links", "always"]) }.code == 0)
        let output = try await onThread { try a.command(["open", "--to", destination, "--url", "HTTP://EXAMPLE.ORG:80/always"]) }
        try #require(output.code == 0)
        let batch = try output.decode(TransferBatch.self)
        try await waitForOpenReceipt(a, device: destination, id: #require(batch.transfers.first).id)
        #expect(try await desktop(b).opens == 2)
        #expect(try await desktop(b).last_url == "http://example.org/always")
        let prompts: [FollowPrompt] = try await call(b, "follow.prompts", as: [FollowPrompt].self)
        #expect(prompts.isEmpty)
        #expect(try await onThread { try a.command(["open", "--to", destination, "--url", "file:///not-opened"]) }.code == 64)
        #expect(try await desktop(b).opens == 2)
        print("remote open --to: ask/allow, ask/refuse, always; normalized test opener calls 2, system opener calls 0")
    }
    @Test func twoRealAgentsFollowBothWaysAndOpenThroughTheTestOpener() async throws {
        let agents = try PairedAgents(environment: ["CATFLAP_TEST_FOLLOW_PLATFORM": "1"])
        defer { agents.stop() }
        try await agents.startAndPair()
        let a = agents.first, b = agents.second
        let aDevice = try #require(try await onThread { try a.command(["devices"]) }.decode([DeviceSummary].self).first?.id)
        let bDevice = try #require(try await onThread { try b.command(["devices"]) }.decode([DeviceSummary].self).first?.id)
        #expect(try await onThread { try a.command(["follow", "--to", aDevice]) }.code == 0)
        #expect(try await onThread { try b.command(["follow", "--to", bDevice]) }.code == 0)
        for (direction, sender, receiver, senderOnReceiver) in [("A to B", a, b, bDevice), ("B to A", b, a, aDevice)] {
            let beforeWrites = try await desktop(receiver).writes
            let beforeSent = try await sent(receiver).count
            try await copyAndDeliver(sender, label: direction + " unset")
            #expect(try await desktop(receiver).writes == beforeWrites)
            let prompts: [FollowPrompt] = try await call(receiver, "follow.prompts", as: [FollowPrompt].self)
            #expect(prompts.count == 1 && prompts.first?.kind == "follow")
            #expect(try await onThread { try receiver.command(["follow", "--device", senderOnReceiver, "--permission", "allowed"]) }.code == 0)
            #expect(try await desktop(receiver).writes == beforeWrites + 1)
            try await copyAndDeliver(sender, label: direction + " allowed")
            #expect(try await desktop(receiver).writes == beforeWrites + 2)
            // A followed offer's watcher callback completed before the ack. It created no send,
            // even though the receiver has its own follow target enabled.
            #expect(try await sent(receiver).count == beforeSent)
            #expect(try await onThread { try receiver.command(["follow", "--device", senderOnReceiver, "--permission", "refused"]) }.code == 0)
            try await copyAndDeliver(sender, label: direction + " refused")
            #expect(try await desktop(receiver).writes == beforeWrites + 2)
            #expect(try await sent(receiver).count == beforeSent)
            print("follow \(direction): unset held, allowed wrote twice, refused received without writing; forwarded-back count 0")
        }
        // Ordinary received URL: explicit open command asks, then the answer reaches the
        // injected opener, not the system browser.
        let sentURL = try await onThread { try a.command(["send", "--to", aDevice, "--text", "HTTPS://EXAMPLE.ORG:443/follow-check", "--now"], timeout: 180) }
        try #require(sentURL.code == 0)
        let receivedURL = try sentURL.decode(TransferRecord.self)
        let id = receivedURL.id
        #expect(try await onThread { try b.command(["open", "--from", bDevice, id]) }.code == 0)
        #expect(try await desktop(b).opens == 0)
        let prompts: [FollowPrompt] = try await call(b, "follow.prompts", as: [FollowPrompt].self)
        let prompt = try #require(prompts.first(where: { $0.kind == "open" }))
        #expect(try await onThread { try b.command(["follow", "--answer", prompt.id, "--allow"]) }.code == 0)
        let state = try await desktop(b)
        #expect(state.opens == 1 && state.last_url == "https://example.org/follow-check")
        print("open command: test opener received https://example.org/follow-check, calls 1; system opener calls 0")
    }
}
