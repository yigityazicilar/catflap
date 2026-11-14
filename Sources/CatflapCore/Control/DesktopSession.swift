#if os(Linux)
import Foundation
import Glibc
import Synchronization

/// A separate, owner-authenticated desktop session. The ordinary control server is unchanged.
/// One I/O thread owns descriptors. Producers only enqueue bounded writes and wake that thread.
public final class DesktopSession: Sendable {
    public static let frameLimit = 40 * 1_048_576
    private struct State: Sendable {
        var stopped = false
        var connected = false
        var generation: UInt64 = 0
        var output = Data()
        var disconnect = false
        var tasks: [UUID: Task<Void, Never>] = [:]
    }
    private let state = Mutex(State())
    private let listener: Int32
    private let wake: [Int32]
    private let path: String
    private let ended = DispatchGroup()
    public var connected: Bool { state.withLock { $0.connected } }

    public init(path: URL) throws {
        self.path = path.path
        listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue | SOCK_NONBLOCK.rawValue), 0)
        guard listener >= 0 else { throw AgentError.control }
        var pipeFDs = [Int32](repeating: -1, count: 2)
        guard pipe(&pipeFDs) == 0 else { close(listener); throw AgentError.control }
        wake = pipeFDs
        do {
            for fd in wake { _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
            var info = stat()
            if lstat(self.path, &info) == 0 {
                guard info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), unlink(self.path) == 0 else {
                    throw AgentError.unsafePath
                }
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(self.path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentError.control }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0, chmod(self.path, 0o600) == 0, listen(listener, 4) == 0 else { throw AgentError.control }
        } catch { close(listener); wake.forEach { close($0) }; throw error }
    }
    deinit { close(listener); wake.forEach { close($0) }; _ = unlink(path) }

    @discardableResult
    public func send(_ data: Data) -> Bool { enqueue(data, generation: nil) }
    private func enqueue(_ data: Data, generation: UInt64?) -> Bool {
        let accepted = state.withLock { value in
            guard !value.stopped, value.connected, generation == nil || generation == value.generation else { return false }
            guard data.count < Self.frameLimit, value.output.count + data.count + 1 <= Self.frameLimit else {
                value.disconnect = true; return false
            }
            value.output.append(data); value.output.append(10)
            return true
        }
        signal()
        return accepted
    }
    private func signal() { var byte: UInt8 = 1; _ = write(wake[1], &byte, 1) }
    public func start(changed: @escaping @Sendable (Bool) async -> Void,
                      handler: @escaping @Sendable (Data) async -> Data) {
        ended.enter()
        Thread.detachNewThread { [self] in run(changed: changed, handler: handler); ended.leave() }
    }
    public func stop() async {
        state.withLock { $0.stopped = true }
        signal()
        await withCheckedContinuation { done in ended.notify(queue: .global()) { done.resume() } }
    }
    private func run(changed: @escaping @Sendable (Bool) async -> Void,
                     handler: @escaping @Sendable (Data) async -> Data) {
        var client: Int32 = -1
        var input = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var lastProgress = ContinuousClock.now
        func disconnect() {
            guard client >= 0 else { return }
            close(client); client = -1; input.removeAll(keepingCapacity: false)
            let tasks = state.withLock { value in
                value.connected = false; value.generation &+= 1; value.output = Data(); value.disconnect = false
                let tasks = Array(value.tasks.values); value.tasks = [:]; return tasks
            }
            tasks.forEach { $0.cancel() }
            // Preserve connection-transition order without blocking the I/O thread on async work.
            Task { await changed(false) }
        }
        defer { disconnect() }
        while !state.withLock({ $0.stopped }) {
            if state.withLock({ $0.disconnect }) { disconnect() }
            let writing = state.withLock { !$0.output.isEmpty }
            if !writing { lastProgress = .now }
            var fds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0),
                       pollfd(fd: client, events: Int16(POLLIN) | (writing ? Int16(POLLOUT) : 0), revents: 0)]
            let polled = poll(&fds, nfds_t(fds.count), writing ? 1000 : -1)
            if polled < 0 { if errno == EINTR { continue }; break }
            if writing && ContinuousClock.now - lastProgress > .seconds(5) { disconnect(); continue }
            if fds[1].revents != 0 { while read(wake[0], &buffer, buffer.count) > 0 {} }
            if fds[0].revents & Int16(POLLIN) != 0 {
                let next = accept(listener, nil, nil)
                if next >= 0 {
                    _ = fcntl(next, F_SETFD, FD_CLOEXEC); _ = fcntl(next, F_SETFL, O_NONBLOCK)
                    var credentials = [UInt32](repeating: 0, count: 3)
                    var size: socklen_t = 12
                    let valid = credentials.withUnsafeMutableBytes { getsockopt(next, SOL_SOCKET, SO_PEERCRED, $0.baseAddress, &size) }
                    if valid == 0, size == 12, credentials[1] == getuid() {
                        disconnect(); client = next
                        state.withLock { $0.connected = true; $0.generation &+= 1 }
                        Task { await changed(true) }
                        continue
                    } else { close(next) }
                }
            }
            guard client >= 0 else { continue }
            if fds[2].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { disconnect(); continue }
            if fds[2].revents & Int16(POLLIN) != 0 {
                let count = recv(client, &buffer, buffer.count, 0)
                if count <= 0 { if count == 0 || (errno != EAGAIN && errno != EINTR) { disconnect() }; continue }
                input.append(contentsOf: buffer.prefix(count))
                while let newline = input.firstIndex(of: 10) {
                    let frame = Data(input[..<newline]); input.removeSubrange(...newline)
                    guard frame.count < Self.frameLimit else { disconnect(); break }
                    let id = UUID()
                    let generation = state.withLock { $0.generation }
                    let admitted = state.withLock { value -> Bool in
                        guard value.tasks.count < 16 else { return false }
                        // Register under the lock: a fast handler cannot finish before its
                        // task is registered and leave a stale entry consuming the limit.
                        value.tasks[id] = Task { [self] in
                            let reply = await handler(frame)
                            if !Task.isCancelled { _ = enqueue(reply, generation: generation) }
                            _ = state.withLock { $0.tasks.removeValue(forKey: id) }
                        }
                        return true
                    }
                    guard admitted else { disconnect(); break }
                }
                if input.count >= Self.frameLimit { disconnect(); continue }
            }
            // Partial writes remain bounded and resume only when the socket is writable.
            // A session that makes no progress is closed; producers never perform I/O.
            let output = state.withLock { $0.output }
            if !output.isEmpty {
                let sent = output.withUnsafeBytes { Glibc.send(client, $0.baseAddress, min($0.count, 65_536), Int32(MSG_NOSIGNAL | MSG_DONTWAIT)) }
                if sent > 0 {
                    state.withLock { $0.output.removeFirst(sent) }
                    lastProgress = .now
                } else if errno != EAGAIN && errno != EINTR { disconnect() }
            }
        }
    }
}
#endif
