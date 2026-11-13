import CatflapCore
import Crypto
import Foundation
import Tailcat
import Testing

/// Booleans are computed before `#expect` wherever a value could hold an address, a key or a
/// code, because a failed expectation prints its operands.
@Suite(.serialized)
struct PairingTests {
    @Test func testCodeExpiresAfterTenMinutes() async throws {
        #expect(PairingConfiguration().codeLifetime == .seconds(600))
        try await withTestDevices { devices in
            // The default lifetime, as the agent reports it to the command line.
            let standard = try await devices.make("Device A")
            var started = try await standard.pairing.start()
            if started.state == .starting { started = try await waitForStatus(standard) { $0.state != .starting } }
            let lifetime = try #require(started.expiresAt).timeIntervalSinceNow
            #expect(lifetime > 570 && lifetime <= 600)
            _ = await standard.pairing.decline()

            // The same expiry, shortened so the test can watch it happen.
            let short = try await devices.make("Device B") { $0.codeLifetime = .seconds(4) }
            let joiner = try await devices.make("Device C") { $0.dialTimeout = .seconds(6) }
            var expiring = try await short.pairing.start()
            if expiring.state == .starting { expiring = try await waitForStatus(short) { $0.state != .starting } }
            #expect(expiring.state == .waiting)
            let code = try #require(expiring.code)
            let expired = try await waitForStatus(short, timeout: .seconds(10)) { !$0.isActive }
            #expect(expired.state == .failed)
            #expect(expired.error == "The pairing code expired.")
            #expect(expired.code == nil)

            // The throwaway server is gone: the code no longer reaches anything.
            _ = try await joiner.pairing.join(code: code)
            let joined = try await waitForStatus(joiner, timeout: .seconds(20)) { !$0.isActive }
            #expect(joined.state == .failed)
            #expect(joined.digits == nil)
            for device in [short, joiner] {
                #expect(try await device.devices.isEmpty)
                #expect(await device.serverRunning == false)
            }
        }
    }

    @Test func testCodeIsSingleUse() async throws {
        try await withTestDevices { devices in
            let owner = try await devices.make("Device A")
            let first = try await devices.make("Device X")
            let second = try await devices.make("Device B") { $0.dialTimeout = .seconds(8) }

            let code = try await reachDigits(owner, first)
            // Someone else used the code first: the second device cannot get in.
            _ = try await second.pairing.join(code: code)
            let refused = try await waitForStatus(second, timeout: .seconds(30)) { !$0.isActive }
            #expect(refused.state == .failed)
            #expect(refused.digits == nil)
            print("single-use: second device ended with: \(refused.error ?? "no message")")
            // The owner still shows the first device's digits, and only those.
            let ownerStatus = await owner.status
            #expect(ownerStatus.state == .confirm)
            #expect(ownerStatus.peerName == "Device X")
            let sameDigits = ownerStatus.digits == (await first.status).digits
            #expect(sameDigits)

            // Nothing was confirmed, so declining ends it and nothing is stored anywhere. After
            // the second dial, which used the same one-time key, the first device's tunnel was
            // seen to stop delivering, so the first device declines on its own side as well.
            _ = await owner.pairing.decline()
            #expect(try await waitForStatus(owner) { !$0.isActive }.state == .failed)
            let sawDecline = try await waitForStatus(first, timeout: .seconds(10)) { !$0.isActive }.state == .failed
            print("single-use: first device saw the owner's decline within 10 s: \(sawDecline)")
            _ = await first.pairing.decline()
            #expect(try await waitForStatus(first) { !$0.isActive }.state == .failed)
            for device in [owner, first, second] {
                #expect(try await device.devices.isEmpty)
                #expect(await device.serverRunning == false)
            }
            // A used code stays used.
            let later = try await devices.make("Device D") { $0.dialTimeout = .seconds(6) }
            _ = try await later.pairing.join(code: code)
            #expect(try await waitForStatus(later, timeout: .seconds(20)) { !$0.isActive }.state == .failed)
        }
    }

