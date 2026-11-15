import Foundation
import Synchronization
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct ControlRequest: Codable, Sendable {
    public var command: String
    public var arguments: [String: String]
    public init(_ command: String, arguments: [String: String] = [:]) {
        self.command = command; self.arguments = arguments
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var payload: Data
    public var error: String?
    public var exitCode: Int32
    enum CodingKeys: String, CodingKey {
        case ok, payload, error
        case exitCode = "exit_code"
    }
    public init<T: Encodable>(value: T) throws {
        ok = true; payload = try ControlJSON.encoder.encode(value); error = nil; exitCode = 0
    }
    public init(error: AgentError, exitCode: Int32 = 1) {
        ok = false; payload = Data("null".utf8); self.error = error.rawValue; self.exitCode = exitCode
    }
    /// A refusal with its own sentence for the person, when none of the general errors says it.
    public init(failure message: String, exitCode: Int32 = 1) {
        ok = false; payload = Data("null".utf8); error = message; self.exitCode = exitCode
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try ControlJSON.decoder.decode(type, from: payload) }
}

private enum LocalSocket {
    static let maxFrame = 40 * 1_048_576
    static func create() throws -> Int32 {
        #if os(Linux)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw AgentError.control }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        #if os(macOS)
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentError.control }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return address
    }
    static func owner(_ fd: Int32) -> Bool {
        #if os(Linux)
        // Linux ucred is pid_t, uid_t, gid_t in this order.
        var credentials = [UInt32](repeating: 0, count: 3)
        var length = socklen_t(credentials.count * MemoryLayout<UInt32>.size)
        let code = credentials.withUnsafeMutableBytes { getsockopt(fd, SOL_SOCKET, SO_PEERCRED, $0.baseAddress, &length) }
        return code == 0 && length == 12 && credentials[1] == getuid()
        #else
        var uid: uid_t = 0; var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
        #endif
    }
    /// More bytes than the server's budget for all connections together.
    struct OverBudget: Error {}
    /// How long a frame may take to arrive: five seconds, and one more for each 64 KiB that
    /// has arrived. A large frame that keeps arriving on a busy machine is read whole, and one
    /// that stops is still cut off: a read waits at most five seconds for the next bytes.
    static func frameAllowance(received: Int) -> Duration {
        .seconds(5) + .seconds(Double(received) / 65_536)
    }
    /// Reads one frame of fewer than `limit` bytes. `hold` is asked before each piece is kept,
    /// and may refuse it.
    static func readFrame(_ fd: Int32, limit: Int = maxFrame, hold: (Int) -> Bool = { _ in true }) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let started = ContinuousClock.now
        while data.count < limit && started.duration(to: .now) < frameAllowance(received: data.count) {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw AgentError.control }
            guard hold(count) else { throw OverBudget() }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                guard data.count + newline < limit, newline == count - 1 else { throw AgentError.invalidRequest }
                data.append(contentsOf: buffer[..<newline])
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        throw AgentError.invalidRequest
    }
    /// Writes one frame. Without `waiting`, a send that would have to wait fails at once.
    static func writeFrame(_ data: Data, _ fd: Int32, waiting: Bool = true) throws {
        guard data.count < maxFrame else { throw AgentError.invalidRequest }
        let frame = data + Data([10])
        let pace = waiting ? Int32(0) : Int32(MSG_DONTWAIT)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if os(Linux)
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, pace | Int32(MSG_NOSIGNAL))
                #else
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, pace)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AgentError.control }
                offset += count
            }
        }
    }
    static func configureAccepted(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if os(macOS)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }
}

