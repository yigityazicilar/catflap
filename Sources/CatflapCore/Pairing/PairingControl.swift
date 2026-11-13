import Foundation

/// The result of `unpair`, as the command line reads it.
public struct UnpairResult: Codable, Sendable {
    public var removed: String
    public var name: String
    /// Whether a server runs for the remaining devices; nil while it is still restarting.
    public var serverRunning: Bool?
    public var state: String
    enum CodingKeys: String, CodingKey { case removed, name, state, serverRunning = "server_running" }
}

extension PairingService {
    /// Creates the peer and pairing services for `runtime` and registers their control
    /// commands. Call before `runtime.start()`, so the listener observer sees the first start.
    @discardableResult
    public static func install(on runtime: AgentRuntime, configuration: PairingConfiguration = .init()) async -> PairingService {
        let peers = PeerService(runtime: runtime, build: configuration.build)
        await peers.install()
        let service = PairingService(runtime: runtime, peers: peers, configuration: configuration)
        // Features installed later (transfers, clipboard) reach the same instances.
        await runtime.provide(peers)
        await runtime.provide(service)
        await runtime.register("pair.start") { _ in await respond { try await service.start() } }
        await runtime.register("pair.join") { request in
            await respond { try await service.join(code: request.arguments["code"] ?? "") }
        }
        await runtime.register("pair.status") { _ in await respond { await service.currentStatus() } }
        await runtime.register("pair.confirm") { _ in await respond { try await service.confirm() } }
        await runtime.register("pair.decline") { _ in await respond { await service.decline() } }
        await runtime.register("pair.check") { request in
            await respond {
                let device = try await service.resolve(request.arguments["device"] ?? "")
                if request.arguments["start"] == "1" { return await service.startCheck(deviceID: device.id) }
                guard let status = await service.checkStatus(deviceID: device.id) else {
                    throw ControlFailure("No check has run for that device.")
                }
                return status
            }
        }
        await runtime.register("unpair") { request in
            await respond {
                let device = try await service.resolve(request.arguments["device"] ?? "")
                let work = Task<Bool, Error> { try await peers.unpair(deviceID: device.id) }
                // Answer within the control channel's limit; a slow restart goes on.
                switch await awaitAtMost(.seconds(4), work) {
                case .success(let running)?:
                    return UnpairResult(removed: device.id, name: device.name, serverRunning: running, state: "done")
                case .failure?:
                    let remaining = try await runtime.store.devices().contains { $0.id == device.id }
                    throw ControlFailure(remaining ? "Could not remove the device."
                        : "Removed \(device.name), but the server for the remaining devices did not start.")
                case nil:
                    return UnpairResult(removed: device.id, name: device.name, serverRunning: nil, state: "restarting")
                }
            }
        }
        return service
    }

    /// A paired device by id, or by name when exactly one device has it.
    func resolve(_ text: String) async throws -> DeviceRecord {
        let devices = try await runtime.store.devices()
        if let device = devices.first(where: { $0.id == text }) { return device }
        let named = devices.filter { $0.name == text }
        guard !named.isEmpty else { throw ControlFailure("No paired device has that id or name.") }
        guard named.count == 1 else { throw ControlFailure("Several paired devices have that name. Use the device id.") }
        return named[0]
    }
}

struct ControlFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private func respond<T: Encodable & Sendable>(_ body: @Sendable () async throws -> T) async -> ControlResponse {
    do { return try ControlResponse(value: try await body()) }
    catch {
        let message: String
        switch error {
        case let failure as ControlFailure: message = failure.message
        case let failure as LocalizedError: message = failure.errorDescription ?? AgentError.invalidRequest.rawValue
        default: message = AgentError.storage.rawValue
        }
        var response = ControlResponse(error: .invalidRequest, exitCode: 1)
        response.error = message
        return response
    }
}
