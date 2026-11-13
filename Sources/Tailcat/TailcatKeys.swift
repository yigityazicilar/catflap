import CTailcat
import Foundation

/// A tailcat node key pair and a pre-shared key, in tailcat's text encodings.
///
/// All three strings are secrets except `publicKey`. The type's descriptions never show them.
public struct TailcatKeys: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let privateKey: String
    public let publicKey: String
    public let presharedKey: String

    public init(privateKey: String, publicKey: String, presharedKey: String) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.presharedKey = presharedKey
    }

    /// Generates a fresh key pair and pre-shared key locally, without network access.
    public static func generate() throws -> TailcatKeys {
        var out: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let status = tc_key_generate(&out, &error)
        let json = takeCString(out)
        let message = takeCString(error)
        guard status == statusOK, let json else {
            throw TailcatError(status: status == statusOK ? Int32(TC_FAILURE) : status, operation: "keys.generate", message: message)
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let privateKey = object["private_key"] as? String,
              let publicKey = object["public_key"] as? String,
              let presharedKey = object["preshared_key"] as? String
        else {
            throw TailcatError(.failure, "keys.generate", detail: "unexpected key format")
        }
        return TailcatKeys(privateKey: privateKey, publicKey: publicKey, presharedKey: presharedKey)
    }

    var secrets: [String] { [privateKey, presharedKey] }

    public var description: String { "TailcatKeys(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
