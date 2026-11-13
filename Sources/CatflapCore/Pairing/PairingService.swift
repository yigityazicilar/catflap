import Crypto
import Foundation
import Synchronization
import Tailcat
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum PairingRole: String, Codable, Sendable { case initiator, joiner }

public struct PairingConfiguration: Sendable {
    /// How long the throwaway server and its code live.
    public var codeLifetime: Duration = .seconds(600)
    /// How long an accepted connection has to deliver its first complete frame.
    public var firstFrameTimeout: Duration = .seconds(10)
    /// The overall dial deadline, shared by up to three attempts.
    public var dialTimeout: Duration = .seconds(30)
    /// How long the joiner waits for the other device's hello.
    public var helloTimeout: Duration = .seconds(30)
    /// How long the joiner waits for both people to confirm. The initiator's limit is the code's.
    public var confirmTimeout: Duration = .seconds(600)
    /// From both confirmations to the stored device.
    public var exchangeTimeout: Duration = .seconds(90)
    public var name: String = PairingConfiguration.defaultName
    public var build: String = AgentStatus.currentBuild
    public var version: Int = WireProtocol.version
    /// Tests only: wraps the pairing tunnel's stream to observe or alter it.
    public var transportHook: (@Sendable (any WireTransport, PairingRole) -> any WireTransport)?
    public init() {}

    public static var defaultName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "Catflap device" }
        let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let short = host.split(separator: ".").first.map(String.init) ?? ""
        return short.isEmpty ? "Catflap device" : short
    }
}

public struct PairingStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case idle, starting, waiting, connecting, confirm, confirmed, exchanging, paired, failed
    }
    public var state: State
    public var role: PairingRole?
    /// The code to carry to the other device, while it is waiting for it.
    public var code: String?
    public var expiresAt: Date?
    /// The six digits to compare, once both hellos crossed.
    public var digits: String?
    public var peerName: String?
    /// The paired device's id, once stored.
    public var deviceID: String?
    public var error: String?
    public init(state: State, role: PairingRole? = nil) { self.state = state; self.role = role }
    enum CodingKeys: String, CodingKey {
        case state, role, code, digits, error
        case expiresAt = "expires_at", peerName = "peer_name", deviceID = "device_id"
    }
    public var isActive: Bool { ![.idle, .paired, .failed].contains(state) }

    // `expires_at` is an ISO-8601 UTC timestamp whatever encoder carries it, the convention for
    // every control payload and `--json` output.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(State.self, forKey: .state)
        role = try values.decodeIfPresent(PairingRole.self, forKey: .role)
        code = try values.decodeIfPresent(String.self, forKey: .code)
        digits = try values.decodeIfPresent(String.self, forKey: .digits)
        peerName = try values.decodeIfPresent(String.self, forKey: .peerName)
        deviceID = try values.decodeIfPresent(String.self, forKey: .deviceID)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        if let text = try values.decodeIfPresent(String.self, forKey: .expiresAt) {
            guard let date = ISO8601DateFormatter().date(from: text) else {
                throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: values, debugDescription: "not an ISO-8601 timestamp")
            }
            expiresAt = date
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        try values.encodeIfPresent(role, forKey: .role)
        try values.encodeIfPresent(code, forKey: .code)
        try values.encodeIfPresent(expiresAt.map { ISO8601DateFormatter().string(from: $0) }, forKey: .expiresAt)
        try values.encodeIfPresent(digits, forKey: .digits)
        try values.encodeIfPresent(peerName, forKey: .peerName)
        try values.encodeIfPresent(deviceID, forKey: .deviceID)
        try values.encodeIfPresent(error, forKey: .error)
    }
}

public enum PairingError: Error, Sendable, Equatable, LocalizedError {
    case busy, invalidCode, nothingToConfirm
    public var errorDescription: String? {
        switch self {
        case .busy: "A pairing is already in progress. Decline it first."
        case .invalidCode: "This is not a Catflap pairing code."
        case .nothingToConfirm: "No pairing is waiting for confirmation."
        }
    }
}

