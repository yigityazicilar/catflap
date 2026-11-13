import CatflapCore
import Crypto
import Foundation
import Synchronization
import Tailcat
import Testing

// Pairing and wire tests open real tailcat tunnels through the public relays, so they need
// internet access. Each simulated device has its own data directory, store and identity.

/// One simulated device: an agent runtime with the pairing and peer services installed.
final class TestDevice: Sendable {
    let paths: AgentPaths
    let runtime: AgentRuntime
    let pairing: PairingService
    let name: String
    var peers: PeerService { pairing.peers }

    private init(paths: AgentPaths, runtime: AgentRuntime, pairing: PairingService, name: String) {
        self.paths = paths; self.runtime = runtime; self.pairing = pairing; self.name = name
    }

    static func make(_ name: String, configure: (inout PairingConfiguration) -> Void = { _ in }) async throws -> TestDevice {
        let paths = try storeTestPaths()
        do {
            TestProgress.mark("make \(name): runtime")
            let runtime = try AgentRuntime(paths: paths)
            var configuration = PairingConfiguration()
            configuration.name = name
            configure(&configuration)
            TestProgress.mark("make \(name): install")
            let pairing = await PairingService.install(on: runtime, configuration: configuration)
            TestProgress.mark("make \(name): start")
            try await runtime.start()
            return TestDevice(paths: paths, runtime: runtime, pairing: pairing, name: name)
        } catch {
            removeStoreTestPaths(paths)
            throw error
        }
    }

    var id: String { get async { await runtime.identityServer.identity.id } }
    var identity: DeviceIdentity { get async { await runtime.identityServer.identity } }
    var devices: [DeviceRecord] { get async throws { try await runtime.store.devices() } }
    var serverRunning: Bool { get async { await runtime.identityServer.isRunning } }
    var status: PairingStatus { get async { await pairing.currentStatus() } }

    /// Stops everything this device started and removes its keys and data.
    func shutdown() async {
        TestProgress.mark("shutdown \(name): decline")
        _ = await pairing.decline()
        TestProgress.mark("shutdown \(name): stop runtime")
        await runtime.stop()
        TestProgress.mark("shutdown \(name): remove data")
        removeStoreTestPaths(paths)
    }

    func handle(_ command: String, _ arguments: [String: String] = [:]) async -> ControlResponse {
        await runtime.handle(.init(command, arguments: arguments))
    }
}

/// The last step a test reached, so a test that does not finish says where it stopped.
final class TestProgress: Sendable {
    @TaskLocal static var current: TestProgress?
    private let step = Mutex("start")
    var last: String { step.withLock { $0 } }
    static func mark(_ text: String) { current?.step.withLock { $0 = text } }
}

/// A guard against a stuck test process. Each tunnel test returns within its limit while
/// Swift's cooperative threads run; one still registered long after that means the process
/// has stopped making progress. A plain thread then reports the stuck tests, whether the
/// cooperative threads still run work, and ends the process so CI prints the output so far.
enum RunWatchdog {
    static let running = Mutex<[String: (since: ContinuousClock.Instant, progress: TestProgress)]>([:])
    static let armed: Bool = {
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 30)
                let stuck = running.withLock { $0.filter { ContinuousClock.now - $0.value.since > .seconds(360) } }
                guard !stuck.isEmpty else { continue }
                let answered = DispatchSemaphore(value: 0)
                Task.detached { answered.signal() }
                let poolAnswers = answered.wait(timeout: .now() + 10) == .success
                var report = "run watchdog: a tunnel test is still running past its limit; cooperative threads answer: \(poolAnswers)\n"
                for (name, entry) in stuck { report += "run watchdog: \(name) at: \(entry.progress.last)\n" }
                FileHandle.standardError.write(Data(report.utf8))
                exit(70)
            }
        }
        return true
    }()
}

private final class Once: Sendable {
    private let claimed = Mutex(false)
    func claim() -> Bool { claimed.withLock { value in defer { value = true }; return !value } }
}

