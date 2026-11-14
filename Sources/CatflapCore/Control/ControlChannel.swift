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
    static func readFrame(_ fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(5)
        while data.count < maxFrame && Date() < deadline {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw AgentError.control }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                guard data.count + newline < maxFrame, newline == count - 1 else { throw AgentError.invalidRequest }
                data.append(contentsOf: buffer[..<newline])
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        throw AgentError.invalidRequest
    }
    static func writeFrame(_ data: Data, _ fd: Int32) throws {
        guard data.count < maxFrame else { throw AgentError.invalidRequest }
        let frame = data + Data([10])
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if os(Linux)
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                #else
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
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
        let fd = try LocalSocket.create(); defer { close(fd) }
        var address = try LocalSocket.address(url.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, LocalSocket.owner(fd) else { throw AgentError.control }
        try LocalSocket.writeFrame(ControlJSON.encoder.encode(request), fd)
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

public final class ControlServer: Sendable {
    private let fd: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let url: URL
    // Retain the lock until the socket has closed, including shutdown/error paths.
    private let lock: AgentLock
    private struct State: Sendable {
        var started = false
        var stopped = false
        var sessions: [UUID: ControlSession] = [:]
    }
    private let state = Mutex(State())
    var activeConnections: Int { state.withLock { $0.sessions.count } }
    public init(paths: AgentPaths, lock: AgentLock) throws {
        self.lock = lock; url = paths.socket
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
    deinit { close(fd); close(wakeRead); close(wakeWrite); _ = unlink(url.path) }

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
    /// One JSON-line request per connection; up to 32 independent connection workers.
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
    private func acceptLoop(handler: @escaping @Sendable (ControlRequest) async -> ControlResponse) {
        let workers = DispatchGroup()
        while !state.withLock({ $0.stopped }) {
            // An infinite wait on a dedicated thread: no timer or idle polling wake-ups.
            var items = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                         pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            let result = poll(&items, nfds_t(items.count), -1)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0, items[1].revents == 0 else { break }
            guard items[0].revents & Int16(POLLIN) != 0 else { break }
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            LocalSocket.configureAccepted(client)
            guard LocalSocket.owner(client) else { close(client); continue }
            let id = UUID()
            let session = ControlSession(client)
            let admitted = state.withLock { value in
                guard !value.stopped, value.sessions.count < 32 else { return false }
                value.sessions[id] = session
                return true
            }
            guard admitted else { close(client); continue }
            workers.enter()
            Thread.detachNewThread {
                defer {
                    session.closeSocket()
                    _ = self.state.withLock { $0.sessions.removeValue(forKey: id) }
                    workers.leave()
                }
                do {
                    let request = try ControlJSON.decoder.decode(ControlRequest.self, from: LocalSocket.readFrame(client))
                    let task = Task {
                        let response = await handler(request)
                        session.complete(response)
                    }
                    session.install(task)
                    if let response = session.reply() {
                        try LocalSocket.writeFrame(ControlJSON.encoder.encode(response), client)
                    }
                } catch {
                    try? LocalSocket.writeFrame(ControlJSON.encoder.encode(ControlResponse(error: .invalidRequest)), client)
                }
            }
        }
        stop()
        workers.wait()
    }
}