/// Why a pairing ended without a device. Each ends with nothing stored.
enum PairingFailure: Error {
    case expired, declined, peerDeclined, timedOut, connectionLost, codeUsed, unreachable
    case versionMismatch(String), protocolViolation, ownCode
    var message: String {
        switch self {
        case .expired: "The pairing code expired."
        case .declined: "Pairing was declined on this device."
        case .peerDeclined: "Pairing was declined on the other device."
        case .timedOut: "Pairing timed out before both devices confirmed."
        case .connectionLost: "The connection to the other device was lost."
        case .codeUsed: "The pairing code was used by a connection that did not pair. Start again."
        case .unreachable: "Cannot reach the device that made this code. It may have expired or been used."
        case .versionMismatch(let device): "Update Catflap on \(device)"
        case .protocolViolation: "The other device broke the pairing protocol."
        case .ownCode: "This code was made on this device."
        }
    }
}

/// Runs one pairing at a time and keeps its state in the agent, so the command line can start
/// it, poll it, and confirm or decline in separate short requests.
public actor PairingService {
    public nonisolated let runtime: AgentRuntime
    public nonisolated let peers: PeerService
    public private(set) var configuration: PairingConfiguration
    private var status = PairingStatus(state: .idle)
    private var session: UUID?
    private var events: AsyncStream<Event>.Continuation?
    private var throwawayServer: TailcatServer?
    private var joinClient: TailcatClient?
    private var checks: [String: CheckStatus] = [:]

    enum Event: Sendable {
        case local(confirm: Bool)
        case peer(WireFrame?)
        case peerFailed
        case timeout
    }

    public struct CheckStatus: Codable, Sendable, Equatable {
        public var state: String
        public var error: String?
        public init(state: String, error: String? = nil) { self.state = state; self.error = error }
    }

    public init(runtime: AgentRuntime, peers: PeerService, configuration: PairingConfiguration = .init()) {
        self.runtime = runtime; self.peers = peers; self.configuration = configuration
    }

    public func setConfiguration(_ value: PairingConfiguration) { configuration = value }

    public func currentStatus() -> PairingStatus { status }

    // MARK: Starting

    /// Starts a throwaway server and returns its code, or the `starting` state if the server
    /// takes longer than about four seconds; poll `currentStatus()` then.
    public func start() async throws -> PairingStatus {
        guard !status.isActive else { throw PairingError.busy }
        let (id, stream) = begin(.initiator, state: .starting)
        let lifetime = configuration.codeLifetime
        Task.detached { try? await Task.sleep(for: lifetime); await self.expire(id) }
        Task.detached { await self.runInitiator(id, stream, expiry: .now + lifetime) }
        let deadline = ContinuousClock.now + .seconds(4)
        while session == id && status.state == .starting && .now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return status
    }

    /// Joins the device that made `code`. Returns at once; poll `currentStatus()`.
    public func join(code text: String) throws -> PairingStatus {
        guard !status.isActive else { throw PairingError.busy }
        guard let code = PairingCode(text) else { throw PairingError.invalidCode }
        let (id, stream) = begin(.joiner, state: .connecting)
        Task.detached { await self.runJoiner(id, stream, code: code) }
        return status
    }

    public func confirm() throws -> PairingStatus {
        guard [.confirm, .confirmed].contains(status.state), let events else { throw PairingError.nothingToConfirm }
        events.yield(.local(confirm: true))
        return status
    }

    /// Declines the pairing in progress, at any stage before both sides confirmed.
    public func decline() async -> PairingStatus {
        guard let id = session, status.isActive, status.state != .exchanging else { return status }
        events?.yield(.local(confirm: false))
        let early = [.starting, .waiting, .connecting].contains(status.state)
        finish(id, .declined)
        if early { await closeTunnel() }
        return status
    }

    private func begin(_ role: PairingRole, state: PairingStatus.State) -> (UUID, AsyncStream<Event>) {
        let id = UUID()
        session = id
        status = PairingStatus(state: state, role: role)
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        events = continuation
        return (id, stream)
    }

    private func update(_ id: UUID, _ change: (inout PairingStatus) -> Void) {
        guard session == id, status.isActive else { return }
        change(&status)
    }

    private func finish(_ id: UUID, _ failure: PairingFailure) {
        guard session == id, status.isActive else { return }
        status.state = .failed; status.error = failure.message; status.code = nil
    }

    private func expire(_ id: UUID) async {
        guard session == id, status.isActive, status.state != .exchanging else { return }
        events?.yield(.timeout)
        finish(id, .expired)
        await closeTunnel()
    }

    private func closeTunnel() async {
        let server = throwawayServer, client = joinClient
        throwawayServer = nil; joinClient = nil
        await server?.close(); await client?.close()
    }

    private func wrap(_ connection: TailcatConnection, _ role: PairingRole) -> WireConnection {
        WireConnection(configuration.transportHook?(connection, role) ?? connection)
    }

    private func myHello(exchangeKey: Curve25519.KeyAgreement.PrivateKey) async throws -> Data {
        let identity = await runtime.identityServer.identity
        return try WireCodec.header(PairHello(v: configuration.version, deviceID: identity.id, name: configuration.name,
                                              clientKey: identity.clientKeys.publicKey,
                                              exchangeKey: exchangeKey.publicKey.rawRepresentation.base64EncodedString(),
                                              build: configuration.build, nonce: Nonce.make()))
    }

    // MARK: The two roles

    private func runInitiator(_ id: UUID, _ events: AsyncStream<Event>, expiry: ContinuousClock.Instant) async {
        var wire: WireConnection?
        do {
            let joinKeys = try TailcatKeys.generate()
            // The throwaway server admits only the one-time key carried in the code.
            let server = try TailcatServer(config: .init(keys: try TailcatKeys.generate(), allowedClients: [joinKeys.publicKey]))
            guard session == id, status.isActive else { await server.close(); return }
            throwawayServer = server
            let listener = try await server.listen(port: PairingProtocol.port, timeout: .seconds(30))
            let info = try await server.info(timeout: .seconds(10))
            let lifetime = ContinuousClock.now.duration(to: expiry)
            update(id) {
                $0.state = .waiting
                $0.code = PairingCode(address: info.address, clientKey: joinKeys.privateKey).encoded
                $0.expiresAt = Date().addingTimeInterval(Double(lifetime.components.seconds))
            }
            // Accept until one connection delivers bytes. An empty or silent one is not an
            // attempt and does not use the code up.
            var first: WireFrame?
            while first == nil {
                let connection = wrap(try await listener.accept(), .initiator)
                do {
                    first = try await connection.readFrame(deadline: .now + configuration.firstFrameTimeout)
                    if first == nil { await connection.close(); continue }
                    wire = connection
                } catch {
                    guard await connection.receivedAnyByte else { await connection.close(); continue }
                    wire = connection
                    throw PairingFailure.codeUsed
                }
            }
            // This connection used the code: accept no other.
            await listener.close()
            guard let wire, let first else { throw PairingFailure.codeUsed }
            update(id) { $0.code = nil; $0.state = .connecting }
            // The joiner's first frame commits to its hello; versions are compared on it.
            guard first.type == PairCommit.type, let version = try? JSONDecoder().decode(VersionOnly.self, from: first.header) else {
                throw PairingFailure.codeUsed
            }
            if version.v != configuration.version {
                try? await wire.send(Mismatch(v: configuration.version), timeout: .seconds(5))
                await wire.finish()
                throw PairingFailure.versionMismatch("the other device")
            }
            guard let commit = try? first.decode(PairCommit.self), Data(base64Encoded: commit.commit)?.count == 32 else {
                throw PairingFailure.codeUsed
            }
            // Only now does this side reveal its hello, then the joiner reveals its own.
            let exchangeKey = Curve25519.KeyAgreement.PrivateKey()
            let mine = try await myHello(exchangeKey: exchangeKey)
            try await wire.send(header: mine, timeout: .seconds(10))
            let revealed: WireFrame?
            do { revealed = try await wire.readFrame(timeout: configuration.helloTimeout) } catch { throw PairingFailure.connectionLost }
            guard let revealed else { throw PairingFailure.connectionLost }
            // A hello that differs from the commitment is a protocol violation: nothing stored.
            guard revealed.type == PairHello.type, PairingDigits.commitment(hello: revealed.header) == commit.commit,
                  let peer = try? revealed.decode(PairHello.self), peer.isWellFormed, peer.v == configuration.version else {
                throw PairingFailure.protocolViolation
            }
            let transcript = PairingDigits.transcript(joinerHello: revealed.header, initiatorHello: mine)
            try await confirmAndExchange(id, wire, events, role: .initiator, peer: peer, exchangeKey: exchangeKey,
                                         transcript: transcript, readDeadline: expiry)
        } catch {
            await fail(id, error, wire: wire)
        }
        await end(id, wire)
    }

    private func runJoiner(_ id: UUID, _ events: AsyncStream<Event>, code: PairingCode) async {
        var wire: WireConnection?
        do {
            let client = try TailcatClient(address: code.address, key: TailcatKeys(privateKey: code.clientKey, publicKey: "", presharedKey: ""))
            guard session == id, status.isActive else { await client.close(); return }
            joinClient = client
            let connection: TailcatConnection
            do { connection = try await Dialer.dial(client, port: PairingProtocol.port, timeout: configuration.dialTimeout) }
            catch { throw PairingFailure.unreachable }
            let tunnel = wrap(connection, .joiner)
            wire = tunnel
            // Commit to this side's hello first; reveal it only after the initiator's arrived.
            let exchangeKey = Curve25519.KeyAgreement.PrivateKey()
            let mine = try await myHello(exchangeKey: exchangeKey)
            try await tunnel.send(PairCommit(v: configuration.version, commit: PairingDigits.commitment(hello: mine)),
                                  timeout: .seconds(10))
            let answer: WireFrame?
            do { answer = try await tunnel.readFrame(timeout: configuration.helloTimeout) } catch { throw PairingFailure.unreachable }
            guard let answer else { throw PairingFailure.unreachable }
            if answer.type == Mismatch.type { throw PairingFailure.versionMismatch("the other device") }
            guard let peer = try? answer.decode(PairHello.self), peer.isWellFormed else { throw PairingFailure.protocolViolation }
            if peer.v != configuration.version { throw PairingFailure.versionMismatch(peer.name) }
            try await tunnel.send(header: mine, timeout: .seconds(10))
            let transcript = PairingDigits.transcript(joinerHello: mine, initiatorHello: answer.header)
            let limit = configuration.confirmTimeout
            Task.detached { try? await Task.sleep(for: limit); await self.timeOut(id) }
            try await confirmAndExchange(id, tunnel, events, role: .joiner, peer: peer, exchangeKey: exchangeKey,
                                         transcript: transcript, readDeadline: .now + limit)
        } catch {
            await fail(id, error, wire: wire)
        }
        await end(id, wire)
    }

    private func timeOut(_ id: UUID) {
        guard session == id, status.isActive else { return }
        events?.yield(.timeout)
    }

    // MARK: Confirmation and exchange

    private func confirmAndExchange(_ id: UUID, _ wire: WireConnection, _ events: AsyncStream<Event>, role: PairingRole,
                                    peer: PairHello, exchangeKey: Curve25519.KeyAgreement.PrivateKey, transcript: Data,
                                    readDeadline: ContinuousClock.Instant) async throws {
        let identity = await runtime.identityServer.identity
        guard peer.deviceID != identity.id else { throw PairingFailure.ownCode }
        guard session == id, status.isActive else { throw PairingFailure.declined }
        // The exchange key's private half lives only here, in memory, for this pairing.
        let shared: Data
        do { shared = try PairingSeal.sharedSecret(exchangeKey, peerKey: peer.exchangeKey) }
        catch { throw PairingFailure.protocolViolation }
        let peerRole: PairingRole = role == .initiator ? .joiner : .initiator
        update(id) {
            $0.state = .confirm; $0.code = nil
            $0.digits = PairingDigits.digits(transcript: transcript); $0.peerName = peer.name
        }
        let continuation = self.events
        let reader = Task {
            do {
                while true {
                    let frame = try await wire.readFrame(deadline: readDeadline)
                    continuation?.yield(.peer(frame))
                    if frame == nil { return }
                }
            } catch WireError.timedOut {
                // The read deadline is the confirmation limit itself.
                continuation?.yield(.timeout)
            } catch { continuation?.yield(.peerFailed) }
        }
        defer { reader.cancel() }

        var localConfirmed = false, peerConfirmed = false
        var opened: (address: String, share: Data)?
        var peerDone = false, doneSent = false
        var myShare: Data?
        var pendingKey: String?
        do {
            for await event in events {
                switch event {
                case .local(confirm: false):
                    try? await wire.send(PairDecline(), timeout: .seconds(5))
                    throw PairingFailure.declined
                case .local(confirm: true):
                    guard !localConfirmed else { break }
                    localConfirmed = true
                    try await wire.send(PairConfirm(), timeout: .seconds(10))
                    if !peerConfirmed { update(id) { $0.state = .confirmed } }
                case .peer(let frame?):
                    switch frame.type {
                    case PairConfirm.type where !peerConfirmed: peerConfirmed = true
                    case PairDecline.type: throw PairingFailure.peerDeclined
                    // Permanent material is accepted only after both sides confirmed, and only
                    // sealed to this pairing's exchange.
                    case PairKeys.type where localConfirmed && peerConfirmed && opened == nil:
                        guard let keys = try? frame.decode(PairKeys.self),
                              let contents = try? PairingSeal.open(keys.box, shared: shared, transcript: transcript,
                                                                   sealedBy: peerRole) else {
                            // Tell the peer, so it does not store either.
                            try? await wire.send(PairDecline(), timeout: .seconds(5))
                            throw PairingFailure.protocolViolation
                        }
                        opened = contents
                    case PairDone.type where opened != nil && !peerDone: peerDone = true
                    default: throw PairingFailure.protocolViolation
                    }
                case .peer(nil), .peerFailed:
                    throw PairingFailure.connectionLost
                case .timeout:
                    try? await wire.send(PairDecline(), timeout: .seconds(2))
                    throw PairingFailure.timedOut
                }
                if localConfirmed && peerConfirmed && myShare == nil {
                    // A decline that raced the peer's confirmation wins: nothing is sent.
                    guard session == id, status.isActive else { throw PairingFailure.declined }
                    // Both confirmed. Add the peer's client key, rebuild the permanent server
                    // with it, read the address, then send it sealed.
                    update(id) { $0.state = .exchanging }
                    let limit = configuration.exchangeTimeout
                    Task.detached { try? await Task.sleep(for: limit); await self.timeOut(id) }
                    pendingKey = peer.clientKey
                    let address = try await peers.preparePairing(clientKey: peer.clientKey)
                    guard session == id, status.isActive else { throw PairingFailure.declined }
                    let share = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    myShare = share
                    let box = try PairingSeal.seal(address: address, share: share, shared: shared, transcript: transcript,
                                                   sealedBy: role)
                    try await wire.send(PairKeys(box: box), timeout: .seconds(30))
                }
                if myShare != nil, opened != nil, !doneSent {
                    doneSent = true
                    try await wire.send(PairDone(), timeout: .seconds(10))
                }
                if let myShare, let opened, doneSent, peerDone {
                    let secret = role == .initiator
                        ? PairingDigits.pairSecret(transcript: transcript, shared: shared, initiatorShare: myShare, joinerShare: opened.share)
                        : PairingDigits.pairSecret(transcript: transcript, shared: shared, initiatorShare: opened.share, joinerShare: myShare)
                    guard session == id, status.isActive else { throw PairingFailure.declined }
                    try await peers.commitPairing(DeviceRecord(id: peer.deviceID, name: peer.name, clientPublicKey: peer.clientKey,
                                                               address: opened.address, pairSecret: secret, build: peer.build))
                    pendingKey = nil
                    update(id) { $0.state = .paired; $0.deviceID = peer.deviceID }
                    // Let the peer read everything before the tunnel closes: wait for its end.
                    await wire.closeWrite()
                    let drained = Task<Void, Error> { await reader.value }
                    _ = await awaitAtMost(.seconds(5), drained)
                    return
                }
            }
            throw PairingFailure.connectionLost
        } catch {
            // Show the failure at once; then take back any key added for the exchange.
            await fail(id, error, wire: wire)
            if let pendingKey { await peers.abandonPairing(clientKey: pendingKey) }
            // Let a last decline reach the peer before the tunnel closes: wait for its end, also
            // when this side's reader has already stopped (it stops at a read timeout).
            await wire.closeWrite()
            let drained = Task<Void, Error> { await reader.value }
            _ = await awaitAtMost(.seconds(3), drained)
            reader.cancel()
            await wire.finish(timeout: .seconds(3))
            throw error
        }
    }

    private func fail(_ id: UUID, _ error: Error, wire: WireConnection?) async {
        if let failure = error as? PairingFailure { finish(id, failure) }
        else if error is PairingError { finish(id, .protocolViolation) }
        else { finish(id, status.role == .joiner ? .unreachable : .connectionLost) }
    }

    private func end(_ id: UUID, _ wire: WireConnection?) async {
        await wire?.close()
        guard session == id else { return }
        if status.isActive { finish(id, .connectionLost) }
        events?.finish(); events = nil
        await closeTunnel()
    }

    // MARK: Connection check

    /// Starts an Open step to `deviceID` in the background; poll with `checkStatus`.
    public func startCheck(deviceID: String) -> CheckStatus {
        if checks[deviceID]?.state == "running" { return checks[deviceID]! }
        checks[deviceID] = CheckStatus(state: "running")
        Task {
            let result: CheckStatus
            do {
                let session = try await peers.open(deviceID: deviceID, timeout: configuration.dialTimeout)
                await peers.release(session)
                result = CheckStatus(state: "ok")
            } catch {
                result = CheckStatus(state: "failed", error: (error as? LocalizedError)?.errorDescription ?? "Check failed.")
            }
            self.checks[deviceID] = result
        }
        return checks[deviceID]!
    }

    public func checkStatus(deviceID: String) -> CheckStatus? { checks[deviceID] }
}

private final class OnceFlag: Sendable {
    private let claimed = Mutex(false)
    func claim() -> Bool { claimed.withLock { value in defer { value = true }; return !value } }
}

/// Waits for `task` at most `limit`; nil if it is still running then. The task goes on.
func awaitAtMost<T: Sendable>(_ limit: Duration, _ task: Task<T, Error>) async -> Result<T, Error>? {
    await withCheckedContinuation { continuation in
        let once = OnceFlag()
        Task {
            let result = await task.result
            if once.claim() { continuation.resume(returning: result) }
        }
        Task {
            try? await Task.sleep(for: limit)
            if once.claim() { continuation.resume(returning: nil) }
        }
    }
}
