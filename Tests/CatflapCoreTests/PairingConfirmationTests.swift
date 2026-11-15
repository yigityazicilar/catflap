import CatflapCore
import Foundation
import Testing

/// A joiner-side transport that holds the end of the stream until the test releases it, so
/// the pairing's exchange stays open on that side and its pending key stays admitted.
struct HeldEndTransport: WireTransport {
    let inner: any WireTransport
    let release: TestSignal
    func read(upTo maxLength: Int, timeout: Duration?) async throws -> Data? {
        let data = try await inner.read(upTo: maxLength, timeout: timeout)
        if data == nil { await release.wait() }
        return data
    }
    func write(_ data: Data, timeout: Duration?) async throws { try await inner.write(data, timeout: timeout) }
    func closeWrite(timeout: Duration?) async throws { try await inner.closeWrite(timeout: timeout) }
    func close() async { await inner.close() }
}

/// Lead's Q6 answer: no leftover key stays on any allowlist. The side that stored a new
/// pairing keeps it `unconfirmed` until the other side shows it admits this device.
@Suite struct PairingConfirmationTests {
    @Test func testPairingThatFinishedOnOneSideStaysUnconfirmedWithThatMessage() async throws {
        // Device A's final `pair_done` never leaves: A has B's, so A stores the pairing; B
        // never gets A's, so B stores nothing and its server never admits A.
        let dropDone: @Sendable (any WireTransport, PairingRole) -> any WireTransport = { transport, role in
            RecordingTransport(inner: transport, role: role, log: TunnelLog(), rewrite: { data in
                contains(data, "pair_done") ? Data() : data
            })
        }
        try await withTestDevices { devices in
            let a = try await devices.make("Device A") { $0.transportHook = dropDone }
            let b = try await devices.make("Device B") { $0.exchangeTimeout = .seconds(20) }
            _ = try await reachDigits(a, b)
            _ = try await a.pairing.confirm(); _ = try await b.pairing.confirm()
            #expect(try await waitForStatus(a) { !$0.isActive }.state == .paired)
            #expect(try await waitForStatus(b) { !$0.isActive }.state == .failed)
            #expect(try await b.runtime.store.devices().isEmpty)
            let bID = try #require(try await a.runtime.store.devices().first?.id)
            #expect(await a.peers.deviceStates()[bID]?.confirmed == false)
            // A dial to it explains the one-sided pairing.
            await #expect(throws: PeerError.unreachableUnconfirmed(device: "Device B")) {
                _ = try await a.peers.open(deviceID: bID, timeout: .seconds(3))
            }
            #expect(await a.peers.deviceStates()[bID]?.confirmed == false)
        }
    }

    /// A ping answer proves only that the other server admits this device's key, which it does
    /// while a pairing is still pending there. It must not confirm a pairing the other side has
    /// not stored. B's exchange is held open (its final `pair_done` from A never comes and its
    /// exchange limit is far off), so A's key stays pending on B while A pings it.
    @Test func testPingAnsweredWhileTheKeyIsOnlyPendingDoesNotConfirm() async throws {
        let dropDone: @Sendable (any WireTransport, PairingRole) -> any WireTransport = { transport, role in
            RecordingTransport(inner: transport, role: role, log: TunnelLog(), rewrite: { data in
                contains(data, "pair_done") ? Data() : data
            })
        }
        try await withTestDevices { devices in
            let held = TestSignal()
            defer { held.fire() }
            let a = try await devices.make("Device A") { $0.transportHook = dropDone }
            let b = try await devices.make("Device B") {
                $0.exchangeTimeout = .seconds(600)
                $0.transportHook = { transport, _ in HeldEndTransport(inner: transport, release: held) }
            }
            _ = try await reachDigits(a, b)
            _ = try await a.pairing.confirm(); _ = try await b.pairing.confirm()
            #expect(try await waitForStatus(a) { !$0.isActive }.state == .paired)
            // B is still in its exchange: it stored nothing, and A's key is pending on it.
            #expect(await b.status.state == .exchanging)
            #expect(try await b.runtime.store.devices().isEmpty)
            let bID = try #require(try await a.runtime.store.devices().first?.id)
            // The ping is answered: the key is admitted.
            var answered = false
            for _ in 0..<4 where !answered { answered = (try? await a.peers.ping(deviceID: bID, timeout: .seconds(30))) != nil }
            #expect(answered, "B's server did not answer a ping from a pending key")
            #expect(await a.peers.deviceStates()[bID]?.confirmed == false, "a ping answer confirmed a pairing B never stored")
            held.fire()
            _ = await b.pairing.decline()
        }
    }

    @Test func testFullPairingBecomesConfirmedAfterItsFirstPing() async throws {
        try await withTestDevices { devices in
            let a = try await devices.make("Device A"), b = try await devices.make("Device B")
            _ = try await reachDigits(a, b)
            _ = try await a.pairing.confirm(); _ = try await b.pairing.confirm()
            #expect(try await waitForStatus(a) { !$0.isActive }.state == .paired)
            #expect(try await waitForStatus(b) { !$0.isActive }.state == .paired)
            let bID = try #require(try await a.runtime.store.devices().first?.id)
            // The ping the agent sends right after pairing is the proof.
            #expect(try await waitUntil(timeout: .seconds(120)) { await a.peers.deviceStates()[bID]?.confirmed == true })
        }
    }
}