public enum ControlClient {
    @available(*, noasync, message: "Use requestAsync from asynchronous code.")
    public static func request(_ request: ControlRequest, socket url: URL) throws -> ControlResponse {
        try ControlThread.wait { try perform(request, socket: url) }
    }
    public static func requestAsync(_ request: ControlRequest, socket url: URL) async throws -> ControlResponse {
        try await ControlThread.run { try perform(request, socket: url) }
    }
    private static func perform(_ request: ControlRequest, socket url: URL) throws -> ControlResponse {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK), info.st_mode & 0o077 == 0 else { throw AgentError.control }
        let frame = try ControlJSON.encoder.encode(request)
        let fd = try LocalSocket.create(); defer { close(fd) }
        var address = try LocalSocket.address(url.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, LocalSocket.owner(fd) else { throw AgentError.control }
        do { try LocalSocket.writeFrame(frame, fd) }
        catch AgentError.control {
            // The agent refuses some requests part way through (too large, busy) and closes
            // the connection once it has answered, so the answer may be here although the
            // send failed. Only without one is the agent unreachable.
            guard let reply = try? LocalSocket.readFrame(fd),
                  let response = try? ControlJSON.decoder.decode(ControlResponse.self, from: reply) else { throw AgentError.control }
            return response
        }
        return try ControlJSON.decoder.decode(ControlResponse.self, from: LocalSocket.readFrame(fd))
    }
}

private final class ControlSession: Sendable {
    private struct State: Sendable {
        var fd: Int32
        var stopped = false
        var task: Task<Void, Never>?
        var response: ControlResponse?
    }
    private let state: Mutex<State>
    private let ready = DispatchSemaphore(value: 0)
    init(_ fd: Int32) { state = Mutex(State(fd: fd)) }
    func install(_ task: Task<Void, Never>) {
        let stopped = state.withLock { value in value.task = task; return value.stopped }
        if stopped { task.cancel() }
    }
    func complete(_ response: ControlResponse) {
        let signal = state.withLock { value in
            guard !value.stopped, value.response == nil else { return false }
            value.response = response
            return true
        }
        if signal { ready.signal() }
    }
    func reply() -> ControlResponse? {
        ready.wait()
        return state.withLock { $0.stopped ? nil : $0.response }
    }
    func stop() {
        let task = state.withLock { value -> Task<Void, Never>? in
            guard !value.stopped else { return nil }
            value.stopped = true
            // Keep shutdown and close under the same lock so a reused fd cannot be shut down.
            if value.fd >= 0 { _ = shutdown(value.fd, Int32(SHUT_RDWR)) }
            return value.task
        }
        task?.cancel()
        ready.signal()
    }
    func closeSocket() {
        state.withLock { value in
            if value.fd >= 0 { close(value.fd); value.fd = -1 }
            value.task = nil
        }
    }
}

/// A failure a test makes the control listener see, to prove how it and the agent handle it.
public enum ControlListenerFault: Sendable {
    /// The next `times` accepts fail with `errno`.
    case acceptFails(errno: Int32, times: Int)
    /// After `afterPolls` real polls, the next one fails with `errno`.
    case pollFails(errno: Int32, afterPolls: Int)
}

