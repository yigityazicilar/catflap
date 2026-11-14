#if os(macOS)
import CatflapCore

/// Owns capture for exactly the agent's platform lifetime.
public actor Platform {
    private var watcherTask: Task<Void, Never>?
    private init(watcherTask: Task<Void, Never>) { self.watcherTask = watcherTask }
    public static func start(on runtime: AgentRuntime) async throws -> Platform {
        guard let history = await runtime.service(ClipboardHistory.self) else { throw ClipboardFailure.missing }
        let watcher = await ClipboardWatcher(source: SystemClipboardSource(), history: history, runtime: runtime)
        await watcher.reportStatus()
        let task = Task { @MainActor in await watcher.run() }
        return Platform(watcherTask: task)
    }
    public func stop() async {
        guard let task = watcherTask else { return }
        watcherTask = nil
        task.cancel()
        await task.value
    }
}
#endif
