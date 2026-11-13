import Crypto
import Foundation

public enum PairingProtocol {
    /// The TCP port inside the throwaway pairing tunnel.
    public static let port: UInt16 = 7448
}

/// The one-time pairing code: the throwaway server's address and the one-time client key that
/// server admits. A server never runs with an empty allowlist, so the code has to carry a key
/// the server lists. Both are secrets; the description never shows them.
public struct PairingCode: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let address: String
    public let clientKey: String
    static let prefix = "catflap-pair-1."
    private struct Body: Codable { var a: String; var k: String }

    public init(address: String, clientKey: String) { self.address = address; self.clientKey = clientKey }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix), trimmed.utf8.count <= 16 * 1024 else { return nil }
        var encoded = String(trimmed.dropFirst(Self.prefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.utf8.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded), let body = try? JSONDecoder().decode(Body.self, from: data),
              !body.a.isEmpty, !body.k.isEmpty else { return nil }
        address = body.a; clientKey = body.k
    }

    public var encoded: String {
        let data = (try? JSONEncoder().encode(Body(a: address, k: clientKey))) ?? Data()
        let text = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.prefix + text
    }

    public var description: String { "PairingCode(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Public material only: what the two devices swap before anyone confirms.
public struct PairHello: WireMessage, Equatable {
    public static let type = "pair_hello"
    public var v: Int
    public var deviceID: String
    public var name: String
    public var clientKey: String
    /// A fresh X25519 public key made for this pairing only (raw, base64).
    public var exchangeKey: String
    public var build: String
    public var nonce: String
    public init(v: Int, deviceID: String, name: String, clientKey: String, exchangeKey: String, build: String, nonce: String) {
        self.v = v; self.deviceID = deviceID; self.name = name; self.clientKey = clientKey
        self.exchangeKey = exchangeKey; self.build = build; self.nonce = nonce
    }
    enum CodingKeys: String, CodingKey {
        case v, name, build, nonce
        case deviceID = "device_id", clientKey = "client_key", exchangeKey = "exchange_key"
    }
    var isWellFormed: Bool {
        !deviceID.isEmpty && deviceID.utf8.count <= 128 && !name.isEmpty && name.utf8.count <= 256
            && !clientKey.isEmpty && clientKey.utf8.count <= 256 && build.utf8.count <= 128 && Nonce.isValid(nonce)
            && exchangeKey.utf8.count <= 64 && Data(base64Encoded: exchangeKey)?.count == 32
    }
}
/// The joiner's first frame: a commitment to the hello it reveals only after it has the
/// initiator's. A machine in the middle must fix its hello before seeing either real one, so
/// it cannot search for a hello that gives both devices the same digits.
public struct PairCommit: WireMessage {
    public static let type = "pair_commit"
    public var v: Int
    public var commit: String
    public init(v: Int, commit: String) { self.v = v; self.commit = commit }
}
public struct PairConfirm: WireMessage { public static let type = "confirm"; public init() {} }
public struct PairDecline: WireMessage { public static let type = "decline"; public init() {} }
/// Sent only after both sides confirmed: the permanent address and this side's share of the
/// per-pair secret, sealed to the pairing's key exchange.
public struct PairKeys: WireMessage {
    public static let type = "pair_keys"
    public var box: String
    public init(box: String) { self.box = box }
}
/// Sent once the peer's box has opened. Each side stores the device only after the other
/// side's `pair_done`, so a box that fails to open on either side leaves both with nothing.
public struct PairDone: WireMessage { public static let type = "pair_done"; public init() {} }

public enum PairingDigits {
    static let commitLabel = Data("catflap-pair-commit-v1".utf8)

    /// The commitment the joiner sends first: SHA-256 over a fixed label and the exact bytes
    /// of the hello it will send later, base64.
    public static func commitment(hello: Data) -> String {
        Data(SHA256.hash(data: commitLabel + hello)).base64EncodedString()
    }

    /// A hash of the exchange: both hellos exactly as they crossed the tunnel, joiner first.
    public static func transcript(joinerHello: Data, initiatorHello: Data) -> Data {
        var input = Data("catflap-pair-v1".utf8)
        for part in [joinerHello, initiatorHello] {
            var length = UInt32(part.count).bigEndian
            input.append(Data(bytes: &length, count: 4))
            input.append(part)
        }
        return Data(SHA256.hash(data: input))
    }

    /// The six digits both people compare.
    public static func digits(joinerHello: Data, initiatorHello: Data) -> String {
        digits(transcript: transcript(joinerHello: joinerHello, initiatorHello: initiatorHello))
    }

    static func digits(transcript: Data) -> String {
        let value = transcript.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let number = String(value % 1_000_000)
        return String(repeating: "0", count: 6 - number.count) + number
    }

    /// The per-pair secret, from the exchange's shared secret and both sides' shares, bound
    /// to the exchange.
    static func pairSecret(transcript: Data, shared: Data, initiatorShare: Data, joinerShare: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared + initiatorShare + joinerShare),
                                         salt: transcript, info: Data("catflap-pair-secret-v1".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}

/// Seals `pair_keys` to the X25519 exchange of this pairing.
enum PairingSeal {
    enum Failure: Error { case badKey, zeroSecret, unopened }
    private struct Contents: Codable { var address: String; var secret: String }

    /// The X25519 shared secret with the peer's exchange key. An all-zero result is refused.
    static func sharedSecret(_ mine: Curve25519.KeyAgreement.PrivateKey, peerKey: String) throws -> Data {
        guard let raw = Data(base64Encoded: peerKey), raw.count == 32,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
              let secret = try? mine.sharedSecretFromKeyAgreement(with: peer) else { throw Failure.badKey }
        let bytes = secret.withUnsafeBytes { Data($0) }
        guard bytes.contains(where: { $0 != 0 }) else { throw Failure.zeroSecret }
        return bytes
    }

    /// A different key for each direction, so neither box can be sent back as the other's.
    static func key(shared: Data, transcript: Data, sealedBy role: PairingRole) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared), salt: transcript,
                               info: Data("catflap-pair-box-v1 sealed by \(role.rawValue)".utf8), outputByteCount: 32)
    }

    static func seal(address: String, share: Data, shared: Data, transcript: Data, sealedBy role: PairingRole) throws -> String {
        let plain = try JSONEncoder().encode(Contents(address: address, secret: share.base64EncodedString()))
        let box = try ChaChaPoly.seal(plain, using: key(shared: shared, transcript: transcript, sealedBy: role),
                                      authenticating: transcript)
        return box.combined.base64EncodedString()
    }

    static func open(_ text: String, shared: Data, transcript: Data, sealedBy role: PairingRole) throws -> (address: String, share: Data) {
        guard text.utf8.count <= 32 * 1024, let combined = Data(base64Encoded: text),
              let box = try? ChaChaPoly.SealedBox(combined: combined),
              let plain = try? ChaChaPoly.open(box, using: key(shared: shared, transcript: transcript, sealedBy: role),
                                               authenticating: transcript),
              let contents = try? JSONDecoder().decode(Contents.self, from: plain),
              !contents.address.isEmpty, contents.address.utf8.count <= 16 * 1024,
              let share = Data(base64Encoded: contents.secret), share.count == 32 else { throw Failure.unopened }
        return (contents.address, share)
    }
}
