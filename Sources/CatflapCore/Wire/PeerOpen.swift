import Crypto
import Foundation
import Tailcat

/// The Open step's frames: `hello` → `challenge` → `auth` → `ok`, or `mismatch` and close.
public struct Hello: WireMessage, Equatable {
    public static let type = "hello"
    public var v: Int
    public var deviceID: String
    public var build: String
    public var nonce: String
    public init(v: Int, deviceID: String, build: String, nonce: String) {
        self.v = v; self.deviceID = deviceID; self.build = build; self.nonce = nonce
    }
    enum CodingKeys: String, CodingKey { case v, build, nonce, deviceID = "device_id" }
}
public struct Challenge: WireMessage {
    public static let type = "challenge"
    public var nonce: String
    public init(nonce: String) { self.nonce = nonce }
}
public struct Auth: WireMessage {
    public static let type = "auth"
    public var hmac: String
    public init(hmac: String) { self.hmac = hmac }
}
/// The accepter's answer to a good proof, with its own proof: only the device that holds
/// this pair's secret can make it, so a dialer never hands a transfer to another device.
public struct OK: WireMessage {
    public static let type = "ok"
    public var hmac: String
    public init(hmac: String = "") { self.hmac = hmac }
}
public struct Mismatch: WireMessage {
    public static let type = "mismatch"
    public var v: Int
    public var build: String
    public init(v: Int, build: String = AgentStatus.currentBuild) { self.v = v; self.build = build }
}
/// Only the version, read before anything else so a peer of another version is recognised
/// even when the rest of its hello has changed shape.
struct VersionOnly: Decodable { let v: Int }
/// The id from a hello of another version, if it has one, for the hint `devices` shows.
private struct DeviceIDOnly: Decodable {
    let deviceID: String
    enum CodingKeys: String, CodingKey { case deviceID = "device_id" }
}

/// Messages a person reads when a peer cannot be used.
public enum PeerError: Error, Sendable, Equatable, LocalizedError {
    /// The tunnel works but the peer speaks an older protocol version.
    case updateNeeded(device: String)
    /// No tunnel formed, so no version could be read.
    case unreachable(device: String, lastSeenBuild: String)
    /// The peer answered but did not accept this device's proof.
    case refused(device: String)
    /// The peer speaks a newer protocol version: this device is the one to update.
    case updateThisDevice(device: String)
    /// The device at the stored address could not prove it holds this pair's secret.
    case wrongDevice(device: String)
    /// No tunnel formed to a device that has never shown it admits this one: the pairing may
    /// have finished on this side only.
    case unreachableUnconfirmed(device: String)

    public var errorDescription: String? {
        switch self {
        case .updateNeeded(let device): "Update Catflap on \(device)"
        case .unreachable(let device, let build):
            "Cannot reach \(device): asleep, offline, or on an older Catflap (last seen on build \(build))"
        case .refused(let device): "\(device) no longer accepts this device. Pair again."
        case .updateThisDevice(let device): "Update Catflap on this device: \(device) runs a newer Catflap"
        case .wrongDevice(let device): "The device at \(device)'s address is not \(device). Pair again."
        case .unreachableUnconfirmed(let device):
            "Cannot reach \(device). If it does not list this device, the pairing finished on one side only: pair again."
        }
    }
}

public enum Nonce {
    public static func make() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }
    static func isValid(_ nonce: String) -> Bool {
        nonce.utf8.count <= 64 && Data(base64Encoded: nonce)?.count == 32
    }
}

public enum OpenAuth {
    static let authLabel = "catflap-open-v3"
    static let okLabel = "catflap-open-v3-ok"
    /// HMAC over both fresh nonces, bound to who dialed whom.
    public static func mac(secret: Data, dialer: String, accepter: String, helloNonce: String, challengeNonce: String) -> Data {
        code(authLabel, secret: secret, dialer: dialer, accepter: accepter, helloNonce: helloNonce, challengeNonce: challengeNonce)
    }
    /// The accepter's proof in `ok`. Its own label keeps it from ever passing for an `auth`.
    public static func okMac(secret: Data, dialer: String, accepter: String, helloNonce: String, challengeNonce: String) -> Data {
        code(okLabel, secret: secret, dialer: dialer, accepter: accepter, helloNonce: helloNonce, challengeNonce: challengeNonce)
    }
    static func verify(_ mac: Data, secret: Data, dialer: String, accepter: String, helloNonce: String, challengeNonce: String) -> Bool {
        check(mac, authLabel, secret: secret, dialer: dialer, accepter: accepter, helloNonce: helloNonce, challengeNonce: challengeNonce)
    }
    static func verifyOK(_ mac: Data, secret: Data, dialer: String, accepter: String, helloNonce: String, challengeNonce: String) -> Bool {
        check(mac, okLabel, secret: secret, dialer: dialer, accepter: accepter, helloNonce: helloNonce, challengeNonce: challengeNonce)
    }
    private static func code(_ label: String, secret: Data, dialer: String, accepter: String, helloNonce: String, challengeNonce: String) -> Data {
        let message = input(label, dialer: dialer, accepter: accepter, helloNonce: helloNonce, challengeNonce: challengeNonce)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }
    private static func check(_ mac: Data, _ label: String, secret: Data, dialer: String, accepter: String, helloNonce: String, challengeNonce: String) -> Bool {
        let message = input(label, dialer: dialer, accepter: accepter, helloNonce: helloNonce, challengeNonce: challengeNonce)
        // Constant-time comparison.
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: SymmetricKey(data: secret))
    }
    private static func input(_ label: String, dialer: String, accepter: String, helloNonce: String, challengeNonce: String) -> Data {
        var message = Data(label.utf8)
        for part in [dialer, accepter, helloNonce, challengeNonce] {
            message.append(0)
            message.append(Data(part.utf8))
        }
        return message
    }
}

