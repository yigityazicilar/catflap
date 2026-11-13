import CatflapCore
import Crypto
import Foundation
import Tailcat
import Testing
#if os(macOS)
import Security
#endif

private actor ListenerEvents {
    var listeners: [TailcatListener?] = []
    func record(_ listener: TailcatListener?) { listeners.append(listener) }
    func snapshot() -> [TailcatListener?] { listeners }
}
extension IdentityTests {
    @Test func testListenerObserverSeesStartRebuildAndStop() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let runtime = try AgentRuntime(paths: paths)
        let peer = try TailcatKeys.generate()
        try await runtime.store.saveDevice(.init(id: "peer", name: "Peer", clientPublicKey: peer.publicKey,
                                               address: "test", pairSecret: Data([1]), build: "test"))
        let events = ListenerEvents()
        // This is the same registration point a feature uses in install(on:), before start.
        await runtime.identityServer.observeListener { await events.record($0) }
        let registeredCount = await events.snapshot().count
        #expect(registeredCount == 1)
        try await runtime.start()
        let first = try #require(await runtime.identityServer.listener)
        try await runtime.identityServer.rebuild(allowedClients: [peer.publicKey])
        let second = try #require(await runtime.identityServer.listener)
        await runtime.stop()
        let observed = await events.snapshot()
        let observedCount = observed.count
        #expect(observedCount == 5)
        guard observedCount == 5 else { return }
        let states = observed.map { $0 != nil }
        let firstMatches = observed[1] === first
        let secondMatches = observed[3] === second
        let distinctListeners = first !== second
        // Compare booleans so a failed assertion cannot reflect a server's private fields.
        #expect(states == [false, true, false, true, false])
        #expect(firstMatches)
        #expect(secondMatches)
        #expect(distinctListeners)
        #expect(await runtime.identityServer.isRunning == false)
    }
    @Test func testEraseRemovesStoredKeys() throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let persistence = IdentityStore(paths: paths)
        let first = try persistence.loadOrCreate()
        #expect(try persistence.hasStoredKeys())
        try persistence.erase()
        #expect(try persistence.hasStoredKeys() == false)
        #expect(FileManager.default.fileExists(atPath: paths.identity.path) == false)
        #if os(macOS)
        let account = SHA256.hash(data: Data(paths.directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "Catflap.identity.v1", kSecAttrAccount as String: account]
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
        #else
        #expect(FileManager.default.fileExists(atPath: paths.keys.path) == false)
        #endif
        try persistence.erase()
        let second = try persistence.loadOrCreate()
        #expect(first.id != second.id)
        let differentKeys = first.serverKeys != second.serverKeys && first.clientKeys != second.clientKeys
        #expect(differentKeys)
    }
}
