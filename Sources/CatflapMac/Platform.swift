#if os(macOS)
import CatflapCore

/// Owns capture, the panel and its actions for exactly the agent's platform lifetime.
public actor Platform {
    private var watcherTask: Task<Void, Never>?
    private var panel: PanelController?
    private var actions: PanelActions?
    private init(watcherTask: Task<Void, Never>, panel: PanelController, actions: PanelActions) {
        self.watcherTask = watcherTask
        self.panel = panel
        self.actions = actions
    }
    public static func start(on runtime: AgentRuntime) async throws -> Platform {
        guard let history = await runtime.service(ClipboardHistory.self) else { throw ClipboardFailure.missing }
        let watcher = await ClipboardWatcher(source: SystemClipboardSource(), history: history, runtime: runtime)
        await watcher.reportStatus()
        let task = Task { @MainActor in await watcher.run() }
        // The panel starts AppKit's event loop and takes over `toggle`, `ui state` and `ui invoke`.
        let panel = await PanelController.start(runtime: runtime)
        // The actions attach themselves to the panel, which calls them for its controls, and
        // take `ui state` and `ui invoke` over again, passing the panel's own actions on.
        let actions = await PanelActions.start(runtime: runtime, controller: panel, pollClipboard: { @MainActor in await watcher.poll() })
        return Platform(watcherTask: task, panel: panel, actions: actions)
    }
    public func stop() async {
        // The actions go first, then the panel, then the clipboard watcher.
        if let actions {
            self.actions = nil
            await actions.stop()
        }
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