/// The client side of a dial: a tailcat client in the agent. Tests pass their own to control
/// how a dial and the client's teardown behave.
public protocol PeerDialClient: Sendable {
    func dialTransport(port: UInt16, timeout: Duration?) async throws -> any WireTransport
    func close() async
}
extension TailcatClient: PeerDialClient {
    public func dialTransport(port: UInt16, timeout: Duration?) async throws -> any WireTransport {
        try await dial(port: port, timeout: timeout)
    }
}

/// Dials with a finite timeout. A dial that times out is retried, at most three attempts in
/// all, inside one overall deadline, so an unreachable peer still fails within `timeout`.
public enum Dialer {
    public static func dialTransport(_ client: any PeerDialClient, port: UInt16, timeout: Duration, attempts: Int = 3) async throws -> any WireTransport {
        let deadline = ContinuousClock.now + timeout
        var left = attempts
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw WireError.timedOut }
            do {
                return try await client.dialTransport(port: port, timeout: remaining / left)
            } catch let error as TailcatError where error.code == .timeout {
                left -= 1
                if left == 0 { throw error }
            }
        }
    }
    public static func dial(_ client: TailcatClient, port: UInt16, timeout: Duration, attempts: Int = 3) async throws -> TailcatConnection {
        let deadline = ContinuousClock.now + timeout
        var left = attempts
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw WireError.timedOut }
            do {
                return try await client.dial(port: port, timeout: remaining / left)
            } catch let error as TailcatError where error.code == .timeout {
                left -= 1
                if left == 0 { throw error }
            }
        }
    }
}

/// An authenticated connection to or from a paired device.
public final class PeerSession: Sendable {
    public let device: DeviceRecord
    public let connection: WireConnection
    /// Set on sessions this device dialed: the client owns the connection.
    let client: (any PeerDialClient)?
    public let id = UUID()

    init(device: DeviceRecord, connection: WireConnection, client: (any PeerDialClient)?) {
        self.device = device; self.connection = connection; self.client = client
    }

    public func close() async {
        await connection.close()
        await client?.close()
    }
}

public enum PeerOpen {
    public static let handshakeTimeout: Duration = .seconds(10)

    /// Dials `device` and runs the Open step as the dialing side.
    public static func dial(_ device: DeviceRecord, identity: DeviceIdentity, build: String,
                            version: Int = WireProtocol.version, port: UInt16 = WireProtocol.port,
                            timeout: Duration = .seconds(30)) async throws -> PeerSession {
        let unreachable = PeerError.unreachable(device: device.name, lastSeenBuild: device.build)
        let client: TailcatClient
        do { client = try TailcatClient(address: device.address, key: identity.clientKeys) } catch { throw unreachable }
        return try await dial(device, identity: identity, build: build, version: version, port: port, timeout: timeout, client: client)
    }

