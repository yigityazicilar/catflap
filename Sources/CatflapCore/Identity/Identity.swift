import Crypto
import Foundation
import Tailcat
#if os(macOS)
import Security
#endif

public struct IdentitySecurityError: Error, LocalizedError, Sendable {
    public let operation: String
    public let status: Int32
    public var errorDescription: String? { AgentError.identity.rawValue }
    public var isAuthenticationFailed: Bool {
        #if os(macOS)
        return status == errSecAuthFailed
        #else
        return false
        #endif
    }
}

public struct DeviceIdentity: Sendable, CustomStringConvertible, CustomReflectable {
    public let id: String
    public let serverKeys: TailcatKeys
    public let clientKeys: TailcatKeys
    public fileprivate(set) var region: TailcatRegion?
    public var description: String { "DeviceIdentity(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// On macOS, first use of this store disables Keychain dialogs for the calling
/// process before its first Keychain operation. The setting is per process,
/// including when a test process uses the store itself.
public struct IdentityStore: Sendable {
    public let paths: AgentPaths
    public init(paths: AgentPaths) {
        self.paths = paths
        #if os(macOS)
        // Initialize the process-wide policy before the first Keychain operation.
        _ = Self.nonInteractiveStatus
        #endif
    }
    private struct Metadata: Codable { var id: String; var region: TailcatRegion? }
    private struct Keys: Codable {
        var serverPrivate: String; var serverPublic: String; var serverPSK: String
        var clientPrivate: String; var clientPublic: String; var clientPSK: String
        init(_ identity: DeviceIdentity) {
            serverPrivate = identity.serverKeys.privateKey; serverPublic = identity.serverKeys.publicKey
            serverPSK = identity.serverKeys.presharedKey; clientPrivate = identity.clientKeys.privateKey
            clientPublic = identity.clientKeys.publicKey; clientPSK = identity.clientKeys.presharedKey
        }
        func identity(_ metadata: Metadata) -> DeviceIdentity {
            .init(id: metadata.id,
                  serverKeys: .init(privateKey: serverPrivate, publicKey: serverPublic, presharedKey: serverPSK),
                  clientKeys: .init(privateKey: clientPrivate, publicKey: clientPublic, presharedKey: clientPSK), region: metadata.region)
        }
    }
    public func loadOrCreate() throws -> DeviceIdentity {
        do {
            if FileManager.default.fileExists(atPath: paths.identity.path) {
                try AgentPaths.secureFile(paths.identity)
                let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: paths.identity))
                return try JSONDecoder().decode(Keys.self, from: readKeys()).identity(metadata)
            }
            let identity = DeviceIdentity(id: UUID().uuidString, serverKeys: try .generate(), clientKeys: try .generate(), region: nil)
            try writeKeys(JSONEncoder().encode(Keys(identity)))
            try save(identity)
            return identity
        } catch let failure as IdentitySecurityError { throw failure }
        catch { throw AgentError.identity }
    }
    public func save(_ identity: DeviceIdentity) throws {
        try AgentPaths.writePrivate(JSONEncoder().encode(Metadata(id: identity.id, region: identity.region)), to: paths.identity)
    }
    public func erase() throws {
        #if os(macOS)
        let query = try keyQuery()
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentitySecurityError(operation: "SecItemDelete", status: status)
        }
        #else
        if FileManager.default.fileExists(atPath: paths.keys.path) {
            try FileManager.default.removeItem(at: paths.keys)
        }
        #endif
        if FileManager.default.fileExists(atPath: paths.identity.path) {
            try FileManager.default.removeItem(at: paths.identity)
        }
    }
    /// Checks the actual key backend, independently of whether metadata remains on disk.
    public func hasStoredKeys() throws -> Bool {
        #if os(macOS)
        let query = try keyQuery()
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw IdentitySecurityError(operation: "SecItemCopyMatching.presence", status: status)
        }
        return true
        #else
        return FileManager.default.fileExists(atPath: paths.keys.path)
        #endif
    }
    #if os(macOS)
    private static let nonInteractiveStatus = SecKeychainSetUserInteractionAllowed(false)
    private func keyQuery() throws -> [String: Any] {
        guard Self.nonInteractiveStatus == errSecSuccess else {
            throw IdentitySecurityError(operation: "SecKeychainSetUserInteractionAllowed", status: Self.nonInteractiveStatus)
        }
        let account = SHA256.hash(data: Data(paths.directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Catflap.identity.v1", kSecAttrAccount as String: account]
    }
    private func readKeys() throws -> Data {
        var query = try keyQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw IdentitySecurityError(operation: "SecItemCopyMatching.read", status: status)
        }
        guard let data = result as? Data else { throw AgentError.identity }
        return data
    }
    private func writeKeys(_ data: Data) throws {
        var query = try keyQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery = try keyQuery()
            let update = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw IdentitySecurityError(operation: "SecItemUpdate", status: update) }
        } else if status != errSecSuccess { throw IdentitySecurityError(operation: "SecItemAdd", status: status) }
    }
    #else
    private func readKeys() throws -> Data {
        try AgentPaths.secureFile(paths.keys)
        return try Data(contentsOf: paths.keys)
    }
    private func writeKeys(_ data: Data) throws { try AgentPaths.writePrivate(data, to: paths.keys) }
    #endif
}

/// The permanent server has no instance at all until there is a paired client.
public actor IdentityServer {
    public private(set) var identity: DeviceIdentity
    public private(set) var server: TailcatServer?
    public private(set) var listener: TailcatListener?
    private let persistence: IdentityStore
    public init(persistence: IdentityStore) throws {
        self.persistence = persistence
        identity = try persistence.loadOrCreate()
    }
    public var isRunning: Bool { server != nil }
    public typealias ListenerObserver = @Sendable (TailcatListener?) async -> Void
    private var observer: ListenerObserver?
    private var transitioning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func acquireTransition() async {
        if !transitioning { transitioning = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func releaseTransition() {
        if waiters.isEmpty { transitioning = false }
        else { waiters.removeFirst().resume() }
    }
    /// One observer, including the current state on registration. Start an accept task and
    /// return; the observer must not await an accept or re-enter lifecycle operations.
    public func observeListener(_ observer: @escaping ListenerObserver) async {
        await acquireTransition()
        defer { releaseTransition() }
        self.observer = observer
        await observer(listener)
    }
    public func rebuild(allowedClients: [String], port: UInt16 = 7447) async throws {
        await acquireTransition()
        defer { releaseTransition() }
        await stopCurrent()
        guard !allowedClients.isEmpty else { return }
        let candidate = try TailcatServer(config: .init(keys: identity.serverKeys, allowedClients: allowedClients, region: identity.region))
        do {
            let listening = try await candidate.listen(port: port, timeout: .seconds(30))
            let info = try await candidate.info(timeout: .seconds(10))
            guard let region = info.region else { throw AgentError.identity }
            identity.region = region
            // Commit the pin before exposing the server to pairing or transfer code.
            try persistence.save(identity)
            server = candidate; listener = listening
            await observer?(listening)
        } catch { await candidate.close(); throw error }
    }
    public func address() async throws -> String? {
        guard let server else { return nil }
        return try await server.info(timeout: .seconds(10)).address
    }
    public func stop() async {
        await acquireTransition()
        defer { releaseTransition() }
        await stopCurrent()
    }
    private func stopCurrent() async {
        let oldListener = listener; let oldServer = server
        listener = nil; server = nil
        await oldListener?.close(); await oldServer?.close()
        // Closing the server also closes every accepted connection it owns.
        if oldListener != nil { await observer?(nil) }
    }
}