public final class ControlServer: Sendable {
    /// Bytes for frames and replies larger than `smallFrame`, across all connections: two
    /// connections at a time may hold a near-limit frame; more are refused as busy.
    public static let defaultByteBudget = 2 * LocalSocket.maxFrame
    /// What any connection may hold without a share of the budget. Ordinary requests and
    /// replies are far smaller, and 32 connections hold at most 32 times this.
    public static let smallFrame = 1_048_576
    public static let busy = "The agent is busy with other large requests. Try again in a moment."
    /// The answer to a connection beyond the 32 served at once.
    public static let crowded = "The agent is busy with too many requests at once. Try again in a moment."
    public static let listenerFailure = "The agent's control channel stopped working, so the agent stopped. Start it again."
    private let fd: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let url: URL
    /// The folder's lock, which this server lets go of when `run` ends (or, if it never runs,
    /// when it goes). The lock is freed then unless whoever took it still holds it too, as
    /// the agent does until its runtime has stopped.
    private let folderLock: Mutex<AgentLock?>
    private let byteBudget: Int
    /// The largest request frame read, `LocalSocket.maxFrame` but in tests, which lower it to
    /// reach the refusal of a frame too large without sending 40 MiB.
    private let frameLimit: Int
    private struct State: Sendable {
        var started = false
        var stopped = false
        var failed = false
        var sessions: [UUID: ControlSession] = [:]
        var acceptFaults: (errno: Int32, times: Int)?
        var pollFault: (errno: Int32, afterPolls: Int)?
        var acceptAttempts: [ContinuousClock.Instant] = []
        var small = 0
        var reserved = 0
        var peakReserved = 0
        var refused = 0
        /// The listening socket is closed and its path removed.
        var gaveUpFolder = false
    }
    /// What one connection holds: up to `smallFrame` bytes of its own, or else one whole-frame
    /// reservation from the budget. A frame that grows past `smallFrame` reserves a whole
    /// frame at once, or is refused there; reserving as it grows would let several large
    /// frames fill the budget together and every one of them be refused.
    private struct Holding { var small = 0; var reserved = false }
    private let state = Mutex(State())
    var activeConnections: Int { state.withLock { $0.sessions.count } }
    /// When each accept was tried, for tests.
    var acceptAttempts: [ContinuousClock.Instant] { state.withLock { $0.acceptAttempts } }
    /// Bytes counted for all connections now: their small holdings and reservations.
    var inFlightBytes: Int { state.withLock { $0.small + $0.reserved } }
    /// Budget reserved now, and at most so far.
    var reservedBytes: Int { state.withLock { $0.reserved } }
    var peakReservedBytes: Int { state.withLock { $0.peakReserved } }
    /// Connections refused as busy because the budget was full, counted once they let go.
    var busyRefusals: Int { state.withLock { $0.refused } }
    /// True when the listener ended because it failed, not because it was stopped.
    public var listenerFailed: Bool { state.withLock { $0.failed } }
    public func inject(_ fault: ControlListenerFault) {
        state.withLock { value in
            switch fault {
            case .acceptFails(let code, let times): value.acceptFaults = (code, times)
            case .pollFails(let code, let afterPolls): value.pollFault = (code, afterPolls)
            }
        }
    }
    public convenience init(paths: AgentPaths, lock: AgentLock) throws {
        try self.init(paths: paths, lock: lock, byteBudget: Self.defaultByteBudget)
    }
    init(paths: AgentPaths, lock: AgentLock, byteBudget: Int, frameLimit: Int? = nil) throws {
        folderLock = Mutex<AgentLock?>(lock); url = paths.socket; self.byteBudget = byteBudget
        self.frameLimit = frameLimit ?? LocalSocket.maxFrame
        let descriptor = try LocalSocket.create()
        var wake = [Int32](repeating: -1, count: 2)
        guard pipe(&wake) == 0 else { close(descriptor); throw AgentError.control }
        do {
            for pipeFD in wake { _ = fcntl(pipeFD, F_SETFD, FD_CLOEXEC) }
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            var address = try LocalSocket.address(url.path)
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard info.st_uid == getuid(), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { throw AgentError.unsafePath }
                guard unlink(url.path) == 0 else { throw AgentError.control }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, chmod(url.path, 0o600) == 0, listen(descriptor, 32) == 0 else { throw AgentError.control }
        } catch { close(descriptor); close(wake[0]); close(wake[1]); throw error }
        fd = descriptor; wakeRead = wake[0]; wakeWrite = wake[1]
    }
    deinit {
        close(wakeRead); close(wakeWrite)
        if !state.withLock({ $0.gaveUpFolder }) { close(fd); _ = unlink(url.path) }
    }
    /// Closes the listening socket, removes its path, then lets go of the lock, in that order,
    /// so that a new agent can start in the folder as soon as `run` returns, however long this
    /// object lives on. Without that, a server that a thread of its own still held kept the
    /// folder locked, and its late deinit removed the next server's socket.
    private func giveUpFolder() {
        let first = state.withLock { value in
            guard !value.gaveUpFolder else { return false }
            value.gaveUpFolder = true
            return true
        }
        guard first else { return }
        close(fd); _ = unlink(url.path)
        folderLock.withLock { $0 = nil }
    }

