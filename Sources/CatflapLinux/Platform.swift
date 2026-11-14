import CatflapCore

/// The desktop side of the agent on Linux: clipboard capture (T7) and, later, the panel (T10).
///
/// The agent calls `start(on:)` once the core features are installed, the runtime is running
/// and the control socket is bound, and `stop()` after the control socket is closed and
/// before the runtime stops. `ClipboardHistory` is available from
/// `await runtime.service(ClipboardHistory.self)` by then.
///
/// `start(on:)` returns promptly. A desktop that lacks a protocol does not fail the agent:
/// report it with `runtime.setPlatformStatus(_:)` and carry on. Throw only for a fault that
/// should stop the agent. `stop()` ends every thread and connection `start(on:)` opened.
public actor Platform {
    public static func start(on runtime: AgentRuntime) async throws -> Platform {
        Platform()
    }
    public func stop() async {}
}
