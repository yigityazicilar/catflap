import CatflapCore
import Foundation
import Testing

@Suite struct FollowCLIE2E {
    @Test func commandsExposeFollowFilterAndOpenWithoutDesktopAccess() async throws {
        let agent = try AgentHarness(); defer { agent.stop() }
        try await onThread { try agent.start() }
        let filter = try await onThread { try agent.command(["clip", "filter", "--off"]) }
        #expect(filter.code == 0)
        #expect(jsonObject(filter.output)?["filter_secrets"] as? Bool == false)
        let follow = try await onThread { try agent.command(["follow", "--off"]) }
        #expect(follow.code == 0)
        let pending = try await onThread { try agent.command(["follow", "--pending"]) }
        #expect(pending.code == 0)
        #expect((try? pending.decode([FollowPrompt].self).isEmpty) == true)
        let bad = try await onThread { try agent.command(["open", "--to", "missing", "--url", "javascript:alert(1)"]) }
        #expect(bad.code == 64)
        #expect(jsonObject(bad.output)?["ok"] as? Bool == false)
    }
}
