import CatflapCore
import Crypto
import Foundation
import Tailcat
import Testing

struct IdentityTests {
    @Test func testIdentityKeepsItsAddressAcrossRestart() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let persistence = IdentityStore(paths: paths)
        let first = try IdentityServer(persistence: persistence)
        let peer = try TailcatKeys.generate()
        try await first.rebuild(allowedClients: [peer.publicKey])
        let oldIdentity = await first.identity
        let oldAddress = try #require(await first.address())
        let digest = SHA256.hash(data: Data(oldAddress.utf8))
        #expect(oldIdentity.region != nil)
        await first.stop()
        let second = try IdentityServer(persistence: persistence)
        let newIdentity = await second.identity
        let sameKeys = oldIdentity.serverKeys == newIdentity.serverKeys && oldIdentity.clientKeys == newIdentity.clientKeys
        #expect(sameKeys)
        let distinctKeys = newIdentity.serverKeys.publicKey != newIdentity.clientKeys.publicKey
        #expect(distinctKeys)
        #expect(oldIdentity.id == newIdentity.id)
        try await second.rebuild(allowedClients: [peer.publicKey])
        let newAddress = try #require(await second.address())
        let sameAddress = digest == SHA256.hash(data: Data(newAddress.utf8))
        await second.stop()
        #expect(sameAddress)
    }
    @Test func testNoServerRunsWithoutPairedDevices() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let runtime = try AgentRuntime(paths: paths)
        try await runtime.start()
        #expect(await runtime.identityServer.isRunning == false)
        #expect(try await runtime.identityServer.address() == nil)
        let status = try await runtime.handle(.init("status")).decode(AgentStatus.self)
        #expect(status.serverRunning == false)
        #expect(status.pairedDevices == 0)
        await runtime.stop()
    }
}