    @Test func testEmptyConnectionDoesNotUseUpThePairingCode() async throws {
        try await withTestDevices { devices in
            let owner = try await devices.make("Device A") { $0.firstFrameTimeout = .seconds(2) }
            let joiner = try await devices.make("Device B")

            var started = try await owner.pairing.start()
            if started.state == .starting { started = try await waitForStatus(owner) { $0.state != .starting } }
            let text = try #require(started.code)
            let code = try #require(PairingCode(text))
            let stranger = try TailcatClient(address: code.address,
                                             key: TailcatKeys(privateKey: code.clientKey, publicKey: "", presharedKey: ""))
            // One connection that ends without a byte, then one that stays silent past the deadline.
            let ended = try await Dialer.dial(stranger, port: PairingProtocol.port, timeout: .seconds(30))
            try await ended.closeWrite(timeout: .seconds(5))
            await ended.close()
            let silent = try await Dialer.dial(stranger, port: PairingProtocol.port, timeout: .seconds(30))
            try await Task.sleep(for: .seconds(3))
            let afterSilence = await owner.status
            #expect(afterSilence.state == .waiting)
            #expect(afterSilence.digits == nil)
            // The owner closed the silent connection without writing to it.
            let silentEnd: Result<Data?, Error> = await Result(catching: { try await silent.read(upTo: 16, timeout: .seconds(10)) })
            switch silentEnd {
            case .success(let data): #expect(data == nil)
            case .failure(let error): #expect((error as? TailcatError)?.code != .timeout)
            }
            await stranger.close()

            _ = try await joiner.pairing.join(code: text)
            let ownerStatus = try await waitForStatus(owner) { $0.state == .confirm || !$0.isActive }
            let joinerStatus = try await waitForStatus(joiner) { $0.state == .confirm || !$0.isActive }
            #expect(ownerStatus.state == .confirm)
            #expect(joinerStatus.state == .confirm)
            #expect(ownerStatus.peerName == "Device B")
            let sameDigits = ownerStatus.digits != nil && ownerStatus.digits == joinerStatus.digits
            #expect(sameDigits)
            _ = await owner.pairing.decline()
            _ = try await waitForStatus(joiner) { !$0.isActive }
        }
    }

    @Test func testSixDigitsChangeWhenEitherHelloChanges() throws {
        func exchangeKey() -> String { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString() }
        let joiner = PairHello(v: 2, deviceID: "device-b", name: "Device B", clientKey: "nodekey:b",
                               exchangeKey: exchangeKey(), build: "0.1.0-dev", nonce: Nonce.make())
        let initiator = PairHello(v: 2, deviceID: "device-a", name: "Device A", clientKey: "nodekey:a",
                                  exchangeKey: exchangeKey(), build: "0.1.0-dev", nonce: Nonce.make())
        let base = PairingDigits.digits(joinerHello: try WireCodec.header(joiner), initiatorHello: try WireCodec.header(initiator))
        #expect(base.count == 6 && base.allSatisfy(\.isNumber))
        #expect(PairingDigits.digits(joinerHello: try WireCodec.header(joiner), initiatorHello: try WireCodec.header(initiator)) == base)

        func variants(_ hello: PairHello) -> [PairHello] {
            var result: [PairHello] = []
            var changed = hello; changed.v += 1; result.append(changed)
            changed = hello; changed.deviceID += "x"; result.append(changed)
            changed = hello; changed.name += "x"; result.append(changed)
            changed = hello; changed.clientKey += "x"; result.append(changed)
            changed = hello; changed.exchangeKey = exchangeKey(); result.append(changed)
            changed = hello; changed.build += "x"; result.append(changed)
            changed = hello; changed.nonce = Nonce.make(); result.append(changed)
            return result
        }
        for changed in variants(joiner) {
            let digits = PairingDigits.digits(joinerHello: try WireCodec.header(changed), initiatorHello: try WireCodec.header(initiator))
            #expect(digits != base)
        }
        for changed in variants(initiator) {
            let digits = PairingDigits.digits(joinerHello: try WireCodec.header(joiner), initiatorHello: try WireCodec.header(changed))
            #expect(digits != base)
        }
        // The roles are part of the hash: swapping the two hellos changes the digits too.
        #expect(PairingDigits.digits(joinerHello: try WireCodec.header(initiator), initiatorHello: try WireCodec.header(joiner)) != base)
        // Fresh nonces give each pairing its own digits.
        var seen = Set<String>()
        for _ in 0..<50 {
            var fresh = initiator
            fresh.nonce = Nonce.make()
            seen.insert(PairingDigits.digits(joinerHello: try WireCodec.header(joiner), initiatorHello: try WireCodec.header(fresh)))
        }
        #expect(seen.count >= 49)
    }

