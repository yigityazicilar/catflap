import CatflapCore
import Foundation
import Synchronization
import Testing

/// An initiator transport whose `close()` does not reach the other side until the test
/// releases it (a hang guard ends it after 60 s), while `closeWrite()` does: what a tunnel
/// torn down before its close went out looks like to the joiner.
final class HeldCloseTransport: WireTransport, @unchecked Sendable {
    let inner: any WireTransport
    let release: TestSignal
    init(inner: any WireTransport, release: TestSignal) { self.inner = inner; self.release = release }
    func read(upTo maxLength: Int, timeout: Duration?) async throws -> Data? { try await inner.read(upTo: maxLength, timeout: timeout) }
    func write(_ data: Data, timeout: Duration?) async throws { try await inner.write(data, timeout: timeout) }
    func closeWrite(timeout: Duration?) async throws { try await inner.closeWrite(timeout: timeout) }
    func close() async {
        let release = release
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ClaimOnce()
            Task { await release.wait(); if once.claim() { continuation.resume() } }
            Task { try? await Task.sleep(for: .seconds(60)); if once.claim() { continuation.resume() } }
        }
        await inner.close()
    }
}

/// An initiator that refuses the joiner's reveal tells the joiner by ending its side of the
/// stream, as the confirmation path does, not only by tearing the tunnel down.
@Suite struct PairingHangUpTests {
    @Test func testRejectedRevealReachesTheJoinerWithoutTheTunnelClose() async throws {
        let joinerEnded = TestSignal()
        defer { joinerEnded.fire() }
        let holdClose: @Sendable (any WireTransport, PairingRole) -> any WireTransport = { transport, _ in
            HeldCloseTransport(inner: transport, release: joinerEnded)
        }
        // The joiner's hello is changed after its commitment went out.
        let changeReveal: @Sendable (any WireTransport, PairingRole) -> any WireTransport = { transport, role in
            RecordingTransport(inner: transport, role: role, log: TunnelLog(), rewrite: { data in
                guard data.range(of: Data("\"pair_hello\"".utf8)) != nil,
                      let range = data.range(of: Data("Device B".utf8)) else { return data }
                var changed = data
                changed.replaceSubrange(range, with: Data("Device Y".utf8))
                return changed
            })
        }
        try await withTestDevices { devices in
            let a = try await devices.make("Device A") { $0.transportHook = holdClose }
            let b = try await devices.make("Device B") { $0.transportHook = changeReveal }
            var started = try await a.pairing.start()
            if started.state == .starting { started = try await waitForStatus(a) { $0.state != .starting } }
            _ = try await b.pairing.join(code: try #require(started.code))
            // The joiner ends while the initiator's close is still held: the hang-up was the
            // end of the initiator's stream. The wait is a hang guard.
            let bEnd = try await waitForStatus(b, timeout: .seconds(45)) { !$0.isActive }
            joinerEnded.fire()
            #expect(bEnd.state == .failed, "joiner still \(bEnd.state.rawValue) while the initiator's close is held")
            #expect(bEnd.error == "The connection to the other device was lost.")
            let aEnd = try await waitForStatus(a) { !$0.isActive }
            #expect(aEnd.state == .failed && aEnd.error == "The other device broke the pairing protocol.")
            // The initiator never showed digits for a hello that broke its commitment.
            let noInitiatorDigits = aEnd.digits == nil
            #expect(noInitiatorDigits)
            let aStored = try await a.runtime.store.devices(), bStored = try await b.runtime.store.devices()
            #expect(aStored.isEmpty && bStored.isEmpty)
        }
    }
}
