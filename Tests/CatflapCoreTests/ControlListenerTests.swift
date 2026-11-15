@testable import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// A connection that writes and reads raw bytes, so a test can hold a frame half sent.
private final class RawClient: @unchecked Sendable {
    let fd: Int32
    init(_ url: URL) throws {
        #if os(Linux)
        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif
        guard fd >= 0 else { throw AgentError.control }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        // A guard against a hang only.
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(fd); throw AgentError.control }
    }
    deinit { close(fd) }
    /// False once the server has stopped taking bytes.
    func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if os(Linux)
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                #else
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
    /// The reply line, or nil if the connection ended without one.
    func reply() -> ControlResponse? {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer[..<count])
            if let newline = data.firstIndex(of: 10) { return try? ControlJSON.decoder.decode(ControlResponse.self, from: data[..<newline]) }
        }
    }
}

private func onThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

/// A status request padded with an argument to about `size` bytes, without its newline.
private func paddedRequest(_ size: Int) throws -> Data {
    try ControlJSON.encoder.encode(ControlRequest("status", arguments: ["pad": String(repeating: "p", count: size)]))
}

@Suite(.serialized, .timeLimit(.minutes(5))) struct ControlListenerTests {
    private func serve(_ server: ControlServer) -> Task<Void, Never> {
        Task { await server.run { _ in (try? ControlResponse(value: "answered")) ?? ControlResponse(error: .storage) } }
    }

    /// Accept failing for lack of descriptors, or for a connection gone before it was taken,
    /// waits before each retry, longer every time, instead of spinning; the waiting client is
    /// answered once accept works again.
    @Test(arguments: [EMFILE, ENFILE, ECONNABORTED, EINTR])
    func testAcceptFailuresBackOffThenServe(_ code: Int32) async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        server.inject(.acceptFails(errno: code, times: 4))
        let task = serve(server)
        let reply = try await ControlClient.requestAsync(.init("status"), socket: paths.socket)
        #expect(reply.ok)
        let attempts = server.acceptAttempts
        // Four refusals and the accept that worked: no retry beyond those.
        #expect(attempts.count == 5, "accept was tried \(attempts.count) times")
        for (index, (before, after)) in zip(attempts, attempts.dropFirst()).enumerated() {
            // A lower bound only: a slow machine waits longer, never shorter.
            #expect(before.duration(to: after) >= ControlServer.acceptBackoff(failures: index + 1), "retry \(index + 1) came too soon")
        }
        server.stop(); await task.value
        #expect(!server.listenerFailed)
    }

    /// A poll that fails outright ends the listener as failed: its socket goes, so no client
    /// waits on a listener nobody serves, and the agent can tell this from a stop.
    @Test func testTerminalPollErrorEndsTheListenerAsFailed() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        server.inject(.pollFails(errno: EBADF, afterPolls: 1))
        let task = serve(server)
        // The first poll is real: this request is the barrier that the listener was serving.
        #expect(try await ControlClient.requestAsync(.init("status"), socket: paths.socket).ok)
        await task.value
        #expect(server.listenerFailed)
        #expect(!FileManager.default.fileExists(atPath: paths.socket.path), "the failed listener's socket is still there")
        await #expect(throws: (any Error).self) { try await ControlClient.requestAsync(.init("status"), socket: paths.socket) }
    }

    /// A large frame that takes longer than five seconds to arrive, but keeps arriving, is
    /// read whole: the time a frame may take grows with what has arrived. The pace here is
    /// set by sleeps, which a slow machine only lengthens, and stays well above the floor.
    @Test func testLargeFrameArrivingSlowlyButSteadilyIsRead() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        let task = serve(server)
        let frame = try paddedRequest(8 * 1_048_576)
        let client = try RawClient(paths.socket)
        let started = ContinuousClock.now
        let reply = try await onThread { () -> ControlResponse? in
            // 64 pieces, one every 100 ms: at least 6.4 s for the whole frame.
            let piece = (frame.count + 63) / 64
            var offset = 0
            while offset < frame.count {
                guard client.write(frame.subdata(in: offset..<min(offset + piece, frame.count))) else { break }
                offset += piece
                Thread.sleep(forTimeInterval: 0.1)
            }
            _ = client.write(Data([10]))
            return client.reply()
        }
        let took = started.duration(to: .now)
        #expect(took > .seconds(5), "the frame arrived within \(took), so this proves nothing")
        #expect(reply?.ok == true, "a steadily arriving frame was cut off after \(took): \(reply?.error ?? "no reply")")
        server.stop(); await task.value
    }

    /// Waits until the server's own counters show `condition`; the limit only stops a hang.
    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition() {
            guard start.duration(to: .now) < .seconds(120) else {
                Issue.record("the server never showed \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Many near-limit frames at once. Two grow past `smallFrame` and take the budget's two
    /// whole-frame reservations; six more, sent while those are held, are each refused as busy
    /// once they pass `smallFrame`; an ordinary request meanwhile is answered, and the two
    /// held frames are answered when they end. No more than the budget is ever reserved.
    /// Each step waits for the server's own counters, not for the clients' writes, which may
    /// return before or after the server has read them.
    @Test func testManyNearLimitFramesAtOnceStayWithinTheByteBudget() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let server = try ControlServer(paths: paths, lock: AgentLock(paths: paths))
        let task = serve(server)
        let budget = ControlServer.defaultByteBudget
        let fits = budget / (40 * 1_048_576)
        let body = try paddedRequest(39 * 1_048_576)
        let split = 2 * ControlServer.smallFrame
        let head = body.subdata(in: 0..<split), rest = body.subdata(in: split..<body.count) + Data([10])

        let held = try (0..<fits).map { _ in try RawClient(paths.socket) }
        for client in held { #expect(try await onThread { client.write(head) }, "the start of a held frame was refused") }
        try await until("\(fits) frames reserved") { server.reservedBytes == budget }

        let others = try (0..<6).map { _ in try RawClient(paths.socket) }
        let refusals = try await withThrowingTaskGroup(of: ControlResponse?.self) { group in
            for client in others { group.addTask { try await onThread { _ = client.write(body); return client.reply() } } }
            return try await group.reduce(into: [ControlResponse?]()) { $0.append($1) }
        }
        #expect(refusals.allSatisfy { $0?.ok == false && $0?.error == ControlServer.busy }, "\(refusals.map { $0?.error ?? "no reply" })")
        try await until("\(others.count) refused connections let go") { server.busyRefusals == others.count }
        #expect(server.inFlightBytes == budget, "\(server.inFlightBytes) bytes counted while \(fits) frames are held")
        #expect(try await ControlClient.requestAsync(.init("status"), socket: paths.socket).ok, "an ordinary request was refused")

        let replies = try await withThrowingTaskGroup(of: ControlResponse?.self) { group in
            for client in held { group.addTask { try await onThread { _ = client.write(rest); return client.reply() } } }
            return try await group.reduce(into: [ControlResponse?]()) { $0.append($1) }
        }
        #expect(replies.allSatisfy { $0?.ok == true }, "\(replies.map { $0?.error ?? ($0 == nil ? "no reply" : "answered") })")
        #expect(server.peakReservedBytes <= budget)
        try await until("the whole budget free again") { server.inFlightBytes == 0 }
        #expect(try await ControlClient.requestAsync(.init("status"), socket: paths.socket).ok)
        server.stop(); await task.value
    }
}