/// Runs a tunnel test with a deadline. A test that has not finished by then is recorded as
/// failed with the last step it reached, and the run goes on without it.
func bounded(_ limit: Duration = .seconds(240), _ body: @escaping @Sendable () async throws -> Void) async throws {
    _ = RunWatchdog.armed
    let progress = TestProgress()
    let name = Test.current?.name ?? "unnamed test"
    RunWatchdog.running.withLock { $0[name] = (ContinuousClock.now, progress) }
    defer { RunWatchdog.running.withLock { $0[name] = nil } }
    let task = Task { try await TestProgress.$current.withValue(progress) { try await body() } }
    let finished: Result<Void, Error>? = await withCheckedContinuation { continuation in
        let once = Once()
        Task {
            let result = await task.result
            if once.claim() { continuation.resume(returning: result) }
        }
        Task {
            try? await Task.sleep(for: limit)
            if once.claim() { continuation.resume(returning: nil) }
        }
    }
    guard let finished else {
        task.cancel()
        Issue.record("Did not finish within \(limit); last step: \(progress.last)")
        return
    }
    try finished.get()
}

/// The devices one test made. Every one is shut down when the test body ends, also on failure.
final class TestDevices: Sendable {
    private let made = Mutex<[TestDevice]>([])
    func make(_ name: String, configure: (inout PairingConfiguration) -> Void = { _ in }) async throws -> TestDevice {
        TestProgress.mark("make \(name)")
        let device = try await TestDevice.make(name, configure: configure)
        made.withLock { $0.append(device) }
        return device
    }
    func shutdown() async {
        for device in made.withLock({ $0 }) {
            TestProgress.mark("shutdown \(device.name)")
            await device.shutdown()
        }
    }
}

func withTestDevices(_ body: @escaping @Sendable (TestDevices) async throws -> Void) async throws {
    try await bounded {
        let devices = TestDevices()
        do {
            try await body(devices)
            await devices.shutdown()
        } catch {
            await devices.shutdown()
            throw error
        }
    }
}

/// Polls until `condition` holds or `timeout` passes, and returns the last status.
@discardableResult
func waitForStatus(_ device: TestDevice, timeout: Duration = .seconds(60),
                   _ condition: (PairingStatus) -> Bool) async throws -> PairingStatus {
    let deadline = ContinuousClock.now + timeout
    while true {
        let status = await device.status
        TestProgress.mark("\(device.name): waiting, pairing state \(status.state.rawValue)")
        if condition(status) || ContinuousClock.now >= deadline { return status }
        try await Task.sleep(for: .milliseconds(100))
    }
}

func waitUntil(timeout: Duration = .seconds(30), _ condition: () async throws -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    let step = TestProgress.current?.last ?? ""
    TestProgress.mark(step + " (waiting for a condition)")
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(100))
    }
    return try await condition()
}

/// Starts a code on `initiator`, joins it from `joiner` and waits until both show digits.
/// Returns the code so a test can reuse it.
@discardableResult
func reachDigits(_ initiator: TestDevice, _ joiner: TestDevice) async throws -> String {
    TestProgress.mark("\(initiator.name): pair start")
    var started = try await initiator.pairing.start()
    if started.state == .starting { started = try await waitForStatus(initiator) { $0.state != .starting } }
    let code = try #require(started.code)
    TestProgress.mark("\(joiner.name): pair join")
    _ = try await joiner.pairing.join(code: code)
    let first = try await waitForStatus(initiator) { $0.state == .confirm || !$0.isActive }
    let second = try await waitForStatus(joiner) { $0.state == .confirm || !$0.isActive }
    #expect(first.state == .confirm)
    #expect(second.state == .confirm)
    return code
}

/// Stores a pairing on both devices directly, through the same allowlist path a pairing uses,
/// without the pairing tunnel. For tests about connections between already paired devices.
func linkDevices(_ a: TestDevice, _ b: TestDevice, build: String = AgentStatus.currentBuild) async throws {
    let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let (aIdentity, bIdentity) = (await a.identity, await b.identity)
    TestProgress.mark("link \(a.name) and \(b.name): server of \(a.name)")
    let aAddress = try await a.peers.preparePairing(clientKey: bIdentity.clientKeys.publicKey)
    TestProgress.mark("link \(a.name) and \(b.name): server of \(b.name)")
    let bAddress = try await b.peers.preparePairing(clientKey: aIdentity.clientKeys.publicKey)
    TestProgress.mark("link \(a.name) and \(b.name): store")
    try await a.peers.commitPairing(DeviceRecord(id: bIdentity.id, name: b.name, clientPublicKey: bIdentity.clientKeys.publicKey,
                                                 address: bAddress, pairSecret: secret, build: build))
    try await b.peers.commitPairing(DeviceRecord(id: aIdentity.id, name: a.name, clientPublicKey: aIdentity.clientKeys.publicKey,
                                                 address: aAddress, pairSecret: secret, build: build))
}