    /// Wakes the dedicated accept thread and interrupts every connection, including handler waits.
    public func stop() {
        let sessions: [ControlSession]? = state.withLock { value in
            guard !value.stopped else { return nil }
            value.stopped = true
            return Array(value.sessions.values)
        }
        guard let sessions else { return }
        sessions.forEach { $0.stop() }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
    }
    /// One JSON-line request per connection; up to 32 independent connection workers, which
    /// together hold at most the byte budget of requests and replies. Returns after `stop()`,
    /// or when the listener fails (`listenerFailed`), which the agent must end on.
    public func run(handler: @escaping @Sendable (ControlRequest) async -> ControlResponse) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let start = state.withLock { value in
                    guard !value.started else { return false }
                    value.started = true
                    return true
                }
                guard start else { continuation.resume(); return }
                Thread.detachNewThread {
                    self.acceptLoop(handler: handler)
                    continuation.resume()
                }
            }
        } onCancel: { self.stop() }
    }
    /// Accept failures that pass: a shortage of descriptors or memory, or a connection that
    /// went away before it was taken. Each is retried after `acceptBackoff`, never at once.
    private static let passingAcceptErrors: Set<Int32> = [EMFILE, ENFILE, ENOBUFS, ENOMEM, ECONNABORTED, EINTR, EAGAIN, EWOULDBLOCK, EPROTO]
    private func acceptLoop(handler: @escaping @Sendable (ControlRequest) async -> ControlResponse) {
        let workers = DispatchGroup()
        var failures = 0
        var failed = false
        while !state.withLock({ $0.stopped }) {
            // An infinite wait on a dedicated thread: no timer or idle polling wake-ups.
            var items = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                         pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            let result = pollListener(&items)
            if result < 0 && errno == EINTR { continue }
            // Anything else wrong with the poll or the listening socket does not pass.
            guard result >= 0 else { failed = true; break }
            if items[1].revents != 0 { break }
            guard items[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { failed = true; break }
            guard items[0].revents & Int16(POLLIN) != 0 else { continue }
            let client = acceptClient()
            if client < 0 {
                guard Self.passingAcceptErrors.contains(errno) else { failed = true; break }
                failures += 1
                if pause(Self.acceptBackoff(failures: failures)) { break }
                continue
            }
            failures = 0
            LocalSocket.configureAccepted(client)
            guard LocalSocket.owner(client) else { close(client); continue }
            let id = UUID()
            let session = ControlSession(client)
            let (admitted, full) = state.withLock { value -> (Bool, Bool) in
                guard !value.stopped else { return (false, false) }
                guard value.sessions.count < 32 else { return (false, true) }
                value.sessions[id] = session
                return (true, false)
            }
            // One connection too many is told so before it is closed, without waiting: the
            // accept loop must never stall on a client. A stopping agent closes without a word,
            // since it no longer answers anything.
            if full { try? LocalSocket.writeFrame(ControlJSON.encoder.encode(ControlResponse(failure: Self.crowded)), client, waiting: false) }
            guard admitted else { close(client); continue }
            workers.enter()
            Thread.detachNewThread {
                var holding = Holding()
                var refused = false
                defer {
                    session.closeSocket()
                    self.release(&holding)
                    self.state.withLock { value in
                        value.sessions.removeValue(forKey: id)
                        if refused { value.refused += 1 }
                    }
                    workers.leave()
                }
                do {
                    let request = try ControlJSON.decoder.decode(ControlRequest.self, from: LocalSocket.readFrame(client, limit: self.frameLimit) { self.hold($0, &holding) })
                    // The frame itself is gone once decoded.
                    if !holding.reserved { self.release(&holding) }
                    let task = Task {
                        let response = await handler(request)
                        session.complete(response)
                    }
                    session.install(task)
                    if let response = session.reply() {
                        let reply = try ControlJSON.encoder.encode(response)
                        // A reply is held while it is written, so a large one needs a reservation too.
                        if self.hold(reply.count, &holding) {
                            try LocalSocket.writeFrame(reply, client)
                        } else {
                            try LocalSocket.writeFrame(ControlJSON.encoder.encode(ControlResponse(failure: Self.busy)), client)
                        }
                    }
                } catch is LocalSocket.OverBudget {
                    refused = true
                    try? LocalSocket.writeFrame(ControlJSON.encoder.encode(ControlResponse(failure: Self.busy)), client)
                } catch {
                    try? LocalSocket.writeFrame(ControlJSON.encoder.encode(ControlResponse(error: .invalidRequest)), client)
                }
            }
        }
        if failed {
            // Nobody will accept on this socket again: remove it at once, so a client fails
            // to connect rather than waiting, and let the agent see that its listener failed.
            // Requests already taken may finish first, for a few seconds.
            state.withLock { $0.failed = true }
            _ = unlink(url.path)
            _ = workers.wait(timeout: .now() + 5)
        }
        stop()
        workers.wait()
        giveUpFolder()
    }
    /// Waits `duration` unless `stop()` is called first; true if it was.
    private func pause(_ duration: Duration) -> Bool {
        var item = pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
        return poll(&item, 1, milliseconds) > 0
    }
    private func pollListener(_ items: inout [pollfd]) -> Int32 {
        let fault = state.withLock { value -> Int32? in
            guard let fault = value.pollFault else { return nil }
            if fault.afterPolls > 0 { value.pollFault = (fault.errno, fault.afterPolls - 1); return nil }
            value.pollFault = nil
            return fault.errno
        }
        if let fault { errno = fault; return -1 }
        return poll(&items, nfds_t(items.count), -1)
    }
    private func acceptClient() -> Int32 {
        let fault = state.withLock { value -> Int32? in
            value.acceptAttempts.append(.now)
            guard let fault = value.acceptFaults, fault.times > 0 else { return nil }
            value.acceptFaults = fault.times > 1 ? (fault.errno, fault.times - 1) : nil
            return fault.errno
        }
        if let fault { errno = fault; return -1 }
        return accept(fd, nil, nil)
    }
    /// How long the listener waits after its `failures`th accept failure in a row: doubling
    /// from 10 ms, at most a second, so a lasting shortage of descriptors costs no CPU.
    static func acceptBackoff(failures: Int) -> Duration {
        .milliseconds(min(10 << min(max(failures - 1, 0), 7), 1000))
    }
    /// Lets a connection hold `count` more bytes: within `smallFrame` freely, beyond it under
    /// a whole-frame reservation, which is refused when the budget has no frame left.
    private func hold(_ count: Int, _ holding: inout Holding) -> Bool {
        if holding.reserved { return true }
        if holding.small + count <= Self.smallFrame {
            holding.small += count
            state.withLock { $0.small += count }
            return true
        }
        let budget = byteBudget, small = holding.small
        let granted = state.withLock { value in
            guard value.reserved + LocalSocket.maxFrame <= budget else { return false }
            value.reserved += LocalSocket.maxFrame
            value.small -= small
            value.peakReserved = max(value.peakReserved, value.reserved)
            return true
        }
        if granted { holding = Holding(small: 0, reserved: true) }
        return granted
    }
    private func release(_ holding: inout Holding) {
        let released = holding
        holding = Holding()
        state.withLock { value in
            value.small -= released.small
            if released.reserved { value.reserved -= LocalSocket.maxFrame }
        }
    }
}
