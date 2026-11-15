import CatflapCore
import Foundation
import Synchronization
import Testing

/// One direction of a `MemoryPipe`: bytes written at one end, read at the other.
actor PipeBuffer {
    private var data = Data()
    private var closed = false
    private var waiter: CheckedContinuation<Void, Never>?
    func append(_ bytes: Data) throws {
        guard !closed else { throw WireError.closed }
        data.append(bytes); wake()
    }
    func close() { closed = true; wake() }
    func poke() { wake() }
    private func wake() { waiter?.resume(); waiter = nil }
    func take(upTo maxLength: Int, timeout: Duration?) async throws -> Data? {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        while data.isEmpty && !closed {
            if let deadline, ContinuousClock.now >= deadline { throw WireError.timedOut }
            let timer = Task { [weak self] in
                try? await Task.sleep(until: deadline ?? .now + .seconds(3600))
                await self?.poke()
            }
            await withCheckedContinuation { waiter = $0 }
            timer.cancel()
        }
        guard !data.isEmpty else { return nil }
        let chunk = Data(data.prefix(maxLength)); data.removeFirst(chunk.count)
        return chunk
    }
}

/// One end of a pipe: reads what the other end writes.
struct PipeEnd: WireTransport {
    let incoming: PipeBuffer, outgoing: PipeBuffer
    func read(upTo maxLength: Int, timeout: Duration?) async throws -> Data? { try await incoming.take(upTo: maxLength, timeout: timeout) }
    func write(_ data: Data, timeout: Duration?) async throws { try await outgoing.append(data) }
    func closeWrite(timeout: Duration?) async throws { await outgoing.close() }
    func close() async { await outgoing.close(); await incoming.close() }
}
/// Two connected `WireTransport` ends, in memory.
enum MemoryPipe {
    static func make() -> (PipeEnd, PipeEnd) {
        let ab = PipeBuffer(), ba = PipeBuffer()
        return (PipeEnd(incoming: ba, outgoing: ab), PipeEnd(incoming: ab, outgoing: ba))
    }
}

/// What a `FaultTransport` does to a frame of one type.
enum FaultRule: Sendable, Equatable {
    case none
    /// The write of the first frame of this type throws: after forwarding it (the frame arrived,
    /// the writer cannot know) or before (it never left).
    case failWrite(frame: String, delivered: Bool)
    /// The connection breaks once this many payload bytes went through: they arrive, the
    /// rest does not.
    case cutAfterPayload(Int64)
}

/// Wraps a transport and records the type of each frame written through it, in order; raw
/// payload bytes are recorded as `payload`. Fails one write by its rule.
final class FaultTransport: WireTransport, @unchecked Sendable {
    let inner: any WireTransport
    private let state: Mutex<(rule: FaultRule, written: [String], payloadBytes: Int64)>
    init(wrapping inner: any WireTransport, rule: FaultRule = .none) { self.inner = inner; state = Mutex((rule, [], 0)) }
    var written: [String] { state.withLock { $0.written } }
    var payloadBytes: Int64 { state.withLock { $0.payloadBytes } }
    func read(upTo maxLength: Int, timeout: Duration?) async throws -> Data? { try await inner.read(upTo: maxLength, timeout: timeout) }
    func write(_ data: Data, timeout: Duration?) async throws {
        var decoder = FrameDecoder(); decoder.append(data)
        var types: [String] = []
        while let frame = try? decoder.next() { types.append(frame.type) }
        if types.isEmpty { types = ["payload"] }
        let cut: Int? = state.withLock { s in
            guard types == ["payload"], case .cutAfterPayload(let limit) = s.rule, s.payloadBytes + Int64(data.count) > limit else { return nil }
            s.rule = .none
            let keep = Int(limit - s.payloadBytes); s.payloadBytes = limit; s.written.append("payload")
            return keep
        }
        if let cut {
            if cut > 0 { try await inner.write(data.prefix(cut), timeout: timeout) }
            await inner.close()
            throw WireError.closed
        }
        let fail: Bool? = state.withLock { s in
            if types == ["payload"] { s.payloadBytes += Int64(data.count) }
            s.written += types
            if case .failWrite(let type, let delivered) = s.rule, types.contains(type) { s.rule = .none; return delivered }
            return nil
        }
        if fail == true { try await inner.write(data, timeout: timeout) }
        if fail != nil { throw WireError.closed }
        try await inner.write(data, timeout: timeout)
    }
    func closeWrite(timeout: Duration?) async throws { try await inner.closeWrite(timeout: timeout) }
    func close() async { await inner.close() }
}

/// A connector whose links reach a receiving `TransferService` in this process over a memory
/// pipe. Its ping fails until the test says the device is here, and it counts pings in flight.
/// A transport that, once a frame of one type has been written through it (the other side can
/// read it), waits for `gate` before the write returns.
struct HoldAfterWrite: WireTransport {
    let inner: any WireTransport
    let frame: String
    let gate: @Sendable () async -> Void
    func read(upTo maxLength: Int, timeout: Duration?) async throws -> Data? { try await inner.read(upTo: maxLength, timeout: timeout) }
    func write(_ data: Data, timeout: Duration?) async throws {
        try await inner.write(data, timeout: timeout)
        var decoder = FrameDecoder(); decoder.append(data)
        var types: [String] = []
        while let decoded = try? decoder.next() { types.append(decoded.type) }
        if types.contains(frame) { await gate() }
    }
    func closeWrite(timeout: Duration?) async throws { try await inner.closeWrite(timeout: timeout) }
    func close() async { await inner.close() }
}

