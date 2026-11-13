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
        silent.append(try rawControlConnection(paths.socket))
        let start = ContinuousClock.now
        let response = try await ControlClient.requestAsync(.init("status"), socket: paths.socket)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(response.ok)
        #expect(try response.decode(AgentStatus.self).running)
        // Wait for the completed status worker to release its slot before filling the limit.
        let released = ContinuousClock.now.advanced(by: .seconds(1))
        while server.activeConnections != 1 && ContinuousClock.now < released {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(server.activeConnections == 1)
        // Keep 32 silent connections open. The next one must be closed, not queued to a worker.
        for _ in 1..<32 { silent.append(try rawControlConnection(paths.socket)) }
        let extra = try rawControlConnection(paths.socket)
        defer { close(extra) }
        let rejected = try onControlProbeThread {
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            _ = setsockopt(extra, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var byte: UInt8 = 0
            return recv(extra, &byte, 1, 0) == 0
        }
        #expect(rejected)
        let shutdownStart = ContinuousClock.now
        server.stop(); await task.value
        #expect(shutdownStart.duration(to: .now) < .seconds(1))
        await runtime.stop()
    }
    @Test func testSlowHandlerDoesNotDelayOthers() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        defer { server.stop() }
        let runtime = try AgentRuntime(paths: paths)
        try await runtime.start()
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        await runtime.register("slow") { _ in
            continuation.yield(())
            try await Task.sleep(for: .seconds(2))
            return try ControlResponse(value: "slow reply")
        }
        let task = Task { await server.run { await runtime.handle($0) } }
        let slow = Task { try await ControlClient.requestAsync(.init("slow"), socket: paths.socket) }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        let start = ContinuousClock.now
        let status = try await ControlClient.requestAsync(.init("status"), socket: paths.socket)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(status.ok)
        #expect(try status.decode(AgentStatus.self).running)
        let reply = try await slow.value
        #expect(reply.ok)
        #expect(try reply.decode(String.self) == "slow reply")
        continuation.finish()
        server.stop(); await task.value
        await runtime.stop()
    }
}
