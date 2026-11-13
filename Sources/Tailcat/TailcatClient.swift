import CTailcat
import Foundation

/// A tailcat client for one server address. It owns the connections it dials: `close()` ends
/// all of them.
public final class TailcatClient: Sendable {
    let owned: OwnedHandle
    private let secrets: [String]

    var handle: tc_handle { owned.handle }

    /// Creates the client without network access. `address` is the server's secret address;
    /// `key` is this device's client key (only its private key is used).
    public init(address: String, key: TailcatKeys) throws {
        secrets = [address] + key.secrets
        let object: [String: Any] = ["address": address, "key": key.privateKey]
        let json = try JSONSerialization.data(withJSONObject: object)
        var bytes = Array(json) + [0]
        var handle: tc_handle = 0
        var error: UnsafeMutablePointer<CChar>?
        let status = bytes.withUnsafeMutableBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { tc_client_new($0.baseAddress, &handle, &error) }
        }
        let message = takeCString(error)
        guard status == statusOK, handle != 0 else {
            throw TailcatError(status: status, operation: "client.new", message: message, secrets: secrets)
        }
        owned = OwnedHandle(handle, parent: nil, isPeer: true)
    }

    /// Dials a TCP port on the server. A server that does not admit this client's key does not
    /// answer, so this ends in `.timeout`.
    public func dial(port: UInt16, timeout: Duration? = nil) async throws -> TailcatConnection {
        let client = owned.handle
        let result = try await BlockingCall.run(
            "client.dial", resource: client, timeout: timeout, produces: ({ $0 }, client)
        ) { [owned] token in
            _ = owned
            var connection: tc_handle = 0
            var error: UnsafeMutablePointer<CChar>?
            let status = tc_client_dial(client, token, port, Int32(TC_TCP), &connection, &error)
            return CReturn(status: status, value: connection, message: takeCString(error))
        }
        guard result.status == statusOK, result.value != 0 else {
            throw TailcatError(status: result.status, operation: "client.dial", message: result.message, secrets: secrets)
        }
        return TailcatConnection(handle: result.value, owner: client, keepAlive: self)
    }

    /// Closes the client and every connection it dialed.
    public func close() async {
        await owned.close()
    }
}
