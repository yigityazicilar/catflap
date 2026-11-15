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
        let outcome = await PeerOpen.accept(connection, localID: localID, version: version, build: build, mismatched: { [weak self] id, peerVersion in
            await self?.noteMismatch(deviceID: id, peerVersion: peerVersion)
        }) { id in
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
        // An authenticated session from it proves it admits this device.
        await noteContact(device.id)
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
        let session: PeerSession
        do { session = try await PeerOpen.dial(device, identity: identity, build: build, version: version, timeout: timeout) }
        catch let error as PeerError {
            switch error {
            case .updateNeeded: await setPeerState(device.id, "update_peer")
            case .updateThisDevice: await setPeerState(device.id, "update_this_device")
            case .wrongDevice: await setPeerState(device.id, "wrong_device")
            case .unreachable:
                // A device that never showed it admits this one may not have this pairing.
                if await !isConfirmed(device.id) { throw PeerError.unreachableUnconfirmed(device: device.name) }
            default: break
            }
            throw error
        }
        sessions[session.id] = (device.id, session, session.connection)
        await noteContact(device.id)
        return session
    }

    /// Called when another part of the agent heard from a device: a presence check it answered.
    /// That makes its waiting items due. It does not confirm a new pairing (a pending key is
    /// answered too), so an unconfirmed one is checked with an authenticated Open.
    public func answered(deviceID: String) async {
        await contactHandler?(deviceID)
        if await !isConfirmed(deviceID) { Task { _ = await self.confirm(deviceID: deviceID) } }
    }

    /// Confirms a pairing with proof only a stored pairing gives: an Open authenticated with the
    /// pair secret both ways. A ping is not enough, because the other server answers a key it
    /// holds pending during an exchange it may never finish. True when confirmed.
    public func confirm(deviceID: String, timeout: Duration = .seconds(10)) async -> Bool {
        if await isConfirmed(deviceID) { return true }
        if let session = try? await open(deviceID: deviceID, timeout: timeout) { await release(session) }
        return await isConfirmed(deviceID)
    }

    /// Pings a paired device through a client of this device's, bounded by `timeout`. An
    /// answer proves its server admits this device. Only "direct" or the relay region leaves
    /// here, never an endpoint.
    public func ping(deviceID: String, timeout: Duration) async throws -> PeerPing {
        guard let device = try await runtime.store.devices().first(where: { $0.id == deviceID }) else {
            throw PeerError.refused(device: deviceID)
        }
        let unreachable = PeerError.unreachable(device: device.name, lastSeenBuild: device.build)
        let identity = await runtime.identityServer.identity
        let client: TailcatClient
        do { client = try TailcatClient(address: device.address, key: identity.clientKeys) } catch { throw unreachable }
        let result: TailcatPing
        do { result = try await client.ping(timeout: timeout) }
        catch {
            // `tc_close` has no deadline: the client goes off the caller's path.
            Task.detached { await client.close() }
            if error is CancellationError { throw error }
            if let error = error as? TailcatError, error.code == .cancelled { throw CancellationError() }
            throw unreachable
        }
        Task.detached { await client.close() }
        // An answer makes waiting items due; it proves the key is admitted, not that the other
        // side stored this pairing, so it confirms nothing.
        await contactHandler?(device.id)
        let path: PeerPath
        switch result.path {
        case .direct: path = .direct
        case .relayed(_, let code): path = .relayed(regionCode: code)
        }
        return PeerPing(latency: .milliseconds(Int64((result.latency * 1000).rounded())), path: path)
    }

    // MARK: What this device knows of each peer

    public typealias ContactHandler = @Sendable (_ deviceID: String) async -> Void
    private var contactHandler: ContactHandler?
    /// Called whenever a device answered: an authenticated session either way, or a ping.
    public func setContactHandler(_ handler: ContactHandler?) { contactHandler = handler }

    /// The peer state and confirmation of each device that has a row; others are `ok` and
    /// confirmed.
    public func deviceStates() async -> [String: (peerState: String, confirmed: Bool)] {
        let rows = (try? await runtime.store.query("SELECT device_id, peer_state, confirmed FROM device_state")) ?? []
        var states: [String: (String, Bool)] = [:]
        for row in rows {
            guard case .text(let id) = row["device_id"], case .text(let state) = row["peer_state"], case .integer(let confirmed) = row["confirmed"] else { continue }
            states[id] = (state, confirmed != 0)
        }
        return states
    }
    func isConfirmed(_ deviceID: String) async -> Bool {
        await deviceStates()[deviceID]?.confirmed ?? true
    }
    /// An authenticated session, either way: the only proof that confirms a pairing, because
    /// each side authenticates with the pair secret it has stored.
    func noteContact(_ deviceID: String) async {
        try? await runtime.store.execute("""
        INSERT INTO device_state(device_id, peer_state, confirmed, changed_at) SELECT ?, 'ok', 1, ? WHERE EXISTS (SELECT 1 FROM devices WHERE id=?)
        ON CONFLICT(device_id) DO UPDATE SET confirmed=1, peer_state='ok', changed_at=excluded.changed_at
        """, bindings: [.text(deviceID), .real(Date().timeIntervalSince1970), .text(deviceID)])
        await contactHandler?(deviceID)
    }
    private func setPeerState(_ deviceID: String, _ state: String) async {
        try? await runtime.store.execute("""
        INSERT INTO device_state(device_id, peer_state, changed_at) SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM devices WHERE id=?)
        ON CONFLICT(device_id) DO UPDATE SET peer_state=excluded.peer_state, changed_at=excluded.changed_at
        """, bindings: [.text(deviceID), .text(state), .real(Date().timeIntervalSince1970), .text(deviceID)])
    }
    /// A hello of another version named a paired device. Unauthenticated, so it only drives
    /// the hint `devices` shows; it never changes or deletes a pairing.
    private func noteMismatch(deviceID: String, peerVersion: Int) async {
        await setPeerState(deviceID, peerVersion < version ? "update_peer" : "update_this_device")
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
        // Stored here; until the other device shows it admits this one, the pairing may have
        // finished on this side only.
        try await runtime.store.execute("""
        INSERT INTO device_state(device_id, peer_state, confirmed, changed_at) VALUES (?, 'ok', 0, ?)
        ON CONFLICT(device_id) DO UPDATE SET peer_state='ok', confirmed=0, changed_at=excluded.changed_at
        """, bindings: [.text(record.id), .real(Date().timeIntervalSince1970)])
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
