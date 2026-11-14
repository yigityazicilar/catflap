#if os(Linux)
@testable import CatflapCore
import Foundation
import Glibc
import XCTest

final class ControlDesktopSessionTests: XCTestCase, @unchecked Sendable {
    private func connect(_ path: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw AgentError.control }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.path.utf8CString.map { UInt8(bitPattern: $0) }) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); throw AgentError.control }
        return fd
    }
    private func wait(_ condition: () -> Bool) -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return false
    }
    private func read(_ fd: Int32) throws -> Data {
        var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&item, 1, 20000) > 0 else { throw AgentError.control }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = recv(fd, &bytes, bytes.count, 0)
        guard count >= 0 else { throw AgentError.control }
        return Data(bytes.prefix(count))
    }
    func testOwnerOnlyPlainJSONAndSessionReplacement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("session-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("session.sock")
        let server = try DesktopSession(path: path)
        server.start(changed: { _ in }, handler: { $0 })
        do {
            try await ControlThread.run { [self] in
                let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
                XCTAssertEqual(mode?.intValue, 0o600)
                let first = try connect(path); defer { close(first) }
                XCTAssertTrue(wait { server.connected })
                let frame = Data("{\"id\":\"one\",\"command\":\"hello\",\"arguments\":{}}\n".utf8)
                let count = frame.withUnsafeBytes { send(first, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
                XCTAssertEqual(count, frame.count)
                XCTAssertEqual(try read(first), frame)
                let second = try connect(path); defer { close(second) }
                XCTAssertTrue(wait { server.connected })
                XCTAssertEqual(try read(first), Data(), "A replacement session closes the previous one")
                // EOF on the old peer can arrive between its close and admission of the
                // new peer. A real request/reply on the replacement proves admission.
                let secondCount = frame.withUnsafeBytes { send(second, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
                XCTAssertEqual(secondCount, frame.count)
                XCTAssertEqual(try read(second), frame)
                XCTAssertTrue(server.send(Data("{\"event\":\"state\"}".utf8)))
                XCTAssertEqual(try read(second), Data("{\"event\":\"state\"}\n".utf8))
            }
        } catch { await server.stop(); throw error }
        await server.stop()
    }
    func testNonReadingSessionIsClosedWithoutBlockingProducer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pressure-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try DesktopSession(path: folder.appendingPathComponent("session.sock"))
        server.start(changed: { _ in }, handler: { $0 })
        do {
            try await ControlThread.run { [self] in
                let fd = try connect(folder.appendingPathComponent("session.sock")); defer { close(fd) }
                XCTAssertTrue(wait { server.connected })
                XCTAssertTrue(server.send(Data(repeating: 32, count: 20_000_000)))
                // No client read. The bounded output queue must eventually close it.
                XCTAssertTrue(wait { !server.connected })
                XCTAssertFalse(server.send(Data("{}".utf8)))
                let replacement = try connect(folder.appendingPathComponent("session.sock")); defer { close(replacement) }
                XCTAssertTrue(wait { server.connected })
                XCTAssertFalse(server.send(Data(repeating: 32, count: DesktopSession.frameLimit)))
                XCTAssertTrue(wait { !server.connected })
            }
        } catch { await server.stop(); throw error }
        await server.stop()
    }
}
#endif
