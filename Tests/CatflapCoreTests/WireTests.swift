import CatflapCore
import Foundation
import Tailcat
import Testing

@Suite(.serialized)
struct WireTests {
    @Test func testOtherProtocolVersionReportsUpdateNeeded() async throws {
        try await withTestDevices { devices in
            let a = try await devices.make("Device A")
            let b = try await devices.make("Device B")
            try await linkDevices(a, b)
            let (aID, bID) = (await a.id, await b.id)
            // The tunnel works and A speaks another version: A answers `mismatch` and closes.
            await a.peers.setVersion(WireProtocol.version + 1)
            let error = await #expect(throws: PeerError.self) { _ = try await b.peers.open(deviceID: aID) }
            #expect(error == .updateNeeded(device: "Device A"))
            #expect(error?.errorDescription == "Update Catflap on Device A")
            #expect(await a.peers.openConnections(deviceID: bID) == 0)
            // The same message reaches the command line through the agent.
            let check = await b.handle("pair.check", ["device": aID, "start": "1"])
            #expect(check.ok)
            #expect(try await waitUntil { (try? await b.handle("pair.check", ["device": aID]).decode(PairingService.CheckStatus.self).state) != "running" })
            let reported = try await b.handle("pair.check", ["device": aID]).decode(PairingService.CheckStatus.self)
            #expect(reported == .init(state: "failed", error: "Update Catflap on Device A"))
            // With the versions equal again the same pair connects.
            await a.peers.setVersion(WireProtocol.version)
            let session = try await b.peers.open(deviceID: aID)
            await b.peers.release(session)
        }
        // During pairing as well: the joiner is told to update the other device.
        try await withTestDevices { devices in
            let a = try await devices.make("Device A") { $0.version = WireProtocol.version + 1 }
            let b = try await devices.make("Device B")
            var started = try await a.pairing.start()
            if started.state == .starting { started = try await waitForStatus(a) { $0.state != .starting } }
            _ = try await b.pairing.join(code: try #require(started.code))
            let joiner = try await waitForStatus(b) { !$0.isActive }
            #expect(joiner.state == .failed)
            #expect(joiner.error == "Update Catflap on the other device")
            let owner = try await waitForStatus(a) { !$0.isActive }
            // The joiner's first frame is only a commitment, so its name is not known yet.
            #expect(owner.error == "Update Catflap on the other device")
            #expect(try await a.devices.isEmpty)
            #expect(try await b.devices.isEmpty)
        }
    }

    @Test func testUnreachablePeerMessageNamesLastSeenBuild() async throws {
        try await withTestDevices { devices in
            let a = try await devices.make("Device A") { $0.build = "0.0.9" }
            let b = try await devices.make("Device B")
            try await linkDevices(a, b, build: "0.0.7")
            let (aID, bID) = (await a.id, await b.id)
            // A connects to B once: B records the build A said hello with.
            let session = try await a.peers.open(deviceID: bID)
            await a.peers.release(session)
            #expect(try await waitUntil { try await b.devices.first?.build == "0.0.9" })

            // A goes offline; no tunnel forms, so no version can be read.
            await a.runtime.stop()
            let started = ContinuousClock.now
            let error = await #expect(throws: PeerError.self) { _ = try await b.peers.open(deviceID: aID, timeout: .seconds(6)) }
            let elapsed = ContinuousClock.now - started
            #expect(error?.errorDescription == "Cannot reach Device A: asleep, offline, or on an older Catflap (last seen on build 0.0.9)")
            // Every attempt shares the one deadline, so the failure comes inside it.
            #expect(elapsed < .seconds(9))
        }
    }

    @Test func testFrameDecoderRefusesOversizeAndMalformedHeaders() throws {
        var decoder = FrameDecoder()
        decoder.append(Data([0x00, 0x01, 0x00, 0x01]))
        #expect(throws: WireError.frameTooLarge) { _ = try decoder.next() }
        var empty = FrameDecoder()
        empty.append(Data([0, 0, 0, 0]))
        #expect(throws: WireError.emptyFrame) { _ = try empty.next() }
        var notObject = FrameDecoder()
        notObject.append(try WireCodec.frame(header: Data("[1]".utf8)))
        #expect(throws: WireError.malformed) { _ = try notObject.next() }
        var split = FrameDecoder()
        let frame = try WireCodec.frame(Mismatch(v: 3))
        split.append(frame.prefix(3))
        #expect(try split.next() == nil)
        split.append(frame.dropFirst(3))
        let decoded = try #require(try split.next())
        #expect(try decoded.decode(Mismatch.self).v == 3)
        #expect(throws: WireError.unexpected("mismatch")) { _ = try decoded.decode(OK.self) }
    }
}
