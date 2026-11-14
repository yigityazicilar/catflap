#if os(macOS)
import CatflapCore

/// Owns capture and the panel for exactly the agent's platform lifetime.
public actor Platform {
    private var watcherTask: Task<Void, Never>?
    private var panel: PanelController?
    private init(watcherTask: Task<Void, Never>, panel: PanelController) {
        self.watcherTask = watcherTask
        self.panel = panel
    }
    public static func start(on runtime: AgentRuntime) async throws -> Platform {
        guard let history = await runtime.service(ClipboardHistory.self) else { throw ClipboardFailure.missing }
        let watcher = await ClipboardWatcher(source: SystemClipboardSource(), history: history, runtime: runtime)
        await watcher.reportStatus()
        let task = Task { @MainActor in await watcher.run() }
        // The panel starts AppKit's event loop and takes over `toggle`, `ui state` and `ui invoke`.
        let panel = await PanelController.start(runtime: runtime)
        return Platform(watcherTask: task, panel: panel)
    }
    public func stop() async {
        // The panel goes first, before the clipboard watcher.
        if let panel {
            self.panel = nil
            await panel.stop()
        }
        guard let task = watcherTask else { return }
        watcherTask = nil
        task.cancel()
        await task.value
    }
}
#endif
