@testable import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// A stand-in agent whose control server refuses large requests by its own rules: a byte
/// budget of 0 leaves no room for any frame past `smallFrame`, and a frame limit refuses a
/// frame from that size on as too large. Requests it takes are answered as unsupported.
private final class RefusingAgent: @unchecked Sendable {
    let harness: AgentHarness
    private let server: ControlServer
    private let task: Task<Void, Never>
    init(byteBudget: Int = ControlServer.defaultByteBudget, frameLimit: Int? = nil) throws {
        harness = try AgentHarness()
        let paths = try AgentPaths(directory: harness.dataDirectory)
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths), byteBudget: byteBudget, frameLimit: frameLimit)
        self.server = server
        task = Task { [server] in await server.run { _ in ControlResponse(error: .unsupported) } }
    }
    func stop() async { server.stop(); await task.value }
}

/// A listening socket where the agent's would be. It takes one connection, reads a piece of
/// the request and closes the connection without a reply.
private final class DroppingAgent: @unchecked Sendable {
    let harness: AgentHarness
    private let listener: Int32
    private let finished = DispatchSemaphore(value: 0)
    init() throws {
        harness = try AgentHarness()
        let path = harness.dataDirectory.appendingPathComponent("control.sock").path
        #if os(Linux)
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else { throw AgentError.control }
        // Not inherited by the processes other tests start meanwhile.
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 1) == 0 else { close(descriptor); throw AgentError.control }
        listener = descriptor
        let done = finished
        Thread.detachNewThread {
            // The wait is a guard against a hang only.
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&item, 1, 60_000) > 0 {
                let client = accept(descriptor, nil, nil)
                if client >= 0 {
                    _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    _ = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
                    close(client)
                }
            }
            done.signal()
        }
    }
    /// Waits until the connection was taken and dropped.
    func stop() { finished.wait() }
    deinit { close(listener) }
}

/// When the agent refuses a request part way through and closes the connection, `catflap`
/// shows the agent's own answer and exit status; only a connection closed without an answer
/// still says the agent cannot be reached.
@Suite(.timeLimit(.minutes(5))) struct ControlRefusalE2E {
    /// `catflap audit --also` with a 3 MiB file: the file's text travels in the request, and
    /// each refusing agent here stops reading it after 1 MiB at most, while `catflap` is
    /// still sending the rest.
    private func auditWithLargeRequest(_ harness: AgentHarness) async throws -> CommandResult {
        let file = harness.dataDirectory.appendingPathComponent("also.txt")
        try Data(repeating: UInt8(ascii: "a"), count: 3 * 1_048_576).write(to: file)
        let executable = harness.executable, folder = harness.dataDirectory.path
        return try await onThread { try runCatflap(executable, ["audit", "--also", file.path, "--json", "--data-dir", folder]) }
    }

    private func said(_ result: CommandResult) -> String {
        (jsonObject(result.output)?["error"] as? String) ?? "nothing as JSON"
    }

    @Test func testBusyRefusalShowsTheAgentsAnswer() async throws {
        let agent = try RefusingAgent(byteBudget: 0)
        let result = try await auditWithLargeRequest(agent.harness)
        await agent.stop()
        #expect(result.code == 1, "catflap ended with status \(result.code)")
        #expect(jsonObject(result.output)?["ok"] as? Bool == false)
        #expect(said(result) == ControlServer.busy, "catflap said: \(said(result))")
    }

    @Test func testTooLargeRefusalShowsTheAgentsAnswer() async throws {
        let agent = try RefusingAgent(frameLimit: 512 * 1024)
        let result = try await auditWithLargeRequest(agent.harness)
        await agent.stop()
        #expect(result.code == 1, "catflap ended with status \(result.code)")
        #expect(jsonObject(result.output)?["ok"] as? Bool == false)
        #expect(said(result) == AgentError.invalidRequest.rawValue, "catflap said: \(said(result))")
    }

    @Test func testConnectionDroppedWithoutAnAnswerCannotReachTheAgent() async throws {
        let agent = try DroppingAgent()
        let result = try await auditWithLargeRequest(agent.harness)
        agent.stop()
        #expect(result.code == 1, "catflap ended with status \(result.code)")
        #expect(jsonObject(result.output)?["ok"] as? Bool == false)
        #expect(said(result) == AgentError.control.rawValue, "catflap said: \(said(result))")
    }
}