    @Test func testMiddleMachineCannotMatchTheDigits() async throws {
        // Someone handed the joiner a code for a machine of their own, which pairs onward with
        // the initiator: every frame between the two devices passes through it.
        let middle = MiddleBox()
        try await withTestDevices { devices in
            let a = try await devices.make("Device A")
            let b = try await devices.make("Device B") { configuration in
                configuration.transportHook = { transport, role in role == .joiner ? middle.wrap(transport) : transport }
            }
            try await reachDigits(a, b)
            let machine = try #require(middle.machine)
            let (aDigits, bDigits) = (await a.status.digits, await b.status.digits)
            let sameDigits = aDigits == bDigits
            print("middle machine: placed between: \(machine.placedBetween); could search: \(machine.searched); "
                  + "search matched: \(machine.matched); both devices show the same digits: \(sameDigits)")
            // The machine really sat in the middle, and both people see digits to compare.
            #expect(machine.placedBetween)
            #expect(aDigits != nil && bDigits != nil)
            #expect(!sameDigits)
            _ = await a.pairing.decline()
            _ = await b.pairing.decline()
            try await expectNothingStored(a, b)
        }
    }

    @Test func testRevealedHelloMustMatchItsCommitment() async throws {
        // The joiner's hello is changed after its commitment went out.
        let log = TunnelLog()
        let changeReveal: @Sendable (any WireTransport, PairingRole) -> any WireTransport = { transport, role in
            RecordingTransport(inner: transport, role: role, log: log, rewrite: { data in
                guard data.range(of: Data("\"pair_hello\"".utf8)) != nil,
                      let range = data.range(of: Data("Device B".utf8)) else { return data }
                var changed = data
                changed.replaceSubrange(range, with: Data("Device Y".utf8))
                return changed
            })
        }
        try await withTestDevices { devices in
            let a = try await devices.make("Device A")
            let b = try await devices.make("Device B") { $0.transportHook = changeReveal }
            var started = try await a.pairing.start()
            if started.state == .starting { started = try await waitForStatus(a) { $0.state != .starting } }
            _ = try await b.pairing.join(code: try #require(started.code))
            let aEnd = try await waitForStatus(a) { !$0.isActive }
            let bEnd = try await waitForStatus(b) { !$0.isActive }
            #expect(log.frames(.joiner) == ["pair_commit", "pair_hello"])
            #expect(aEnd.state == .failed)
            #expect(aEnd.error == "The other device broke the pairing protocol.")
            // The initiator never showed digits for a hello that broke its commitment.
            #expect(aEnd.digits == nil)
            #expect(bEnd.state == .failed)
            try await expectNothingStored(a, b)
        }
    }

    @Test func testPairKeysAreSealedToTheExchange() async throws {
        // A normal pairing: neither an address nor a share crosses in the clear.
        let log = TunnelLog()
        let record: @Sendable (any WireTransport, PairingRole) -> any WireTransport = { RecordingTransport(inner: $0, role: $1, log: log) }
        try await withTestDevices { devices in
            let a = try await devices.make("Device A") { $0.transportHook = record }
            let b = try await devices.make("Device B") { $0.transportHook = record }
            try await reachDigits(a, b)
            _ = try await a.pairing.confirm()
            _ = try await b.pairing.confirm()
            #expect(try await waitForStatus(a) { !$0.isActive }.state == .paired)
            #expect(try await waitForStatus(b) { !$0.isActive }.state == .paired)
            let aAddress = try #require(try await b.devices.first).address
            let bAddress = try #require(try await a.devices.first).address
            let all = log.written(.initiator) + log.written(.joiner)
            let addressInClear = contains(all, aAddress) || contains(all, bAddress)
            #expect(addressInClear == false)
            let keyFrames = (log.headers(.initiator) + log.headers(.joiner)).filter { $0.type == "pair_keys" }
            #expect(keyFrames.count == 2)
            for frame in keyFrames {
                let object = try headerObject(frame.header)
                #expect(Set(object.keys) == ["type", "box"])
                let sealed = Data(base64Encoded: object["box"] as? String ?? "") ?? Data()
                let readable = sealed.isEmpty || contains(sealed, "address") || contains(sealed, "secret")
                #expect(readable == false)
            }
        }

        // A pair_keys replaced in flight: by a plaintext one, then by a box sealed under another key.
        let replacements: [@Sendable () throws -> Data] = [
            {
                try headerData(["type": "pair_keys", "address": "replaced-address",
                                "secret": SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()])
            },
            {
                let contents = try headerData(["address": "replaced-address",
                                               "secret": SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()])
                let box = try ChaChaPoly.seal(contents, using: SymmetricKey(size: .bits256)).combined
                return try headerData(["type": "pair_keys", "box": box.base64EncodedString()])
            },
        ]
        for replacement in replacements {
            let replaced = TunnelLog()
            let swap: @Sendable (any WireTransport, PairingRole) -> any WireTransport = { transport, role in
                RecordingTransport(inner: transport, role: role, log: replaced, rewrite: { data in
                    guard data.range(of: Data("\"pair_keys\"".utf8)) != nil, let header = try? replacement() else { return data }
                    return (try? WireCodec.frame(header: header)) ?? data
                })
            }
            try await withTestDevices { devices in
                let a = try await devices.make("Device A")
                let b = try await devices.make("Device B") { $0.transportHook = swap }
                try await reachDigits(a, b)
                _ = try await a.pairing.confirm()
                _ = try await b.pairing.confirm()
                let aEnd = try await waitForStatus(a) { !$0.isActive }
                let bEnd = try await waitForStatus(b) { !$0.isActive }
                #expect(replaced.frames(.joiner).contains("pair_keys"))
                #expect(aEnd.state == .failed)
                #expect(aEnd.error == "The other device broke the pairing protocol.")
                #expect(bEnd.state == .failed)
                // Nothing stored, and the key each side added for the exchange taken back.
                try await expectNothingStored(a, b)
            }
        }
    }

    @Test func testNothingPermanentIsSentBeforeBothConfirm() async throws {
        let log = TunnelLog()
        let hook: @Sendable (any WireTransport, PairingRole) -> any WireTransport = { RecordingTransport(inner: $0, role: $1, log: log) }
        try await withTestDevices { devices in
            let a = try await devices.make("Device A") { $0.transportHook = hook }
            let b = try await devices.make("Device B") { $0.transportHook = hook }

            try await reachDigits(a, b)
            #expect(log.frames(.joiner) == ["pair_commit", "pair_hello"])
            #expect(log.frames(.initiator) == ["pair_hello"])
            // Neither device has a permanent server yet, so neither has an address to give away.
            #expect(await a.serverRunning == false)
            #expect(await b.serverRunning == false)

            _ = try await a.pairing.confirm()
            #expect(try await waitForStatus(a) { $0.state == .confirmed }.state == .confirmed)
            try await Task.sleep(for: .seconds(2))
            // One side confirmed: only its confirmation crossed, and still no server runs.
            #expect(log.frames(.initiator) == ["pair_hello", "confirm"])
            #expect(log.frames(.joiner) == ["pair_commit", "pair_hello"])
            #expect(await a.serverRunning == false)
            #expect(await b.serverRunning == false)
            let beforeBoth = log.written(.initiator) + log.written(.joiner)
            for frame in log.headers(.initiator) + log.headers(.joiner) {
                let object = try JSONSerialization.jsonObject(with: frame.header) as? [String: Any] ?? [:]
                #expect(Set(object.keys).isSubset(of: ["type", "v", "commit", "device_id", "name", "client_key",
                                                       "exchange_key", "build", "nonce"]))
            }