/// Records what one side of the pairing tunnel writes, and can alter it.
final class TunnelLog: Sendable {
    private let state = Mutex<[PairingRole: Data]>([:])
    func append(_ data: Data, _ role: PairingRole) { state.withLock { $0[role, default: Data()].append(data) } }
    func written(_ role: PairingRole) -> Data { state.withLock { $0[role] ?? Data() } }
    /// The frame types `role` wrote, in order.
    func frames(_ role: PairingRole) -> [String] {
        var decoder = FrameDecoder()
        decoder.append(written(role))
        var types: [String] = []
        while let frame = try? decoder.next() { types.append(frame.type) }
        return types
    }
    func headers(_ role: PairingRole) -> [WireFrame] {
        var decoder = FrameDecoder()
        decoder.append(written(role))
        var frames: [WireFrame] = []
        while let frame = try? decoder.next() { frames.append(frame) }
        return frames
    }
}

struct RecordingTransport: WireTransport {
    let inner: any WireTransport
    let role: PairingRole
    let log: TunnelLog
    /// Applied to each write before it is recorded and sent; nil drops the connection.
    var rewrite: (@Sendable (Data) -> Data?)?
    func read(upTo maxLength: Int, timeout: Duration?) async throws -> Data? {
        try await inner.read(upTo: maxLength, timeout: timeout)
    }
    func write(_ data: Data, timeout: Duration?) async throws {
        guard let outgoing = rewrite.map({ $0(data) }) ?? data else {
            await inner.close()
            throw WireError.closed
        }
        log.append(outgoing, role)
        try await inner.write(outgoing, timeout: timeout)
    }
    func closeWrite(timeout: Duration?) async throws { try await inner.closeWrite(timeout: timeout) }
    func close() async { await inner.close() }
}

func contains(_ haystack: Data, _ needle: String) -> Bool {
    !needle.isEmpty && haystack.range(of: Data(needle.utf8)) != nil
}

func sha256(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }

/// Serializes a frame header the way the agent does.
func headerData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

func headerObject(_ header: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: header) as? [String: Any])
}

/// Plays a machine in the middle of the joiner's pairing tunnel. It puts its own client key
/// (and its own exchange key, where hellos carry one) into each hello it passes on, keeps the
/// rest, and chooses the nonce of what it sends: when it knows both hellos one device will
/// hash, it searches nonces until that device's digits equal the other device's.
final class MiddleMachine: WireTransport, Sendable {
    /// The commitment the agent sends first: SHA-256 over this label and the hello's bytes.
    static let commitLabel = "catflap-pair-commit-v1"
    let inner: any WireTransport
    let clientKey: String
    let exchangeKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    private struct State {
        var incoming = FrameDecoder()
        var pending = Data()
        var joinerHello: Data?
        var forgedJoinerHello: Data?
        var forgedInitiatorHello: Data?
        var searched = false
        var matched = false
    }
    private let state = Mutex(State())

    init(_ inner: any WireTransport) {
        self.inner = inner
        clientKey = (try? TailcatKeys.generate().publicKey) ?? "nodekey:middle"
    }

    /// Whether it sat in both directions: it sent each device a hello of its own.
    var placedBetween: Bool { state.withLock { $0.forgedJoinerHello != nil && $0.forgedInitiatorHello != nil } }
    /// Whether it could search, and whether the search made the digits equal.
    var searched: Bool { state.withLock { $0.searched } }
    var matched: Bool { state.withLock { $0.matched } }

    func read(upTo maxLength: Int, timeout: Duration?) async throws -> Data? {
        while true {
            let ready: Data? = state.withLock { s in
                guard !s.pending.isEmpty else { return nil }
                let out = Data(s.pending.prefix(maxLength))
                s.pending = Data(s.pending.dropFirst(out.count))
                return out
            }
            if let ready { return ready }
            guard let chunk = try await inner.read(upTo: maxLength, timeout: timeout) else { return nil }
            try state.withLock { s in
                s.incoming.append(chunk)
                while let frame = try s.incoming.next() { s.pending.append(try fromInitiator(frame, &s)) }
            }
        }
    }

    func write(_ data: Data, timeout: Duration?) async throws {
        var decoder = FrameDecoder()
        decoder.append(data)
        var out = Data()
        while let frame = try decoder.next() {
            out.append(try state.withLock { try fromJoiner(frame, &$0) })
        }
        try await inner.write(out, timeout: timeout)
    }