final class LoopbackConnector: PeerConnector, @unchecked Sendable {
    let receiver: TransferService
    let senderID: String
    struct State {
        var here = true
        /// Links that fail as a dial past its limit does, before any succeeds.
        var slowDials = 0
        var rule: FaultRule = .none
        var links: [FaultTransport] = []
        var pings = 0, inFlight = 0, maxInFlight = 0
        var pingGate: (@Sendable () async -> Void)?
        var receiverHold: (frame: String, gate: @Sendable () async -> Void)?
    }
    private let state: Mutex<State>
    init(receiver: TransferService, as senderID: String, here: Bool = true) {
        self.receiver = receiver; self.senderID = senderID
        var s = State(); s.here = here
        state = Mutex(s)
    }
    func setHere(_ here: Bool) { state.withLock { $0.here = here } }
    func slowDials(_ count: Int) { state.withLock { $0.slowDials = count } }
    func failNext(_ rule: FaultRule) { state.withLock { $0.rule = rule } }
    func setPingGate(_ gate: (@Sendable () async -> Void)?) { state.withLock { $0.pingGate = gate } }
    /// Holds the receiver right after it has written its next frame of this type, until `gate` returns.
    func holdReceiver(after frame: String, _ gate: @escaping @Sendable () async -> Void) { state.withLock { $0.receiverHold = (frame, gate) } }
    var links: [FaultTransport] { state.withLock { $0.links } }
    var pings: Int { state.withLock { $0.pings } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }

    func link(deviceID: String, timeout: Duration) async throws -> PeerLink {
        let (here, rule, slow) = state.withLock { s -> (Bool, FaultRule, Bool) in
            let slow = s.slowDials > 0; if slow { s.slowDials -= 1 }
            return (s.here, s.rule, slow)
        }
        if slow { throw PeerError.unreachable(device: "Device B", lastSeenBuild: "test") }
        guard here else { throw PeerError.unreachable(device: "Device B", lastSeenBuild: "test") }
        let (near, far) = MemoryPipe.make()
        let receiver = receiver, senderID = senderID
        let hold = state.withLock { s -> (frame: String, gate: @Sendable () async -> Void)? in defer { s.receiverHold = nil }; return s.receiverHold }
        let receiving: any WireTransport = hold.map { HoldAfterWrite(inner: far, frame: $0.frame, gate: $0.gate) } ?? far
        Task { await receiver.receive(deviceID: senderID, connection: WireConnection(receiving)) }
        let fault = FaultTransport(wrapping: near, rule: rule)
        state.withLock { $0.rule = .none; $0.links.append(fault) }
        return PeerLink(deviceID: deviceID, deviceName: "Device B", connection: WireConnection(fault)) { await near.close() }
    }
    func ping(deviceID: String, timeout: Duration) async throws -> PeerPing {
        let gate = state.withLock { s -> (@Sendable () async -> Void)? in
            s.pings += 1; s.inFlight += 1; s.maxInFlight = max(s.maxInFlight, s.inFlight)
            return s.pingGate
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        await gate?()
        guard state.withLock({ $0.here }) else { throw PeerError.unreachable(device: "Device B", lastSeenBuild: "test") }
        return PeerPing(latency: .milliseconds(1), path: .direct)
    }
}

/// A clock the test moves by hand, for backoff and expiry.
final class TestClock: TransferClock, @unchecked Sendable {
    private let current: Mutex<Date>
    init(_ start: Date = Date()) { current = Mutex(start) }
    func now() -> Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// A sender and a receiver in one process, joined by a `LoopbackConnector`. The sender knows
/// the receiver as paired device `receiver`; the receiver knows the sender as `sender`.
struct LoopbackPair: Sendable {
    let sender: TransferFixture
    let receiver: TransferFixture
    let senderService: TransferService
    let connector: LoopbackConnector
    let clock: TestClock
    static let receiverID = "receiver"
    init(here: Bool = true, limits: TransferLimits = .init(), receiverLimits: TransferLimits = .init()) async throws {
        receiver = try TransferFixture(limits: receiverLimits)
        sender = try TransferFixture(limits: limits)
        connector = LoopbackConnector(receiver: receiver.service, as: "sender", here: here)
        clock = TestClock()
        senderService = TransferService(store: sender.store, inbox: sender.inbox, limits: limits, connector: connector, clock: clock)
        try await sender.store.saveDevice(DeviceRecord(id: Self.receiverID, name: "Device B", clientPublicKey: "", address: "", pairSecret: Data(), build: "test"))
    }
    func row(_ id: String) async throws -> TransferRecord? { try await senderService.status(deviceID: Self.receiverID, id: id) }
    func received() async throws -> [TransferRecord] { try await receiver.service.history.rows() }
    func inboxEntries() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: receiver.inbox.directory.path).sorted() }
    func cleanup() { sender.cleanup(); receiver.cleanup() }
}
