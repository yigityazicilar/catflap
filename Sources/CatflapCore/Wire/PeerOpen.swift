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
}
public struct Auth: WireMessage {
    public static let type = "auth"
    public var hmac: String
}
public struct OK: WireMessage {
    public static let type = "ok"
    public init() {}
}
public struct Mismatch: WireMessage {
    public static let type = "mismatch"
    public var v: Int
    public init(v: Int) { self.v = v }
}
/// Only the version, read before anything else so a peer of another version is recognised
/// even when the rest of its hello has changed shape.
struct VersionOnly: Decodable { let v: Int }

/// Messages a person reads when a peer cannot be used.
public enum PeerError: Error, Sendable, Equatable, LocalizedError {
    /// The tunnel works but the peer speaks another protocol version.
    case updateNeeded(device: String)
    /// No tunnel formed, so no version could be read.
    case unreachable(device: String, lastSeenBuild: String)
    /// The peer answered but did not accept this device's proof.
    case refused(device: String)

    public var errorDescription: String? {
        switch self {
        case .updateNeeded(let device): "Update Catflap on \(device)"
        case .unreachable(let device, let build):
            "Cannot reach \(device): asleep, offline, or on an older Catflap (last seen on build \(build))"
        case .refused(let device): "\(device) no longer accepts this device. Pair again."
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
    /// HMAC over both fresh nonces, bound to who dialed whom.
    public static func mac(secret: Data, dialer: String, accepter: String, helloNonce: String, challengeNonce: String) -> Data {
        let message = input(dialer: dialer, accepter: accepter, helloNonce: helloNonce, challengeNonce: challengeNonce)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }
    static func verify(_ mac: Data, secret: Data, dialer: String, accepter: String, helloNonce: String, challengeNonce: String) -> Bool {
        let message = input(dialer: dialer, accepter: accepter, helloNonce: helloNonce, challengeNonce: challengeNonce)
        // Constant-time comparison.
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: SymmetricKey(data: secret))
    }
    private static func input(dialer: String, accepter: String, helloNonce: String, challengeNonce: String) -> Data {
        var message = Data("catflap-open-v2".utf8)
        for part in [dialer, accepter, helloNonce, challengeNonce] {
            message.append(0)
            message.append(Data(part.utf8))
        }
        return message
    }
}

/// Dials with a finite timeout. A dial that times out is retried, at most three attempts in
/// all, inside one overall deadline, so an unreachable peer still fails within `timeout`.
public enum Dialer {
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
    let client: TailcatClient?
    public let id = UUID()

    init(device: DeviceRecord, connection: WireConnection, client: TailcatClient?) {
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
        let connection: WireConnection
        do { connection = WireConnection(try await Dialer.dial(client, port: port, timeout: timeout)) }
        catch is CancellationError { await client.close(); throw CancellationError() }
        catch let error as TailcatError where error.code == .cancelled { await client.close(); throw CancellationError() }
        catch { await client.close(); throw unreachable }
        do {
            let hello = Hello(v: version, deviceID: identity.id, build: build, nonce: Nonce.make())
            try await connection.send(hello)
            let deadline = ContinuousClock.now + handshakeTimeout
            guard let first = try await connection.readFrame(deadline: deadline) else { throw unreachable }
            if first.type == Mismatch.type { throw PeerError.updateNeeded(device: device.name) }
            let challenge = try first.decode(Challenge.self)
            guard Nonce.isValid(challenge.nonce) else { throw unreachable }
            let mac = OpenAuth.mac(secret: device.pairSecret, dialer: identity.id, accepter: device.id,
                                   helloNonce: hello.nonce, challengeNonce: challenge.nonce)
            try await connection.send(Auth(hmac: mac.base64EncodedString()))
            guard let answer = try await connection.readFrame(deadline: ContinuousClock.now + handshakeTimeout),
                  answer.type == OK.type else { throw PeerError.refused(device: device.name) }
            return PeerSession(device: device, connection: connection, client: client)
        } catch {
            await connection.close(); await client.close()
            if let error = error as? PeerError { throw error }
            if error is CancellationError { throw error }
            throw unreachable
        }
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
    public static func accept(_ connection: WireConnection, localID: String, version: Int = WireProtocol.version,
                              firstFrame: Duration = .seconds(10),
                              lookup: @Sendable (String) async -> DeviceRecord?) async -> Outcome {
        let frame: WireFrame?
        do { frame = try await connection.readFrame(deadline: .now + firstFrame) }
        catch { return await connection.receivedAnyByte ? .rejected : .empty }
        guard let frame else { return await connection.receivedAnyByte ? .rejected : .empty }
        guard frame.type == Hello.type, let peerVersion = try? JSONDecoder().decode(VersionOnly.self, from: frame.header) else {
            return .rejected
        }
        if peerVersion.v != version {
            try? await connection.send(Mismatch(v: version), timeout: .seconds(5))
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
            try await connection.send(OK(), timeout: .seconds(10))
            return .authenticated(device, hello)
        } catch { return .rejected }
    }
}
