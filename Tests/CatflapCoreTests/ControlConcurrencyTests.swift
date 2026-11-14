@testable import CatflapCore
import Foundation
import Synchronization
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private func onControlProbeThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
    let result = Mutex<Result<T, Error>?>(nil)
    let ready = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        let value = Result { try body() }
        result.withLock { $0 = value }; ready.signal()
    }
    ready.wait()
    return try result.withLock { try $0!.get() }
}
private func rawControlConnection(_ url: URL) throws -> Int32 {
    try onControlProbeThread {
        #if os(Linux)
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else { throw AgentError.control }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(descriptor); throw AgentError.control }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let code = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard code == 0 else { close(descriptor); throw AgentError.control }
        return descriptor
    }
}

/// True while a connection is open and the server has written nothing to it.
private func openAndUnanswered(_ descriptor: Int32) -> Bool {
    var byte: UInt8 = 0
    let count = recv(descriptor, &byte, 1, Int32(MSG_DONTWAIT))
    return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
}
/// True when the connection is closed with nothing written to it (20 s guard against a hang).
private func closedUnanswered(_ descriptor: Int32) throws -> Bool {
    try onControlProbeThread {
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        return recv(descriptor, &byte, 1, 0) == 0
    }
}
private func waitUntil(seconds: Int, _ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(1))
    }
    return true
}

extension ControlTests {
    @Test func testSilentClientDoesNotDelayOthers() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        defer { server.stop() }
        let runtime = try AgentRuntime(paths: paths)
        try await runtime.start()
        let task = Task { await server.run { await runtime.handle($0) } }
        var silent: [Int32] = []
        defer { silent.forEach { close($0) } }
        // A server that served one connection at a time would answer the status request only
        // after giving up on the silent connection, which it does 5 s after it opened, by
        // writing a reply and closing it. So when the reply arrives, the silent connection
        // must still be open with nothing written to it. That is an order of events, not a
        // time limit: a slow runner cannot fail it, and one that pauses for more than 5 s
        // inside an attempt gets two more.
        var overlapped = false
        for _ in 1...3 where !overlapped {
            let probe = try rawControlConnection(paths.socket)
            defer { close(probe) }
            let response = try await ControlClient.requestAsync(.init("status"), socket: paths.socket)
            #expect(response.ok)
            #expect(try response.decode(AgentStatus.self).running)
            overlapped = openAndUnanswered(probe)
        }
        try #require(overlapped, "every status reply came after the server gave up on the silent connection")
        // Wait for the probes to release their slots, then hold all 32, each admitted before
        // the next one connects. The next connection must be closed, not queued to a worker.
        try #require(try await waitUntil(seconds: 20) { server.activeConnections == 0 })
        for count in 1...32 {
            silent.append(try rawControlConnection(paths.socket))
            try #require(try await waitUntil(seconds: 20) { server.activeConnections == count })
        }
        let extra = try rawControlConnection(paths.socket)
        defer { close(extra) }
        #expect(try closedUnanswered(extra))
        // Stopping must interrupt the silent connections, not wait out their 5 s: an
        // interrupted one is closed with nothing written to it, while one that ran out of time
        // gets a reply first. The newest one opened moments before the stop.
        server.stop(); await task.value
        #expect(try closedUnanswered(silent[silent.count - 1]))
        await runtime.stop()
    }
    @Test func testSlowHandlerDoesNotDelayOthers() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        defer { server.stop() }
        let runtime = try AgentRuntime(paths: paths)
        try await runtime.start()
        // The slow request stays open until the test lets it go, so a status reply that
        // arrives first did not wait for it, however busy the machine is.
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let (letGo, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        await runtime.register("slow") { _ in
            continuation.yield(())
            for await _ in letGo { break }
            return try ControlResponse(value: "slow reply")
        }
        let task = Task { await server.run { await runtime.handle($0) } }
        let slow = Task { try await ControlClient.requestAsync(.init("slow"), socket: paths.socket) }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        let status = try await ControlClient.requestAsync(.init("status"), socket: paths.socket)
        #expect(status.ok)
        #expect(try status.decode(AgentStatus.self).running)
        release.yield(())
        let reply = try await slow.value
        #expect(reply.ok)
        #expect(try reply.decode(String.self) == "slow reply")
        continuation.finish()
        server.stop(); await task.value
        await runtime.stop()
    }
}