            _ = try await b.pairing.confirm()
            #expect(try await waitForStatus(a) { !$0.isActive }.state == .paired)
            #expect(try await waitForStatus(b) { !$0.isActive }.state == .paired)
            #expect(log.frames(.initiator) == ["pair_hello", "confirm", "pair_keys", "pair_done"])
            #expect(log.frames(.joiner) == ["pair_commit", "pair_hello", "confirm", "pair_keys", "pair_done"])

            // The permanent material that crossed afterwards appears nowhere in what crossed before.
            let aRecord = try #require(try await b.devices.first)
            let bRecord = try #require(try await a.devices.first)
            let sameSecret = aRecord.pairSecret == bRecord.pairSecret
            #expect(sameSecret)
            let (aIdentity, bIdentity) = (await a.identity, await b.identity)
            var permanent = [aRecord.address, bRecord.address, aRecord.pairSecret.base64EncodedString()]
            for keys in [aIdentity.serverKeys, aIdentity.clientKeys, bIdentity.serverKeys, bIdentity.clientKeys] {
                permanent += [keys.privateKey, keys.presharedKey]
            }
            let leaked = permanent.contains { contains(beforeBoth, $0) } || beforeBoth.range(of: aRecord.pairSecret) != nil
            #expect(leaked == false)
            // Each device stored the address the other one's server really has.
            let storedAIsLive = sha256(aRecord.address) == sha256(try #require(try await a.runtime.identityServer.address()))
            let storedBIsLive = sha256(bRecord.address) == sha256(try #require(try await b.runtime.identityServer.address()))
            #expect(storedAIsLive)
            #expect(storedBIsLive)
            // Private keys and pre-shared keys never cross at all; the pair secret itself neither.
            let all = log.written(.initiator) + log.written(.joiner)
            let privateSent = [aIdentity, bIdentity].contains { identity in
                [identity.serverKeys, identity.clientKeys].contains { contains(all, $0.privateKey) || contains(all, $0.presharedKey) }
            } || contains(all, aRecord.pairSecret.base64EncodedString())
            #expect(privateSent == false)
        }
    }

