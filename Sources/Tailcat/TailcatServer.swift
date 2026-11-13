import CTailcat
import Foundation
import Synchronization

/// The relay region a server registers with. Passing the region recorded at first start keeps
/// the server's address the same across restarts.
public enum TailcatRegion: Sendable, Hashable, Codable, CustomStringConvertible {
    /// A region of the default relay map, by id.
    case id(Int)
    /// A full DERPRegion record in its JSON encoding, as embedded in the server's address.
    case record(String)

    /// Short form: the record lists relay hosts, which do not belong in logs.
    public var description: String {
        switch self {
        case .id(let id): "TailcatRegion.id(\(id))"
        case .record(let json): "TailcatRegion.record(\(json.utf8.count) bytes)"
        }
    }
}

/// A tailcat server's public description. `address` is a secret: whoever holds it can try to
/// connect. The type's descriptions never show it.
public struct TailcatServerInfo: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let address: String
    public let publicKey: String
    /// The relay region the address names, for pinning on the next start.
    public let region: TailcatRegion?

    public var description: String { "TailcatServerInfo(address: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// A tailcat server. It admits only the client keys on its allowlist.
///
/// The server owns its listeners and every connection they accept: `close()` ends all of them.
public final class TailcatServer: Sendable {
    public struct Configuration: Sendable {
        /// The server's own key and pre-shared key. Reusing them keeps the address stable.
        public var keys: TailcatKeys
        /// Public keys of the clients that may connect. Must not be empty: tailcat treats an
        /// empty allowlist as "anyone holding the address".
        public var allowedClients: [String]
        /// The relay region to register with. `nil` lets tailcat pick one.
        public var region: TailcatRegion?

        public init(keys: TailcatKeys, allowedClients: [String], region: TailcatRegion? = nil) {
            self.keys = keys
            self.allowedClients = allowedClients
            self.region = region
        }
    }

    let owned: OwnedHandle
    private let keySecrets: [String]
    private let knownAddress = Mutex<String?>(nil)

    var handle: tc_handle { owned.handle }

    /// Creates the server without starting it. `listen` starts it.
    public init(config: Configuration) throws {
        guard !config.allowedClients.isEmpty else {
            throw TailcatError(.invalidArgument, "server.new", detail: "the allowlist is empty")
        }
        keySecrets = config.keys.secrets
        var object: [String: Any] = [
            "key": config.keys.privateKey,
            "preshared_key": config.keys.presharedKey,
            "allowed_clients": config.allowedClients,
        ]
        switch config.region {
        case .id(let id):
            object["region_id"] = id
        case .record(let json):
            guard let record = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else {
                throw TailcatError(.invalidArgument, "server.new", detail: "region record is not JSON")
            }
            object["region"] = record
        case nil:
            break
        }
        let json = try JSONSerialization.data(withJSONObject: object)
        var bytes = Array(json) + [0]
        var handle: tc_handle = 0
        var error: UnsafeMutablePointer<CChar>?
        let status = bytes.withUnsafeMutableBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { tc_server_new($0.baseAddress, &handle, &error) }
        }
        let message = takeCString(error)
        guard status == statusOK, handle != 0 else {
            throw TailcatError(status: status, operation: "server.new", message: message, secrets: keySecrets)
        }
        owned = OwnedHandle(handle, parent: nil, isPeer: true)
    }

    private var secrets: [String] {
        keySecrets + (knownAddress.withLock { $0 }.map { [$0] } ?? [])
    }

    /// Starts the server if needed and listens for TCP connections on `port` inside the tunnel.
    public func listen(port: UInt16, timeout: Duration? = nil) async throws -> TailcatListener {
        let server = owned.handle
        let result = try await BlockingCall.run(
            "server.listen", resource: server, timeout: timeout, produces: ({ $0 }, server)
        ) { [owned] token in
            _ = owned
            var listener: tc_handle = 0
            var error: UnsafeMutablePointer<CChar>?
            let status = tc_server_listen(server, token, port, Int32(TC_TCP), &listener, &error)
            return CReturn(status: status, value: listener, message: takeCString(error))
        }
        guard result.status == statusOK, result.value != 0 else {
            throw TailcatError(status: result.status, operation: "server.listen", message: result.message, secrets: secrets)
        }
        return TailcatListener(handle: result.value, server: self)
    }

    /// The started server's address, public key and relay region.
    public func info(timeout: Duration? = nil) async throws -> TailcatServerInfo {
        let server = owned.handle
        let result = try await BlockingCall.run("server.info", resource: server, timeout: timeout) { [owned] token -> CReturn<TailcatServerInfo?> in
            _ = owned
            var out: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let status = tc_info(server, token, &out, &error)
            let json = takeCString(out)
            let message = takeCString(error)
            guard status == statusOK, let json else {
                return CReturn(status: status, value: nil, message: message)
            }
            return CReturn(status: status, value: Self.parseInfo(json), message: message)
        }
        guard result.status == statusOK else {
            throw TailcatError(status: result.status, operation: "server.info", message: result.message, secrets: secrets)
        }
        guard let info = result.value else {
            throw TailcatError(.failure, "server.info", detail: "unexpected info format")
        }
        knownAddress.withLock { $0 = info.address }
        return info
    }

    private static func parseInfo(_ json: String) -> TailcatServerInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let address = object["address"] as? String,
              let publicKey = object["public_key"] as? String
        else { return nil }
        return TailcatServerInfo(address: address, publicKey: publicKey, region: region(of: address))
    }

    /// Reads the relay region out of an address, locally.
    private static func region(of address: String) -> TailcatRegion? {
        var bytes = Array(address.utf8CString)
        var out: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let status = bytes.withUnsafeMutableBufferPointer { tc_address_parse($0.baseAddress, &out, &error) }
        let json = takeCString(out)
        _ = takeCString(error)
        guard status == statusOK, let json,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        if let id = object["region_id"] as? Int, id != 0 { return .id(id) }
        // The address embeds the region it was created in as a one-element list of records.
        if let records = object["regions"] as? [[String: Any]], let record = records.first,
           let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            return .record(String(decoding: data, as: UTF8.self))
        }
        return nil
    }

    /// Closes the server, its listeners and every connection it accepted.
    public func close() async {
        await owned.close()
    }
}

/// Accepts connections for a server. Closing it stops new connections; accepted ones stay
/// open until they or the server close.
public final class TailcatListener: Sendable {
    let owned: OwnedHandle
    /// Accepted connections belong to the server, so the listener keeps it alive.
    let server: TailcatServer

    var handle: tc_handle { owned.handle }

    init(handle: tc_handle, server: TailcatServer) {
        owned = OwnedHandle(handle, parent: server.handle)
        self.server = server
    }

    /// Waits for the next connection from an allowlisted client.
    public func accept(timeout: Duration? = nil) async throws -> TailcatConnection {
        let listener = owned.handle
        let result = try await BlockingCall.run(
            "listener.accept", resource: listener, timeout: timeout, produces: ({ $0 }, server.handle)
        ) { [owned] token in
            _ = owned
            var connection: tc_handle = 0
            var error: UnsafeMutablePointer<CChar>?
            let status = tc_listener_accept(listener, token, &connection, &error)
            return CReturn(status: status, value: connection, message: takeCString(error))
        }
        guard result.status == statusOK, result.value != 0 else {
            throw TailcatError(status: result.status, operation: "listener.accept", message: result.message)
        }
        return TailcatConnection(handle: result.value, owner: server.handle, keepAlive: server)
    }

    public func close() async {
        await owned.close()
    }
}
