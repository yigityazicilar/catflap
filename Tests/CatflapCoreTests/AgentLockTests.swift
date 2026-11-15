@testable import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private final class LockTestBundleMarker {}

/// The `catflap` executable built beside the test bundle, or the one `CATFLAP_EXECUTABLE` names.
private func catflapExecutable() throws -> URL {
    if let override = ProcessInfo.processInfo.environment["CATFLAP_EXECUTABLE"] { return URL(fileURLWithPath: override) }
    #if os(macOS)
    // XCTest launches through a system runner, not the test bundle executable.
    var directory = Bundle(for: LockTestBundleMarker.self).bundleURL
    #else
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    #endif
    for _ in 0..<6 {
        let candidate = directory.appendingPathComponent("catflap")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        directory.deleteLastPathComponent()
    }
    throw AgentError.unsupported
}

/// Runs `catflap` with `arguments` and returns its exit status and standard error, waiting for
/// its end through the termination handler.
private func runCatflap(_ arguments: [String]) async throws -> (status: Int32, error: String) {
    let child = Process()
    child.executableURL = try catflapExecutable()
    child.arguments = arguments
    let error = Pipe()
    // Close-on-exec, so a process another test spawns meanwhile cannot hold the pipe open.
    for descriptor in [error.fileHandleForReading.fileDescriptor, error.fileHandleForWriting.fileDescriptor] {
        _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) | FD_CLOEXEC)
    }
    child.standardError = error
    child.standardOutput = FileHandle.nullDevice
    child.standardInput = FileHandle.nullDevice
    let (ended, ending) = AsyncStream<Int32>.makeStream()
    child.terminationHandler = { ending.yield($0.terminationStatus); ending.finish() }
    try child.run()
    var status: Int32 = -1
    for await code in ended { status = code }
    let text = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (status, text)
}

struct AgentLockTests {
    /// The audit reads every file in the data folder, the lock file among them, inside the
    /// agent. The folder must stay locked against another process afterwards: a lock that this
    /// process dropped on closing any descriptor of the file would let a second agent start.
    @Test func testLockHoldsAgainstAnotherProcessAfterTheAuditReadTheFolder() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let lock = try AgentLock(paths: paths)
        let findings = try DiskAudit(directory: paths.directory, inbox: paths.directory.appendingPathComponent("inbox"))
            .scan(needles: [AuditNeedle(bytes: Data("not in any file".utf8), kind: "probe")])
        #expect(findings.isEmpty)
        let second = try await runCatflap(["erase-identity", "--data-dir", paths.directory.path])
        #expect(second.status != 0 && second.error.contains(AgentError.alreadyRunning.rawValue),
                "a second process took the folder after the audit: exit \(second.status), \(second.error)")
        withExtendedLifetime(lock) {}
    }
}
