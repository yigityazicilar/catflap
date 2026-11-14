import CatflapCore
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

#if os(macOS)
private final class HarnessBundleMarker: NSObject {}
#endif

enum HarnessError: Error { case executableMissing, startupFailed, commandTimedOut, exitStatusLost, outputNotClosed }
struct CommandResult {
    let code: Int32
    let output: Data
    let error: Data
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try ControlJSON.decoder.decode(type, from: output) }
}

func harnessNote(_ text: String) { FileHandle.standardError.write(Data(("harness: " + text + "\n").utf8)) }

/// Whether a child of the test process has ended. The exit status is nil when it could not be read.
enum ChildEnd: Equatable { case stillRunning, ended(status: Int32?) }

/// What the system says about a child, leaving its exit status in place for Foundation.
/// `collected` means the status has already been taken, so the child is fully gone.
private func systemView(of pid: pid_t) -> (ended: Bool, collected: Bool) {
    var info = siginfo_t()
    guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else { return (errno == ECHILD, true) }
    #if os(Linux)
    let reported = info._sifields._sigchld.si_pid
    #else
    let reported = info.si_pid
    #endif
    return (reported == pid, false)
}

/// Waits for a child to end, for at most `limit` seconds.
///
/// `Process.waitUntilExit()` is not used anywhere in the tests. On the macOS test machines it
/// was seen waiting without end, in `AgentHarness.stop()`, for an agent that was no longer in
/// the process table. Why that wait was never woken is not known, and neither is what
/// `isRunning` said at the time. So every wait has a limit, and the system is asked too: a
/// child it has reported as ended for a full second counts as ended, and the disagreement is
/// written to standard error so the next occurrence leaves facts behind.
func waitForEnd(of child: Process, limit: TimeInterval) -> ChildEnd {
    let pid = child.processIdentifier
    let start = ContinuousClock.now
    var endedSince: ContinuousClock.Instant?
    while true {
        if !child.isRunning { return .ended(status: child.terminationStatus) }
        let system = systemView(of: pid)
        if system.ended {
            let since = endedSince ?? .now
            endedSince = since
            if since.duration(to: .now) > .seconds(1) {
                var status: Int32?
                var raw: Int32 = 0
                if !system.collected, waitpid(pid, &raw, WNOHANG) == pid { status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : raw & 0x7f }
                harnessNote("child \(pid) has ended (exit status \(system.collected ? "already collected" : "not yet collected")), but Foundation still reports it running a second later")
                return .ended(status: status)
            }
        } else {
            endedSince = nil
        }
        if start.duration(to: .now) >= .seconds(limit) { return .stillRunning }
        Thread.sleep(forTimeInterval: 0.02)
    }
}

/// Real subprocess harness shared by agent, pairing, transfer and clipboard scenarios.
final class AgentHarness {
    let dataDirectory: URL
    let executable: URL
    private var process: Process?
    init() throws {
        dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ce-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let override = ProcessInfo.processInfo.environment["CATFLAP_EXECUTABLE"] {
            executable = URL(fileURLWithPath: override)
        } else {
            #if os(macOS)
            // XCTest launches through a system runner, not the test bundle executable.
            var directory = Bundle(for: HarnessBundleMarker.self).bundleURL
            #else
            var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            #endif
            var found: URL?
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent("catflap")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { found = candidate; break }
                directory.deleteLastPathComponent()
            }
            guard let found else { throw HarnessError.executableMissing }
            executable = found
        }
    }
    deinit { stop(); try? eraseIdentity(); try? FileManager.default.removeItem(at: dataDirectory) }
    @discardableResult
    func eraseIdentity() throws -> CommandResult {
        try runHarnessProcess(executable, arguments: ["erase-identity", "--data-dir", dataDirectory.path])
    }
    func start() throws {
        let child = Process()
        child.executableURL = executable
        child.arguments = ["agent", "--data-dir", dataDirectory.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run(); process = child
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && child.isRunning {
            if let response = try? ControlClient.request(.init("status"), socket: dataDirectory.appendingPathComponent("control.sock")), response.ok { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stop(); throw HarnessError.startupFailed
    }
    func stop() {
        guard let child = process else { return }
        process = nil
        let pid = child.processIdentifier
        if child.isRunning && !systemView(of: pid).ended { child.terminate() }
        if waitForEnd(of: child, limit: 7) != .stillRunning { return }
        harnessNote("agent \(pid) did not end within 7 s of SIGTERM; sending SIGKILL")
        kill(pid, SIGKILL)
        if waitForEnd(of: child, limit: 5) == .stillRunning { harnessNote("agent \(pid) is still running 5 s after SIGKILL") }
    }
    func restart() throws { stop(); try start() }
    func command(_ arguments: [String], timeout: TimeInterval = 10) throws -> CommandResult {
        try runHarnessProcess(executable, arguments: arguments + ["--data-dir", dataDirectory.path, "--json"], timeout: timeout)
    }
}

func runHarnessProcess(_ executable: URL, arguments: [String], timeout: TimeInterval = 10) throws -> CommandResult {
    let child = Process(); let output = Pipe(); let error = Pipe()
    child.executableURL = executable
    child.arguments = arguments
    child.standardOutput = output; child.standardError = error
    try child.run()
    // Drain both streams concurrently so larger future history replies cannot fill a pipe.
    let group = DispatchGroup()
    let buffers = HarnessBuffers()
    group.enter()
    DispatchQueue.global().async { buffers.setOutput(output.fileHandleForReading.readDataToEndOfFile()); group.leave() }
    group.enter()
    DispatchQueue.global().async { buffers.setError(error.fileHandleForReading.readDataToEndOfFile()); group.leave() }
    let end = waitForEnd(of: child, limit: timeout)
    if end == .stillRunning { kill(child.processIdentifier, SIGKILL); _ = waitForEnd(of: child, limit: 5) }
    // Both pipes close once the child has gone.
    let drained = group.wait(timeout: .now() + 10) == .success
    guard case .ended(let status) = end else { throw HarnessError.commandTimedOut }
    guard drained else { throw HarnessError.outputNotClosed }
    guard let status else { throw HarnessError.exitStatusLost }
    return CommandResult(code: status, output: buffers.output, error: buffers.error)
}
private final class HarnessBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(); private var err = Data()
    var output: Data { lock.lock(); defer { lock.unlock() }; return out }
    var error: Data { lock.lock(); defer { lock.unlock() }; return err }
    func setOutput(_ value: Data) { lock.lock(); out = value; lock.unlock() }
    func setError(_ value: Data) { lock.lock(); err = value; lock.unlock() }
}
