import CatflapCore
import Foundation

/// The desktop side of the agent on Linux: clipboard capture (T7) and the panel (T10).
///
/// The agent calls `start(on:)` once the core features are installed, the runtime is running
/// and the control socket is bound, and `stop()` after the control socket is closed and
/// before the runtime stops. `ClipboardHistory` is available from
/// `await runtime.service(ClipboardHistory.self)` by then.
///
/// `start(on:)` returns promptly. A desktop that lacks a protocol does not fail the agent:
/// report it with `runtime.updatePlatformStatus(_:)` and carry on. Throw only for a fault that
/// should stop the agent. `stop()` ends every thread and connection `start(on:)` opened.
public actor Platform {
    private var clipboard: DataControlWatcher?
    private var panel: Task<PanelApp?, Never>?

    public static func start(on runtime: AgentRuntime) async throws -> Platform {
        let platform = Platform()
        await platform.install(on: runtime)
        await platform.installPanel(on: runtime)
        return platform
    }

    private func install(on runtime: AgentRuntime) async {
        guard let history = await runtime.service(ClipboardHistory.self) else {
            await runtime.updatePlatformStatus { $0.clipboardCapture = "failed" }
            return
        }
        let watcher = DataControlWatcher(history: history, runtime: runtime)
        clipboard = watcher
        await watcher.start()
    }

    /// After the watcher has reported its state, so `desktop` is added to that report. In a
    /// task of its own: GTK's start can wait on the desktop portal, and the control channel
    /// should answer meanwhile. Without a display or layer-shell the agent runs without a
    /// panel and `desktop` stays `unsupported`.
    private func installPanel(on runtime: AgentRuntime) {
        panel = Task { await PanelApp.start(on: runtime) }
    }

    public func stop() async {
        let panel = self.panel
        self.panel = nil
        if let panel {
            panel.cancel()
            await Self.value(of: panel, within: .seconds(2))?.stop()
        }
        let watcher = clipboard
        clipboard = nil
        await watcher?.stop()
    }

    /// The started panel, or nil if its start is still waiting after `limit`: GTK can sit in
    /// a D-Bus call while it starts, and the agent must stop within seconds. A start that
    /// finishes later sees the cancellation and closes what it opened.
    private static func value(of start: Task<PanelApp?, Never>, within limit: Duration) async -> PanelApp? {
        let once = Once()
        return await withCheckedContinuation { (result: CheckedContinuation<PanelApp?, Never>) in
            Task {
                let app = await start.value
                if !once.claim() { await app?.stop(); return }
                result.resume(returning: app)
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.claim() { result.resume(returning: nil) }
            }
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    /// True for the first caller only.
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