    @Test func testMismatchOrOneSidedConfirmStoresNothing() async throws {
        // Digits differ (the initiator's hello is altered on its way to the joiner, which no
        // commitment covers), and the person declines.
        let altered = TunnelLog()
        let tamper: @Sendable (any WireTransport, PairingRole) -> any WireTransport = { transport, role in
            RecordingTransport(inner: transport, role: role, log: altered, rewrite: { data in
                guard let range = data.range(of: Data("Device A".utf8)) else { return data }
                var changed = data
                changed.replaceSubrange(range, with: Data("Device Y".utf8))
                return changed
            })
        }
        try await withTestDevices { devices in
            let a = try await devices.make("Device A") { $0.transportHook = tamper }
            let b = try await devices.make("Device B")
            try await reachDigits(a, b)
            let differ = (await a.status).digits != (await b.status).digits
            #expect(differ)
            _ = try await b.pairing.confirm()
            _ = await a.pairing.decline()
            #expect(try await waitForStatus(a) { !$0.isActive }.state == .failed)
            let bEnd = try await waitForStatus(b) { !$0.isActive }
            #expect(bEnd.state == .failed)
            #expect(bEnd.error == "Pairing was declined on the other device.")
            try await expectNothingStored(a, b)
        }
        // One side confirms, the other declines.
        try await withTestDevices { devices in
            let a = try await devices.make("Device A")
            let b = try await devices.make("Device B")
            try await reachDigits(a, b)
            _ = try await a.pairing.confirm()
            _ = try await waitForStatus(a) { $0.state == .confirmed }
            _ = await b.pairing.decline()
            let aEnd = try await waitForStatus(a) { !$0.isActive }
            #expect(aEnd.state == .failed)
            #expect(aEnd.error == "Pairing was declined on the other device.")
            #expect(try await waitForStatus(b) { !$0.isActive }.state == .failed)
            try await expectNothingStored(a, b)
        }
        // One side confirms, the other never answers: the wait times out.
        try await withTestDevices { devices in
            let a = try await devices.make("Device A")
            let b = try await devices.make("Device B") { $0.confirmTimeout = .seconds(5) }
            try await reachDigits(a, b)
            _ = try await a.pairing.confirm()
            let bEnd = try await waitForStatus(b, timeout: .seconds(20)) { !$0.isActive }
            #expect(bEnd.state == .failed)
            #expect(bEnd.error == "Pairing timed out before both devices confirmed.")
            #expect(try await waitForStatus(a) { !$0.isActive }.state == .failed)
            try await expectNothingStored(a, b)
        }
        // Both confirm, but the connection drops before the joiner's keys go out: each side,
        // whose server already admitted the other for the exchange, takes that back.
        let dropped = TunnelLog()
        let cut: @Sendable (any WireTransport, PairingRole) -> any WireTransport = { transport, role in
            RecordingTransport(inner: transport, role: role, log: dropped, rewrite: { data in
                data.range(of: Data("\"pair_keys\"".utf8)) == nil ? data : nil
            })
        }
        try await withTestDevices { devices in
            let a = try await devices.make("Device A") { $0.exchangeTimeout = .seconds(20) }
            let b = try await devices.make("Device B") { $0.transportHook = cut }
            try await reachDigits(a, b)
            _ = try await a.pairing.confirm()
            _ = try await b.pairing.confirm()
            #expect(try await waitForStatus(a, timeout: .seconds(40)) { !$0.isActive }.state == .failed)
            #expect(try await waitForStatus(b, timeout: .seconds(40)) { !$0.isActive }.state == .failed)
            #expect(dropped.frames(.joiner) == ["pair_commit", "pair_hello", "confirm"])
            try await expectNothingStored(a, b)
        }
    }

