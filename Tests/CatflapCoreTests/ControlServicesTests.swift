import CatflapCore
import Foundation
import Testing

struct ControlServicesTests {
    @Test func testInstalledPairingProvidesItsServicesToLaterFeatures() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let runtime = try AgentRuntime(paths: paths)
        let before = await runtime.service(PeerService.self)
        #expect(before == nil)
        let pairing = await PairingService.install(on: runtime)
        // A feature installed after pairing gets the same instances, not new ones.
        let peers = await runtime.service(PeerService.self)
        #expect(peers === pairing.peers)
        let found = await runtime.service(PairingService.self)
        #expect(found === pairing)
        // A type nobody provided is absent, and one runtime does not see another's.
        let absent = await runtime.service(Store.self)
        #expect(absent == nil)
        let otherPaths = try storeTestPaths()
        defer { removeStoreTestPaths(otherPaths) }
        let other = try AgentRuntime(paths: otherPaths)
        let foreign = await other.service(PeerService.self)
        #expect(foreign == nil)
        await runtime.stop()
        await other.stop()
    }
}
