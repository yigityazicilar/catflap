import Foundation

public struct AgentStatus: Codable, Sendable {
    public var running: Bool = true
    public var deviceID: String
    public var build: String = "0.1.0-dev"
    public var schemaVersion: Int = 1
    public var serverRunning: Bool
    public var pairedDevices: Int
    public var desktop: String = "unsupported"
    enum CodingKeys: String, CodingKey {
        case running, build, desktop
        case deviceID = "device_id", schemaVersion = "schema_version"
        case serverRunning = "server_running", pairedDevices = "paired_devices"
    }
}
public struct UIState: Codable, Sendable {
    public var visible = false
    public var mode = "hidden"
    public var hasFocus = false
    public var display: String? = nil
    public var shortcut = "unavailable"
    public init() {}
    enum CodingKeys: String, CodingKey {
        case visible, mode, display, shortcut
        case hasFocus = "has_focus"
    }
}

public actor AgentRuntime {
    public let store: Store
    public let identityServer: IdentityServer
    private var ui = UIState()
    public typealias Handler = @Sendable (ControlRequest) async throws -> ControlResponse
    private var handlers: [String: Handler] = [:]
    private var services: [ObjectIdentifier: any Sendable] = [:]
    public init(paths: AgentPaths) throws {
        store = try Store(paths: paths)
        identityServer = try IdentityServer(persistence: IdentityStore(paths: paths))
    }
    /// Hands a long-lived service to the features installed after this one. One per type.
    public func provide<Service: Sendable>(_ service: Service) { services[ObjectIdentifier(Service.self)] = service }
    /// The service of this type an earlier feature provided, if any.
    public func service<Service: Sendable>(_ type: Service.Type = Service.self) -> Service? {
        services[ObjectIdentifier(type)] as? Service
    }
    public func start() async throws {
        let devices = try await store.devices()
        try await identityServer.rebuild(allowedClients: devices.map(\.clientPublicKey))
    }
    public func stop() async { await identityServer.stop() }
    public func register(_ command: String, handler: @escaping Handler) { handlers[command] = handler }
    public func setUIState(_ state: UIState) { ui = state }
    private func toggle() {
        ui.visible.toggle(); ui.mode = ui.visible ? "focused" : "hidden"; ui.hasFocus = ui.visible
    }
    public func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            if let handler = handlers[request.command] { return try await handler(request) }
            switch request.command {
            case "status":
                let devices = try await store.devices()
                return try ControlResponse(value: AgentStatus(deviceID: await identityServer.identity.id,
                    serverRunning: await identityServer.isRunning, pairedDevices: devices.count))
            case "devices": return try ControlResponse(value: try await store.devices().map(DeviceSummary.init))
            case "history": return try ControlResponse(value: try await store.history(search: request.arguments["search"]))
            case "ui.state": return try ControlResponse(value: ui)
            case "toggle":
                toggle()
                return try ControlResponse(value: ui)
            case "ui.invoke":
                switch request.arguments["action"] {
                case "toggle": toggle()
                case "hide": ui.visible = false; ui.mode = "hidden"; ui.hasFocus = false
                default: return ControlResponse(error: .unsupported, exitCode: 64)
                }
                return try ControlResponse(value: ui)
            case "pair", "send", "clip", "unpair": return ControlResponse(error: .unsupported, exitCode: 64)
            default: return ControlResponse(error: .invalidRequest, exitCode: 64)
            }
        } catch let error as AgentError { return ControlResponse(error: error) }
        catch { return ControlResponse(error: .storage) }
    }
}
