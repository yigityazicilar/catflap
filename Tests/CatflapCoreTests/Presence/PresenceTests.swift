import Foundation
import Synchronization
import Tailcat
import Testing
@testable import CatflapCore

private let peer = DeviceRecord(id: "peer", name: "Peer", clientPublicKey: "unused", address: "unused", pairSecret: Data(), build: "test")

private final class PresenceClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    func now() -> Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0.addTimeInterval(seconds) } }
}

private actor PingDouble {
    var calls = 0
    var waiters: [CheckedContinuation<TailcatPing, any Error>] = []
    var deadlines: [Duration] = []
    func ping(_ device: DeviceRecord, timeout: Duration) async throws -> TailcatPing {
        calls += 1; deadlines.append(timeout)
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func waitForCalls(_ count: Int) async {
        while calls < count { await Task.yield() }
    }
    func succeed(_ path: TailcatPing.Path = .direct) {
        waiters.removeFirst().resume(returning: TailcatPing(latency: 0.012, path: path))
    }
    func fail() { waiters.removeFirst().resume(throwing: AgentError.control) }
}

@Suite struct PresenceTests {
    @Test func testCheckingHereAwayAndCachedAge() async throws {
        let clock = PresenceClock(), ping = PingDouble()
        let service = PresenceService(devices: { [peer] }, ping: { try await ping.ping($0, timeout: $1) }, now: clock.now)
        let checking = try await service.presence()
        #expect(checking.first?.state == .checking)
        #expect(checking.first?.checkedAt == nil)
        await ping.waitForCalls(1)
        #expect(await ping.deadlines == [.seconds(10)])
        await ping.succeed(.relayed(regionID: 7, regionCode: "test"))
        await service.waitForChecks()
        clock.advance(5)
        let here = try await service.presence(refresh: false)
        #expect(here.first?.state == .here)
        #expect(here.first?.path == "relayed")
        #expect(here.first?.relayRegionID == 7)
        #expect(here.first?.relayRegionCode == "test")
        #expect(here.first?.latencyMs == 12)
        #expect(here.first?.ageSeconds == 5)
        _ = try await service.presence()
        await ping.waitForCalls(2)
        await ping.fail(); await service.waitForChecks()
        let away = try await service.presence(refresh: false)
        #expect(away.first?.state == .away)
        #expect(away.first?.path == nil)
        #expect(away.first?.latencyMs == nil)
        await service.stop()
    }

    @Test func testConcurrentRequestsHaveOnePingPerDevice() async throws {
        let ping = PingDouble()
        let service = PresenceService(devices: { [peer] }, ping: { try await ping.ping($0, timeout: $1) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { _ = try await service.presence() } }
            try await group.waitForAll()
        }
        await ping.waitForCalls(1)
        #expect(await ping.calls == 1)
        await ping.succeed(); await service.waitForChecks()
        let rows = try await service.presence(refresh: false)
        #expect(rows.first?.path == "direct")
        #expect(rows.first?.relayRegionCode == nil)
        await service.stop()
    }

    @Test func testWatchRenewsExpiresAndOnlyPingsEverySixtySeconds() async throws {
        let clock = PresenceClock(), ping = PingDouble()
        let service = PresenceService(devices: { [peer] }, ping: { try await ping.ping($0, timeout: $1) }, now: clock.now)
        let lease = try await service.watch()
        #expect(lease.expiresAt.timeIntervalSince(clock.now()) == 90)
        await ping.waitForCalls(1); await ping.succeed(); await service.waitForChecks()
        clock.advance(59); try await service.tick()
        #expect(await ping.calls == 1)
        let renewed = try await service.watch(leaseID: lease.leaseID)
        #expect(renewed.leaseID == lease.leaseID)
        clock.advance(1); try await service.tick()
        await ping.waitForCalls(2)
        // A due refresh cannot stack up behind a slow ping.
        clock.advance(60); try await service.tick()
        #expect(await ping.calls == 2)
        await ping.succeed(); await service.waitForChecks()
        clock.advance(30); try await service.tick()
        #expect(await ping.calls == 2)
        let error = await #expect(throws: AgentError.self) { _ = try await service.watch(leaseID: lease.leaseID) }
        #expect(error == .invalidRequest)
        await service.stop()
    }

    @Test func testIndependentWatchLeasesAndRemovedDeviceResults() async throws {
        let clock = PresenceClock(), ping = PingDouble()
        let devices = Mutex([peer])
        let service = PresenceService(devices: { devices.withLock { $0 } }, ping: { try await ping.ping($0, timeout: $1) }, now: clock.now)
        let first = try await service.watch()
        await ping.waitForCalls(1)
        clock.advance(50)
        let second = try await service.watch()
        #expect(first.leaseID != second.leaseID)
        devices.withLock { $0 = [] }
        #expect(try await service.presence(refresh: false).isEmpty)
        await ping.succeed(); await service.waitForChecks()
        #expect(try await service.presence(refresh: false).isEmpty)
        clock.advance(50); try await service.tick()
        _ = try await service.watch(leaseID: second.leaseID)
        await service.stop()
    }

    @Test func testControlCommandsUseSnakeCaseISO8601AndNoEndpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = try AgentPaths(directory: directory)
        let runtime = try AgentRuntime(paths: paths)
        let ping = PingDouble()
        let service = PresenceService(devices: { [peer] }, ping: { try await ping.ping($0, timeout: $1) })
        await service.install(on: runtime)
        let checking = await runtime.handle(ControlRequest("presence"))
        #expect(checking.ok)
        await ping.waitForCalls(1); await ping.succeed(.relayed(regionID: 7, regionCode: "test")); await service.waitForChecks()
        let response = await runtime.handle(ControlRequest("presence", arguments: ["refresh": "false"]))
        let json = try #require(JSONSerialization.jsonObject(with: response.payload) as? [[String: Any]])
        #expect(json.first?["device_id"] as? String == "peer")
        #expect(json.first?["relay_region_code"] as? String == "test")
        let date = try #require(json.first?["checked_at"] as? String)
        #expect(ISO8601DateFormatter().date(from: date) != nil)
        #expect(json.first?["age_seconds"] != nil)
        #expect(!String(decoding: response.payload, as: UTF8.self).contains("endpoint"))
        let watch = await runtime.handle(ControlRequest("presence.watch"))
        #expect(watch.ok)
        let lease = try watch.decode(PresenceLease.self)
        let renew = await runtime.handle(ControlRequest("presence.watch", arguments: ["lease_id": lease.leaseID]))
        #expect(renew.ok)
        let invalid = await runtime.handle(ControlRequest("presence.watch", arguments: ["lease_id": "invalid"]))
        #expect(!invalid.ok)
        await ping.waitForCalls(2); await ping.succeed(); await service.waitForChecks()
        await service.stop()
        try IdentityStore(paths: paths).erase()
        try FileManager.default.removeItem(at: directory)
    }

    @Test func testRealLocalNodePresencePing() async throws {
        let keys = try TailcatKeys.generate()
        let server = try TailcatServer(config: .init(keys: .generate(), allowedClients: [keys.publicKey]))
        do {
            _ = try await server.listen(port: 7447, timeout: .seconds(60))
            let info = try await server.info(timeout: .seconds(60))
            var device = peer; device.address = info.address
            let target = device
            let service = PresenceService(devices: { [target] }, clientKeys: keys)
            _ = try await service.presence()
            await service.waitForChecks()
            let result = try await service.presence(refresh: false)
            #expect(result.first?.state == .here)
            #expect(result.first?.latencyMs != nil)
            #expect(["direct", "relayed"].contains(result.first?.path ?? ""))
            await service.stop()
        } catch { await server.close(); throw error }
        await server.close()
    }
}
