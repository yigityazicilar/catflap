import Foundation
import Tailcat

public struct DevicePresence: Codable, Sendable {
    public enum State: String, Codable, Sendable { case here, away, checking }
    public let deviceID: String
    public let state: State
    public let path: String?
    public let relayRegionID: Int?
    public let relayRegionCode: String?
    public let latencyMs: Double?
    public let checkedAt: Date?
    public let ageSeconds: Double?
    enum CodingKeys: String, CodingKey {
        case state, path
        case deviceID = "device_id", relayRegionID = "relay_region_id", relayRegionCode = "relay_region_code"
        case latencyMs = "latency_ms", checkedAt = "checked_at", ageSeconds = "age_seconds"
    }
}

public struct PresenceLease: Codable, Sendable {
    public let leaseID: String
    public let expiresAt: Date
    enum CodingKeys: String, CodingKey { case leaseID = "lease_id", expiresAt = "expires_at" }
}

/// Presence is a hint, not authorization or a guarantee that the next transfer succeeds.
/// Results are memory-only and contain no network endpoints.
public actor PresenceService {
    public typealias Devices = @Sendable () async throws -> [DeviceRecord]
    public typealias Ping = @Sendable (DeviceRecord, Duration) async throws -> TailcatPing
    public static let interval: TimeInterval = 60
    public static let leaseLifetime: TimeInterval = 90
    public static let timeout: Duration = .seconds(10)
    private let devices: Devices
    private let ping: Ping
    private let now: @Sendable () -> Date
    private struct Cached {
        var checkedAt: Date
        var ping: TailcatPing?
    }
    private struct Flight {
        var task: Task<Void, Never>
        var device: DeviceRecord
    }
    private var cache: [String: Cached] = [:]
    private var active: [String: Flight] = [:]
    private var known: [String: DeviceRecord] = [:]
    private var started: [String: Date] = [:]
    private var leases: [String: Date] = [:]
    private var timer: Task<Void, Never>?
    private var stopped = false

    public init(devices: @escaping Devices, ping: @escaping Ping, now: @escaping @Sendable () -> Date = { Date() }) {
        self.devices = devices; self.ping = ping; self.now = now
    }

    public init(devices: @escaping Devices, clientKeys: TailcatKeys) {
        self.devices = devices; self.now = { Date() }
        self.ping = { device, timeout in
            let client = try TailcatClient(address: device.address, key: clientKeys)
            do {
                let result = try await client.ping(timeout: timeout)
                await client.close()
                return result
            } catch { await client.close(); throw error }
        }
    }

    public init(store: Store, clientKeys: TailcatKeys) {
        self.init(devices: { try await store.devices() }, clientKeys: clientKeys)
    }

    public func install(on runtime: AgentRuntime) async {
        await runtime.provide(self)
        await runtime.register("presence") { [self] request in
            guard request.arguments["refresh"] == nil || ["true", "false"].contains(request.arguments["refresh"]!) else {
                return ControlResponse(error: .invalidRequest, exitCode: 64)
            }
            return try ControlResponse(value: await presence(refresh: request.arguments["refresh"] != "false"))
        }
        await runtime.register("presence.watch") { [self] request in
            do { return try ControlResponse(value: await watch(leaseID: request.arguments["lease_id"])) }
            catch let error as AgentError { return ControlResponse(error: error, exitCode: 64) }
        }
    }

    /// Default: request a new check and return immediately with `checking`. Poll with
    /// refresh=false to read cached results without starting another ping.
    public func presence(refresh: Bool = true) async throws -> [DevicePresence] {
        let rows = try await loadDevices()
        if refresh && !stopped { for device in rows { start(device) } }
        let date = now()
        return rows.map { device in
            let result = cache[device.id]
            let path: String?
            let regionID: Int?
            let regionCode: String?
            switch result?.ping?.path {
            case .direct: path = "direct"; regionID = nil; regionCode = nil
            case .relayed(let id, let code): path = "relayed"; regionID = id; regionCode = code
            case nil: path = nil; regionID = nil; regionCode = nil
            }
            return DevicePresence(deviceID: device.id,
                state: active[device.id] != nil || result == nil ? .checking : (result?.ping == nil ? .away : .here),
                path: path, relayRegionID: regionID, relayRegionCode: regionCode,
                latencyMs: result?.ping.map { $0.latency * 1000 }, checkedAt: result?.checkedAt,
                ageSeconds: result.map { max(0, date.timeIntervalSince($0.checkedAt)) })
        }
    }

    /// Open with no id; renew the returned id at least every 60 s. Each lease lasts 90 s.
    /// Multiple panels are independent; a crashed or closed panel naturally stops renewing.
    public func watch(leaseID: String? = nil) async throws -> PresenceLease {
        guard !stopped else { throw AgentError.invalidRequest }
        expireLeases()
        let wasEmpty = leases.isEmpty
        let id: String
        if let leaseID {
            guard leases[leaseID] != nil else { throw AgentError.invalidRequest }
            id = leaseID
        } else {
            guard leases.count < 256 else { throw AgentError.invalidRequest }
            id = UUID().uuidString
        }
        // Fail closed if the paired-device list cannot be read.
        let rows = try await loadDevices()
        guard !stopped else { throw AgentError.invalidRequest }
        let expiry = now().addingTimeInterval(Self.leaseLifetime)
        leases[id] = expiry
        if wasEmpty { for device in rows { start(device) } }
        if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self else { return }
                    do { try await self.tick() } catch { /* A fresh request can retry a failed device-list read. */ }
                    if await self.hasNoLeases { return }
                }
            }
        }
        return PresenceLease(leaseID: id, expiresAt: expiry)
    }

    private var hasNoLeases: Bool { leases.isEmpty || stopped }
    private func expireLeases() {
        let date = now()
        leases = leases.filter { $0.value > date }
        if leases.isEmpty { timer?.cancel(); timer = nil }
    }

    // The scheduler and deterministic tests use the same lease/due gate.
    func tick() async throws {
        expireLeases()
        guard !leases.isEmpty, !stopped else { return }
        let rows = try await loadDevices()
        // loadDevices suspends: a lease or stop can change while it runs.
        expireLeases()
        guard !leases.isEmpty, !stopped else { return }
        let date = now()
        for device in rows where started[device.id].map({ date.timeIntervalSince($0) >= Self.interval }) ?? true {
            start(device)
        }
    }

    private func loadDevices() async throws -> [DeviceRecord] {
        let rows = try await devices()
        let fresh = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for (id, flight) in active {
            if let device = fresh[id], samePeer(device, flight.device) { continue }
            flight.task.cancel()
        }
        cache = cache.filter { id, _ in
            guard let old = known[id], let new = fresh[id] else { return false }
            return samePeer(old, new)
        }
        started = started.filter { cache[$0.key] != nil || active[$0.key] != nil }
        known = fresh
        return rows
    }

    private func samePeer(_ lhs: DeviceRecord, _ rhs: DeviceRecord) -> Bool {
        lhs.address == rhs.address && lhs.clientPublicKey == rhs.clientPublicKey && lhs.pairedAt == rhs.pairedAt
    }

    private func start(_ device: DeviceRecord) {
        guard active[device.id] == nil, !stopped else { return }
        started[device.id] = now()
        let ping = self.ping
        let task = Task { [weak self] in
            let result: TailcatPing?
            do { result = try await ping(device, Self.timeout) } catch { result = nil }
            await self?.finish(device, result: result, cancelled: Task.isCancelled)
        }
        active[device.id] = Flight(task: task, device: device)
    }

    private func finish(_ device: DeviceRecord, result: TailcatPing?, cancelled: Bool) {
        active[device.id] = nil
        guard !stopped, !cancelled, let current = known[device.id], samePeer(current, device) else { return }
        cache[device.id] = Cached(checkedAt: now(), ping: result)
        if result != nil, let onHere {
            let id = device.id
            Task { await onHere(id) }
        }
    }

    public typealias HereHandler = @Sendable (_ deviceID: String) async -> Void
    private var onHere: HereHandler?
    /// Called for each check a device answered. An answer proves its server admits this
    /// device, which confirms a new pairing and makes its waiting deliveries due.
    public func setHereHandler(_ handler: HereHandler?) { onHere = handler }

    /// Waits for the current checks, including cancellation cleanup. Does not trigger a ping.
    public func waitForChecks() async {
        let tasks = active.values.map(\.task)
        for task in tasks { await task.value }
    }

    /// Call before shutting down the agent. Cancels leases and waits for C calls to return
    /// and for their clients to close off-thread.
    public func stop() async {
        stopped = true
        timer?.cancel(); timer = nil; leases.removeAll()
        let tasks = active.values.map(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        cache.removeAll(); known.removeAll(); started.removeAll()
    }

    deinit { timer?.cancel(); for flight in active.values { flight.task.cancel() } }
}
