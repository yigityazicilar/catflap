import CatflapCore

/// A command's task installs its engine handlers without editing agent startup.
protocol AgentFeature {
    static func install(on runtime: AgentRuntime) async throws
}
extension AgentFeature {
    static func install(on runtime: AgentRuntime) async throws {}
}