    /// The same, over a client the caller made. Only `timeout` and the handshake's own
    /// deadline stand between the call and its outcome: a failed attempt's client is torn
    /// down off the caller's path, because `tc_close` of a started client has no deadline.
    public static func dial(_ device: DeviceRecord, identity: DeviceIdentity, build: String,
                            version: Int = WireProtocol.version, port: UInt16 = WireProtocol.port,
                            timeout: Duration = .seconds(30), client: any PeerDialClient) async throws -> PeerSession {
        let unreachable = PeerError.unreachable(device: device.name, lastSeenBuild: device.build)
        let connection: WireConnection
        do { connection = WireConnection(try await Dialer.dialTransport(client, port: port, timeout: timeout)) }
        catch is CancellationError { teardown(client); throw CancellationError() }
        catch let error as TailcatError where error.code == .cancelled { teardown(client); throw CancellationError() }
        catch { teardown(client); throw unreachable }
        do {
            let hello = Hello(v: version, deviceID: identity.id, build: build, nonce: Nonce.make())
            try await connection.send(hello)
            let deadline = ContinuousClock.now + handshakeTimeout
            guard let first = try await connection.readFrame(deadline: deadline) else { throw unreachable }
            if first.type == Mismatch.type {
                // The message names the side to update.
                let peer = (try? JSONDecoder().decode(VersionOnly.self, from: first.header))?.v ?? 0
                throw peer > version ? PeerError.updateThisDevice(device: device.name) : PeerError.updateNeeded(device: device.name)
            }
            let challenge = try first.decode(Challenge.self)
            guard Nonce.isValid(challenge.nonce) else { throw unreachable }
            let mac = OpenAuth.mac(secret: device.pairSecret, dialer: identity.id, accepter: device.id,
                                   helloNonce: hello.nonce, challengeNonce: challenge.nonce)
            try await connection.send(Auth(hmac: mac.base64EncodedString()))
            guard let answer = try await connection.readFrame(deadline: ContinuousClock.now + handshakeTimeout),
                  answer.type == OK.type else { throw PeerError.refused(device: device.name) }
            // Nothing is sent on this connection until the other side proved it is the device.
            guard let ok = try? answer.decode(OK.self), let proof = Data(base64Encoded: ok.hmac),
                  OpenAuth.verifyOK(proof, secret: device.pairSecret, dialer: identity.id, accepter: device.id,
                                    helloNonce: hello.nonce, challengeNonce: challenge.nonce) else {
                throw PeerError.wrongDevice(device: device.name)
            }
            return PeerSession(device: device, connection: connection, client: client)
        } catch {
            await connection.close(); teardown(client)
            if let error = error as? PeerError { throw error }
            if error is CancellationError { throw error }
            throw unreachable
        }
    }

    /// Closes a client that is no longer needed without waiting for it.
    private static func teardown(_ client: any PeerDialClient) {
        Task.detached { await client.close() }
    }

    public enum Outcome: Sendable {
        /// Ended or stayed silent without one byte: not an attempt, dropped quietly.
        case empty
        /// Answered with `mismatch`, or closed for a bad hello or proof.
        case rejected
        case authenticated(DeviceRecord, Hello)
    }

    /// Runs the Open step as the accepting side. It reads first and writes nothing until a
    /// valid `hello` has arrived; the first frame must arrive within `firstFrame`.
    /// `mismatched` hears of a hello of another version that names a device id, unverified.
    public static func accept(_ connection: WireConnection, localID: String, version: Int = WireProtocol.version,
                              build: String = AgentStatus.currentBuild, firstFrame: Duration = .seconds(10),
                              mismatched: (@Sendable (_ deviceID: String, _ peerVersion: Int) async -> Void)? = nil,
                              lookup: @Sendable (String) async -> DeviceRecord?) async -> Outcome {
        let frame: WireFrame?
        do { frame = try await connection.readFrame(deadline: .now + firstFrame) }
        catch { return await connection.receivedAnyByte ? .rejected : .empty }
        guard let frame else { return await connection.receivedAnyByte ? .rejected : .empty }
        guard frame.type == Hello.type, let peerVersion = try? JSONDecoder().decode(VersionOnly.self, from: frame.header) else {
            return .rejected
        }
        if peerVersion.v != version {
            // Noted before the reply, so the state is stored by the time the other side knows.
            if let mismatched, let named = try? JSONDecoder().decode(DeviceIDOnly.self, from: frame.header), named.deviceID.utf8.count <= 128 {
                await mismatched(named.deviceID, peerVersion.v)
            }
            try? await connection.send(Mismatch(v: version, build: build), timeout: .seconds(5))
            await connection.finish()
            return .rejected
        }
        guard let hello = try? frame.decode(Hello.self), Nonce.isValid(hello.nonce), hello.build.utf8.count <= 128,
              let device = await lookup(hello.deviceID) else { return .rejected }
        let challenge = Challenge(nonce: Nonce.make())
        do {
            try await connection.send(challenge, timeout: .seconds(10))
            guard let answer = try await connection.readFrame(deadline: .now + handshakeTimeout) else { return .rejected }
            let auth = try answer.decode(Auth.self)
            guard let mac = Data(base64Encoded: auth.hmac),
                  OpenAuth.verify(mac, secret: device.pairSecret, dialer: hello.deviceID, accepter: localID,
                                  helloNonce: hello.nonce, challengeNonce: challenge.nonce) else { return .rejected }
            let proof = OpenAuth.okMac(secret: device.pairSecret, dialer: hello.deviceID, accepter: localID,
                                       helloNonce: hello.nonce, challengeNonce: challenge.nonce)
            try await connection.send(OK(hmac: proof.base64EncodedString()), timeout: .seconds(10))
            return .authenticated(device, hello)
        } catch { return .rejected }
    }
}
