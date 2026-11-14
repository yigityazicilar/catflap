import CatflapCore

/// The desktop side of the agent on macOS: pasteboard capture (T8) and, later, the panel (T11).
///
/// The agent calls `start(on:)` once the core features are installed, the runtime is running
/// and the control socket is bound, and `stop()` after the control socket is closed and
/// before the runtime stops. `ClipboardHistory` is available from
/// `await runtime.service(ClipboardHistory.self)` by then.
///
/// `start(on:)` returns promptly. A missing permission does not fail the agent: report it with
/// `runtime.setPlatformStatus(_:)` (`pasteboardAccess`) and carry on. Throw only for a fault
/// that should stop the agent. `stop()` ends every timer and thread `start(on:)` opened.
public actor Platform {
    public static func start(on runtime: AgentRuntime) async throws -> Platform {
        Platform()
    }
    public func stop() async {}
}
