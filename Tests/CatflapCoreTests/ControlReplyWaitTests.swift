@testable import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Leaves a socket file at `url` that nobody listens on, as a stopped agent can: a
/// connection to it is refused.
private func socketWithoutListener(at url: URL) throws {
    #if os(Linux)
    let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard descriptor >= 0 else { throw AgentError.control }
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(url.path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentError.control }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
    #if os(macOS)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, chmod(url.path, 0o600) == 0 else { throw AgentError.control }
}

/// Once a request has reached an agent that is there and belongs to this user, the client
/// waits for the reply as long as the reply wait allows: a busy agent is not one that
/// cannot be reached. An agent that is not there is still reported at once.
@Suite(.timeLimit(.minutes(2))) struct ControlReplyWaitTests {
    /// A reply that comes 7 s after the request, later than the 5 s a socket read used to
    /// wait, is answered with the wait the client ships with.
    @Test func testSlowReplyIsAnswered() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        defer { server.stop() }
        let task = Task {
            await server.run { _ in
                try? await Task.sleep(for: .seconds(7))
                return (try? ControlResponse(value: "late reply")) ?? ControlResponse(error: .storage)
            }
        }
        let reply = try await ControlClient.requestAsync(.init("status"), socket: paths.socket)
        #expect(reply.ok)
        #expect(try reply.decode(String.self) == "late reply")
        server.stop(); await task.value
    }

    /// An agent that takes the request and never answers ends it with "did not answer in
    /// time" once the reply wait has passed, here a short one the test sets.
    @Test func testSilentAgentDidNotAnswerInTime() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        defer { server.stop() }
        let task = Task {
            await server.run { _ in
                // Ends only when the server stops and cancels it.
                try? await Task.sleep(for: .seconds(3600))
                return ControlResponse(error: .storage)
            }
        }
        let started = ContinuousClock.now
        await #expect(throws: AgentError.noAnswer) {
            try await ControlClient.requestAsync(.init("status"), socket: paths.socket, replyWait: .seconds(3))
        }
        // A lower bound only: the client waited for the reply rather than giving up at once.
        #expect(started.duration(to: .now) >= .seconds(3))
        server.stop(); await task.value
    }

    /// With no agent, or only the socket file a stopped one left behind, a request fails at
    /// once and says the agent cannot be reached. The reply wait here is an hour, so a client
    /// that waited for a reply would run into the suite's time limit instead.
    @Test func testMissingOrRefusedAgentCannotBeReachedAtOnce() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        await #expect(throws: AgentError.control, "no socket") {
            try await ControlClient.requestAsync(.init("status"), socket: paths.socket, replyWait: .seconds(3600))
        }
        try socketWithoutListener(at: paths.socket)
        await #expect(throws: AgentError.control, "a socket nobody listens on") {
            try await ControlClient.requestAsync(.init("status"), socket: paths.socket, replyWait: .seconds(3600))
        }
    }
}
