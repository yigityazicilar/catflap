import Foundation
import Tailcat

/// Serves the permanent server: runs the Open step on every accepted connection, and owns
/// every change to the server's allowlist so pairing and unpairing cannot interleave.
public actor PeerService {
    public nonisolated let runtime: AgentRuntime
    public nonisolated let build: String
    /// The protocol version this side speaks. Only tests set another one.
    public var version = WireProtocol.version
    /// Called with each authenticated session, inbound or outbound. The handler owns the
    /// session until it returns; the service then closes it. Transfers install one here.
    public typealias SessionHandler = @Sendable (PeerSession, _ inbound: Bool) async -> Void
    private var sessionHandler: SessionHandler?
    private var acceptTask: Task<Void, Never>?
    private var listenerID: ObjectIdentifier?
    private var sessions: [UUID: (deviceID: String?, session: PeerSession?, connection: WireConnection)] = [:]
    /// Client keys of a pairing in progress: on the allowlist, not yet in the store.
    private var pendingKeys: Set<String> = []
    /// The allowlist of the last rebuild this service made; nil before the first one.
    private var activeAllowlist: Set<String>?
    private var gateBusy = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    public init(runtime: AgentRuntime, build: String = AgentStatus.currentBuild) {
        self.runtime = runtime; self.build = build
    }

    /// Registers the listener observer. Call before `runtime.start()`.
    public func install() async {
        await runtime.identityServer.observeListener { [weak self] listener in
            await self?.listenerChanged(listener)
        }
    }

    public func setSessionHandler(_ handler: SessionHandler?) { sessionHandler = handler }
    public func setVersion(_ value: Int) { version = value }

    private func listenerChanged(_ listener: TailcatListener?) {
        acceptTask?.cancel(); acceptTask = nil
        listenerID = listener.map(ObjectIdentifier.init)
        guard let listener else { return }
        // Start the loop and return: the observer must not wait on an accept.
        acceptTask = Task { [weak self] in await self?.acceptLoop(listener) }
    }

    private nonisolated func acceptLoop(_ listener: TailcatListener) async {
        while !Task.isCancelled {
            do {
                let connection = try await listener.accept()
                Task { [weak self] in await self?.serve(connection) }
            } catch let error as TailcatError where error.code == .closed || error.code == .cancelled {
                return
            } catch {
                if Task.isCancelled { return }
                // Avoid a busy loop on a repeating failure; a rebuild replaces this loop.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func serve(_ transport: TailcatConnection) async {
        let connection = WireConnection(transport)
        let key = UUID()
        sessions[key] = (nil, nil, connection)
        let store = runtime.store
        let localID = await runtime.identityServer.identity.id
        let outcome = await PeerOpen.accept(connection, localID: localID, version: version) { id in
            // Read the store each time, so a device removed a moment ago cannot authenticate.
            try? await store.devices().first { $0.id == id }
        }
        guard case .authenticated(let device, let hello) = outcome else {
            await connection.close(); sessions[key] = nil
            return
        }
        if hello.build != device.build {
            try? await store.execute("UPDATE devices SET build=? WHERE id=?", bindings: [.text(hello.build), .text(device.id)])
        }
        let session = PeerSession(device: device, connection: connection, client: nil)
        sessions[key] = (device.id, session, connection)
        if let sessionHandler {
            await sessionHandler(session, true)
        } else {
            // Nothing to do yet: hold the session until the peer or the server ends it.
            while let _ = try? await connection.readRaw(maxLength: 64 * 1024, deadline: .now + .seconds(30)) {}
        }
        await session.close(); sessions[key] = nil
    }

    /// Dials a paired device and authenticates. The caller closes the session, or passes it
    /// back with `release`. Throws `PeerError` with the message a person reads.
    public func open(deviceID: String, timeout: Duration = .seconds(30)) async throws -> PeerSession {
        guard let device = try await runtime.store.devices().first(where: { $0.id == deviceID }) else {
            throw PeerError.refused(device: deviceID)
        }
        let identity = await runtime.identityServer.identity
        let session = try await PeerOpen.dial(device, identity: identity, build: build, version: version, timeout: timeout)
        sessions[session.id] = (device.id, session, session.connection)
        return session
    }

    public func release(_ session: PeerSession) async {
        await session.close(); sessions[session.id] = nil
    }

    /// Number of open connections, authenticated or still in the Open step.
    public func openConnections(deviceID: String? = nil) -> Int {
        guard let deviceID else { return sessions.count }
        return sessions.values.filter { $0.deviceID == deviceID }.count
    }

    // MARK: Allowlist changes

    private func acquireGate() async {
        if !gateBusy { gateBusy = true; return }
        await withCheckedContinuation { gateWaiters.append($0) }
    }
    private func releaseGate() {
        if gateWaiters.isEmpty { gateBusy = false } else { gateWaiters.removeFirst().resume() }
    }

    /// Rebuilds the permanent server from the stored devices plus pending pairing keys. With
    /// no key at all, no server runs.
    private func rebuildLocked() async throws {
        let keys = try await allowlist()
        activeAllowlist = nil
        try await runtime.identityServer.rebuild(allowedClients: keys)
        activeAllowlist = Set(keys)
    }

    /// Adds a pairing peer's client key, rebuilds the server with it and returns the
    /// server's address. The key stays on the allowlist until `commitPairing` or
    /// `abandonPairing`.
    public func preparePairing(clientKey: String) async throws -> String {
        await acquireGate(); defer { releaseGate() }
        pendingKeys.insert(clientKey)
        do {
            try await rebuildLocked()
            guard let address = try await runtime.identityServer.address() else { throw AgentError.identity }
            return address
        } catch {
            pendingKeys.remove(clientKey)
            try? await rebuildLocked()
            throw error
        }
    }

    /// Stores the paired device. Its key is already on the allowlist.
    public func commitPairing(_ device: DeviceRecord) async throws {
        await acquireGate(); defer { releaseGate() }
        var record = device
        if let existing = try await runtime.store.devices().first(where: { $0.id == device.id }) {
            // saveDevice replaces the whole row; keep when this device was last sent to.
            record.lastSentAt = existing.lastSentAt
        }
        try await runtime.store.saveDevice(record)
        pendingKeys.remove(device.clientPublicKey)
        // Re-pairing a device that had another key leaves the old key admitted: rebuild then.
        if try await Set(allowlist()) != activeAllowlist { try await rebuildLocked() }
    }

    private func allowlist() async throws -> [String] {
        var keys = try await runtime.store.devices().map(\.clientPublicKey)
        keys += pendingKeys.filter { !keys.contains($0) }.sorted()
        return keys
    }

    /// Takes a pairing peer's key off the allowlist again; nothing was stored.
    public func abandonPairing(clientKey: String) async {
        await acquireGate(); defer { releaseGate() }
        guard pendingKeys.remove(clientKey) != nil else { return }
        try? await rebuildLocked()
    }

    /// Deletes the device's key and secret, closes the server, which ends every open
    /// connection, and starts a new one with the remaining keys. With none left, no server
    /// starts. Returns whether a server runs afterwards.
    @discardableResult
    public func unpair(deviceID: String) async throws -> Bool {
        await acquireGate(); defer { releaseGate() }
        guard let device = try await runtime.store.devices().first(where: { $0.id == deviceID }) else {
            throw AgentError.invalidRequest
        }
        try await runtime.store.removeDevice(id: device.id)
        // Sessions this device dialed to the removed one are ended here; inbound ones end
        // with the server below.
        for (key, entry) in sessions where entry.deviceID == device.id && entry.session?.client != nil {
            await entry.session?.close(); sessions[key] = nil
        }
        try await rebuildLocked()
        return await runtime.identityServer.isRunning
    }
}

extension AgentStatus {
    /// The build string this agent reports to peers and in `status`.
    public static var currentBuild: String { AgentStatus(deviceID: "", serverRunning: false, pairedDevices: 0).build }
}