    @Test func testPairStatusJSONUsesSnakeCaseAndISO8601() async throws {
        try await withTestDevices { devices in
            let a = try await devices.make("Device A")
            _ = try await a.pairing.start()
            _ = try await waitForStatus(a) { $0.state != .starting }
            // Exactly the payload the agent sends to the command line.
            let response = await a.handle("pair.status")
            #expect(response.ok)
            let object = try #require(try JSONSerialization.jsonObject(with: response.payload) as? [String: Any])
            let snake = object.keys.allSatisfy { $0.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil }
            #expect(snake)
            #expect(Set(object.keys).isSuperset(of: ["state", "role", "code", "expires_at"]))
            let expires = object["expires_at"] as? String ?? ""
            #expect(expires.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", options: .regularExpression) != nil)
            let decoded = try response.decode(PairingStatus.self)
            let lifetime = try #require(decoded.expiresAt).timeIntervalSinceNow
            #expect(lifetime > 570 && lifetime <= 600)
            _ = await a.pairing.decline()
        }
    }

    @Test func testUnpairEndsOpenSessionAndRebuildsServer() async throws {
        try await withTestDevices { devices in
            let a = try await devices.make("Device A")
            let b = try await devices.make("Device B")
            let c = try await devices.make("Device C")
            try await linkDevices(a, b)
            try await linkDevices(a, c)
            let (aID, bID, cID) = (await a.id, await b.id, await c.id)

            TestProgress.mark("B opens a session to A")
            let session = try await b.peers.open(deviceID: aID)
            #expect(try await waitUntil { await a.peers.openConnections(deviceID: bID) == 1 })
            let oldListener = try #require(await a.runtime.identityServer.listener)
            let oldAddress = sha256(try #require(try await a.runtime.identityServer.address()))

            TestProgress.mark("A unpairs B")
            let started = ContinuousClock.now
            let response = await a.handle("unpair", ["device": bID])
            #expect(response.ok)
            let result = try response.decode(UnpairResult.self)
            #expect(result.removed == bID)
            #expect(result.serverRunning == true)

            // The open session ends at once, not at some timeout.
            TestProgress.mark("B reads its ended session")
            let ending: Result<WireFrame?, Error> = await Result(catching: { try await session.connection.readFrame(timeout: .seconds(20)) })
            let endedPromptly = ContinuousClock.now - started < .seconds(10)
            switch ending {
            case .success(let frame): #expect(frame == nil)
            case .failure(let error): #expect((error as? WireError) != .timedOut)
            }
            #expect(endedPromptly)
            await b.peers.release(session)
            #expect(try await waitUntil { await a.peers.openConnections(deviceID: bID) == 0 })

            // The key and secret are gone, and a new server runs for the remaining device.
            #expect(try await a.devices.map(\.id) == [cID])
            let newListener = try #require(await a.runtime.identityServer.listener)
            #expect(newListener !== oldListener)
            let sameAddress = oldAddress == sha256(try #require(try await a.runtime.identityServer.address()))
            #expect(sameAddress)
            TestProgress.mark("C opens a session to the rebuilt A")
            let kept = try await c.peers.open(deviceID: aID, timeout: .seconds(30))
            await c.peers.release(kept)

            // The removed device is cut off.
            TestProgress.mark("B dials A after unpairing")
            await #expect(throws: PeerError.unreachable(device: "Device A", lastSeenBuild: AgentStatus.currentBuild)) {
                _ = try await b.peers.open(deviceID: aID, timeout: .seconds(8))
            }
        }
    }

    @Test func testUnpairingLastDeviceStopsTheServer() async throws {
        try await withTestDevices { devices in
            let a = try await devices.make("Device A")
            let b = try await devices.make("Device B")
            try await linkDevices(a, b)
            let (aID, bID) = (await a.id, await b.id)
            #expect(await a.serverRunning)
            TestProgress.mark("B opens a session to A")
            let session = try await b.peers.open(deviceID: aID)
            #expect(try await waitUntil { await a.peers.openConnections(deviceID: bID) == 1 })

            TestProgress.mark("A unpairs its last device")
            let response = await a.handle("unpair", ["device": "Device B"])
            #expect(response.ok)
            #expect(try response.decode(UnpairResult.self).serverRunning == false)
            #expect(await a.serverRunning == false)
            #expect(await a.runtime.identityServer.listener == nil)
            #expect(try await a.runtime.identityServer.address() == nil)
            #expect(try await a.devices.isEmpty)
            let status = try await a.handle("status").decode(AgentStatus.self)
            #expect(status.serverRunning == false && status.pairedDevices == 0)

            TestProgress.mark("B reads its ended session")
            let ending: Result<WireFrame?, Error> = await Result(catching: { try await session.connection.readFrame(timeout: .seconds(20)) })
            if case .failure(let error) = ending { #expect((error as? WireError) != .timedOut) }
            await b.peers.release(session)
            TestProgress.mark("B dials A after unpairing")
            await #expect(throws: PeerError.self) { _ = try await b.peers.open(deviceID: aID, timeout: .seconds(6)) }
            // Unpairing a device that is not there is refused with a message; still no server.
            let unknown = await a.handle("unpair", ["device": "Device B"])
            #expect(!unknown.ok)
            #expect(unknown.error == "No paired device has that id or name.")
            #expect(await a.serverRunning == false)
        }
    }
}

private func expectNothingStored(_ devices: TestDevice...) async throws {
    for device in devices {
        #expect(try await device.devices.isEmpty)
        // Any key added for the exchange was taken off again: no server admits the peer.
        #expect(try await waitUntil(timeout: .seconds(10)) { await device.serverRunning == false })
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
