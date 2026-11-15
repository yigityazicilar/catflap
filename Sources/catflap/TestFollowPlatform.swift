import CatflapCore
import Foundation

/// Headless integration double, enabled only explicitly with the ordinary desktop off.
/// It simulates the watcher seeing the exact origin-marked offer, never a system clipboard.
actor TestFollowPlatform: FollowPlatform {
    let history: ClipboardHistory
    private var writes = 0
    private var opens = 0
    private var lastURL: String?
    init(history: ClipboardHistory) { self.history = history }
    func writeClipboard(_ content: ClipboardContent, origin: ClipboardOrigin) async throws {
        _ = try await history.ingest(offeredTypes: [ClipboardOrigin.linuxType], origin: origin) { content }
        writes += 1
    }
    func requestPermission(_ prompt: FollowPrompt) async {}
    func openURL(_ url: URL) async throws { opens += 1; lastURL = url.absoluteString }
    struct State: Encodable { let writes: Int; let opens: Int; let last_url: String? }
    func state() -> State { State(writes: writes, opens: opens, last_url: lastURL) }
}