    func closeWrite(timeout: Duration?) async throws { try await inner.closeWrite(timeout: timeout) }
    func close() async { await inner.close() }

    private func forge(_ header: Data) throws -> Data {
        var object = try headerObject(header)
        object["client_key"] = clientKey
        if object["exchange_key"] != nil { object["exchange_key"] = exchangeKey }
        object["nonce"] = Nonce.make()
        return try headerData(object)
    }

    private func fromJoiner(_ frame: WireFrame, _ s: inout State) throws -> Data {
        switch frame.type {
        case "pair_commit":
            // It must commit before it sees either hello, so it makes one up.
            var commit = try headerObject(frame.header)
            if s.forgedJoinerHello == nil {
                s.forgedJoinerHello = try headerData([
                    "type": "pair_hello", "v": commit["v"] ?? 2, "device_id": UUID().uuidString, "name": "Device B",
                    "client_key": clientKey, "exchange_key": exchangeKey, "build": AgentStatus.currentBuild,
                    "nonce": Nonce.make(),
                ])
            }
            var input = Data(Self.commitLabel.utf8)
            input.append(s.forgedJoinerHello!)
            commit["commit"] = Data(SHA256.hash(data: input)).base64EncodedString()
            return try WireCodec.frame(header: headerData(commit))
        case "pair_hello":
            s.joinerHello = frame.header
            if s.forgedJoinerHello == nil { s.forgedJoinerHello = try forge(frame.header) }
            return try WireCodec.frame(header: s.forgedJoinerHello!)
        default:
            return try WireCodec.frame(header: frame.header)
        }
    }

    private func fromInitiator(_ frame: WireFrame, _ s: inout State) throws -> Data {
        guard frame.type == "pair_hello" else { return try WireCodec.frame(header: frame.header) }
        var forged = try forge(frame.header)
        if let joinerHello = s.joinerHello, let forgedJoiner = s.forgedJoinerHello {
            // The joiner hashes (its hello, this one); the initiator hashes (the forged joiner
            // hello, its own). Both are known here, so search for equal digits.
            s.searched = true
            let target = PairingDigits.digits(joinerHello: forgedJoiner, initiatorHello: frame.header)
            if let found = try search(joinerHello: joinerHello, initiatorHello: forged, target: target),
               PairingDigits.digits(joinerHello: joinerHello, initiatorHello: found) == target {
                forged = found
                s.matched = true
            }
        }
        s.forgedInitiatorHello = forged
        return try WireCodec.frame(header: forged)
    }

    /// Tries nonces for `initiatorHello` until the digits of (joiner, it) equal `target`.
    private func search(joinerHello: Data, initiatorHello: Data, target: String) throws -> Data? {
        let placeholder = String(repeating: "A", count: 43) + "="
        var object = try headerObject(initiatorHello)
        object["nonce"] = placeholder
        let template = try headerData(object)
        guard let range = template.range(of: Data(placeholder.utf8)), let wanted = UInt64(target) else { return nil }
        var prefix = Data("catflap-pair-v1".utf8)
        for part in [joinerHello, template] {
            var length = UInt32(part.count).bigEndian
            prefix.append(Data(bytes: &length, count: 4))
            if part == template { prefix.append(template[..<range.lowerBound]) } else { prefix.append(part) }
        }
        let suffix = [UInt8](template[range.upperBound...])
        var base = SHA256()
        base.update(data: prefix)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var nonce = Array(placeholder.utf8)
        for attempt in 0..<UInt64(60_000_000) {
            var rest = attempt
            for index in 0..<6 { nonce[index] = alphabet[Int(rest & 63)]; rest >>= 6 }
            var hasher = base
            hasher.update(data: nonce)
            hasher.update(data: suffix)
            let value = hasher.finalize().withUnsafeBytes { $0.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            if value % 1_000_000 == wanted {
                object["nonce"] = String(decoding: nonce, as: UTF8.self)
                return try headerData(object)
            }
        }
        return nil
    }
}

/// Holds the middle machine a transport hook made, for the test to inspect.
final class MiddleBox: Sendable {
    private let made = Mutex<MiddleMachine?>(nil)
    var machine: MiddleMachine? { made.withLock { $0 } }
    func wrap(_ transport: any WireTransport) -> any WireTransport {
        let machine = MiddleMachine(transport)
        made.withLock { $0 = machine }
        return machine
    }
}
