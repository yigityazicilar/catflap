import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct ControlTests {
    @Test func testSecondAgentRefusesToStart() throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        var first: AgentLock? = try AgentLock(paths: paths)
        #expect(throws: AgentError.alreadyRunning) { try AgentLock(paths: paths) }
        withExtendedLifetime(first) {}
        first = nil
        let afterShutdown = try AgentLock(paths: paths)
        withExtendedLifetime(afterShutdown) {}
    }
    @Test func testControlChannelIsOwnerOnly() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let lock = try AgentLock(paths: paths)
        let server = try ControlServer(paths: paths, lock: lock)
        let runtime = try AgentRuntime(paths: paths)
        try await runtime.start()
        let task = Task.detached { await server.run { await runtime.handle($0) } }
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.socket.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        let response = try await ControlClient.requestAsync(.init("status"), socket: paths.socket)
        #expect(response.ok)
        #expect(try response.decode(AgentStatus.self).serverRunning == false)
        // A client refuses an endpoint exposed to another account.
        #expect(chmod(paths.socket.path, 0o666) == 0)
        await #expect(throws: AgentError.control) { try await ControlClient.requestAsync(.init("status"), socket: paths.socket) }
        #expect(chmod(paths.socket.path, 0o600) == 0)
        task.cancel(); await task.value
        await runtime.stop()
    }
}
