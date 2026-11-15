import Foundation

extension FollowService {
    public func install(on runtime: AgentRuntime, clipboard: ClipboardService) async {
        await runtime.provide(self)
        await transfersForInstallation().setReceivedHandler { [weak self] device, id, content, keep, intent in
            do { try await self?.received(deviceID: device, id: id, content: content, keep: keep, intent: intent) }
            catch { await self?.noteFailure(error) }
        }
        await clipboard.history.setRecordedHandler { [weak self, weak clipboard] id, content, keep in
            guard let self, let clipboard else { return }
            do { try await self.recorded(id: id, content: content, keep: keep, clipboard: clipboard) }
            catch { await self.noteFailure(error) }
        }
        for command in ["follow", "follow.set", "follow.permission", "links.policy", "follow.prompts", "follow.answer", "open"] {
            await runtime.register(command) { [self] request in
                do { return try await handle(request) }
                catch {
                    if let failure = error as? AgentError { return ControlResponse(failure: failure.rawValue) }
                    if let failure = error as? ClipboardFailure { return ControlResponse(failure: failure.rawValue) }
                    if let failure = error as? TransferFailure { return ControlResponse(failure: failure.errorDescription ?? "Invalid transfer.") }
                    // Desktop adapters may throw LocalizedError containing clipboard or URL
                    // content. Never forward their descriptions over the control socket.
                    await noteFailure(error)
                    return ControlResponse(failure: "The desktop action could not be completed.")
                }
            }
        }
    }
    private func handle(_ request: ControlRequest) async throws -> ControlResponse {
        let a = request.arguments
        switch request.command {
        case "follow": return try await ControlResponse(value: settings(deviceID: a["device_id"]))
        case "follow.set":
            guard (a["device_id"] != nil) != (a["off"] == "true") else { throw AgentError.invalidRequest }
            try await setTarget(a["device_id"])
            return try await ControlResponse(value: settings(deviceID: nil))
        case "follow.permission":
            guard let device = a["device_id"] else { throw AgentError.invalidRequest }
            try await requirePaired(device)
            if let raw = a["permission"] {
                guard let permission = FollowPermission(rawValue: raw) else { throw AgentError.invalidRequest }
                try await setPermission(permission, deviceID: device)
            }
            return try await ControlResponse(value: settings(deviceID: device))
        case "links.policy":
            guard let device = a["device_id"] else { throw AgentError.invalidRequest }
            try await requirePaired(device)
            if let raw = a["policy"] {
                guard let policy = LinkOpenPolicy(rawValue: raw) else { throw AgentError.invalidRequest }
                try await setOpenPolicy(policy, deviceID: device)
            }
            return try await ControlResponse(value: settings(deviceID: device))
        case "follow.prompts": return try ControlResponse(value: prompts())
        case "follow.answer":
            guard let id = a["id"], let value = a["allow"], ["true", "false"].contains(value) else { throw AgentError.invalidRequest }
            try await answer(id: id, allow: value == "true")
            return try ControlResponse(value: ["answered": true])
        case "open":
            guard let device = a["device_id"], let id = a["id"] else { throw AgentError.invalidRequest }
            try await requirePaired(device)
            try await open(deviceID: device, id: id)
            return try ControlResponse(value: ["requested": true])
        default: throw AgentError.invalidRequest
        }
    }
}
public struct FollowSettings: Codable, Sendable {
    public let target: String?
    public let deviceID: String?
    public let permission: FollowPermission?
    public let openPolicy: LinkOpenPolicy?
    public let lastFailure: String?
    enum CodingKeys: String, CodingKey { case target, permission; case deviceID = "device_id", openPolicy = "open_policy", lastFailure = "last_failure" }
}
