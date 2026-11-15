import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

#if os(macOS)
private final class HarnessBundleMarker: NSObject {}
#endif

enum HarnessError: Error { case executableMissing, startupFailed, commandTimedOut, exitStatusLost, outputNotClosed, processObservationFailed(Int32) }
struct CommandResult {
    let code: Int32
    let output: Data
    let error: Data
    /// The subcommand's name only (`clip send`), never its arguments: a pairing code is one.
    var command = ""
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        do { return try ControlJSON.decoder.decode(type, from: output) }
        catch {
            // Only the `error` field of a JSON error reply: the rest can be a transfer record,
            // which carries device ids.
            let object = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
            let reply = object?["ok"] as? Bool == false ? object?["error"] as? String : nil
            throw CommandOutputError(command: command, code: code, output: output.count, error: error, standardError: self.error, reply: reply)
        }
    }
}

/// A command whose output was not what the test expected, with what is needed to see why: the
/// exit status and standard error. Catflap never prints an address or key there.
struct CommandOutputError: Error, CustomStringConvertible {
    let command: String
    let code: Int32
    let output: Int
    let error: any Error
    let standardError: Data
    /// The `error` field of a JSON error reply on standard output, if it was one.
    var reply: String? = nil
    var description: String {
        let said = String(decoding: standardError.prefix(1200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return "`catflap \(command)` exited with status \(code) and printed \(output) bytes on standard output"
            + (reply.map { " (error: \($0.prefix(400)))" } ?? "") + "; "
            + "standard error: \(said.isEmpty ? "(empty)" : said); decoding: \(error)"
    }
}

/// The leading words of a command line, while they are short plain words.
private func commandName(_ arguments: [String]) -> String {
    arguments.prefix { word in
        !word.hasPrefix("-") && word.count <= 16 && word.allSatisfy { $0.isLetter || $0 == "." }
    }.joined(separator: " ")
}

func harnessNote(_ text: String) { FileHandle.standardError.write(Data(("harness: " + text + "\n").utf8)) }

/// Something the harness had to do that means the program under test is at fault. It is
/// called from `defer` and `deinit` too, where no test can be failed, so the fault is written
/// as a line starting `harness-error:`, and `scripts/ci-test.py` fails a run that prints one.
/// Inside a test it is recorded against that test as well.
func harnessError(_ text: String) {
    FileHandle.standardError.write(Data(("harness-error: " + text + "\n").utf8))
    if Test.current != nil { Issue.record(Comment(rawValue: text)) }
}

/// Unknown status is not evidence of a clean exit. An observation failure is not evidence
/// that a PID is still alive, either.
enum ChildEnd: Equatable { case stillRunning, ended(status: Int32?), observationFailed(Int32) }
enum ChildObservation: Equatable { case running, ended(collected: Bool), failed(Int32) }

/// What the system says, without taking the status away from Foundation.
func systemView(of pid: pid_t) -> ChildObservation {
    var info = siginfo_t()
    guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
        let code = errno
        return code == ECHILD ? .ended(collected: true) : .failed(code)
    }
    #if os(Linux)
    let reported = info._sifields._sigchld.si_pid
    #else
    let reported = info.si_pid
    #endif
    return reported == pid ? .ended(collected: false) : .running
}

func childExitStatus(_ raw: Int32) -> Int32 {
    raw & 0x7f == 0 ? (raw >> 8) & 0xff : raw & 0x7f
}

/// Per-child seam: no process-wide hooks or replacement reapers. The real collector is
/// always nonblocking, including when another collector wins after WNOWAIT observation.
struct ChildProcessOperations {
    var foundationStatus: () -> Int32?
    var observe: () -> ChildObservation
    var collect: () -> Int32?
    var now: () -> TimeInterval
    var pause: () -> Void
    var signal: (Int32) -> Void
    var note: (String) -> Void = harnessNote

    static func live(_ child: Process) -> Self {
        let pid = child.processIdentifier
        let origin = ContinuousClock.now
        return Self(
            foundationStatus: { child.isRunning ? nil : child.terminationStatus },
            observe: { systemView(of: pid) },
            collect: {
                var raw: Int32 = 0
                return waitpid(pid, &raw, WNOHANG) == pid ? childExitStatus(raw) : nil
            },
            now: {
                let elapsed = origin.duration(to: .now).components
                return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            },
            pause: { Thread.sleep(forTimeInterval: 0.02) },
            signal: { number in _ = kill(pid, number) })
    }
}

/// A bounded wait. Foundation can lag the system's non-consuming observation; allow a
/// second for it to catch up, then attempt only a nonblocking collection. The historical
/// macOS waitUntilExit hang's cause is unknown; this seam models disagreements, not its cause.
func waitForEnd(of child: Process, limit: TimeInterval, operations: ChildProcessOperations? = nil,
                knownEnded: Bool = false) -> ChildEnd {
    let operations = operations ?? .live(child)
    let start = operations.now()
    var endedSince: TimeInterval? = knownEnded ? start : nil
    var lastError: Int32?
    while true {
        if let status = operations.foundationStatus() { return .ended(status: status) }
        let now = operations.now()
        switch operations.observe() {
        case .ended(let collected):
            let since = endedSince ?? now
            endedSince = since
            // Even a short limit cannot turn an established-dead child into a live timeout.
            if now - since > 1 || now - start >= limit {
                let status = collected ? nil : operations.collect()
                operations.note("child \(child.processIdentifier) has ended (exit status \(collected ? "already collected" : "not yet collected")), but Foundation still reports it running")
                return .ended(status: status)
            }
        case .running:
            if endedSince != nil { return .ended(status: nil) }
            lastError = nil
        case .failed(let code):
            if lastError != code { operations.note("child observation failed with errno \(code); retrying within the wait limit") }
            lastError = code
            // Once established ended, a later observation error cannot authorize a signal.
            if endedSince != nil { return .ended(status: nil) }
        }
        if now - start >= limit {
            if let lastError { return .observationFailed(lastError) }
            return .stillRunning
        }
        operations.pause()
    }
}

/// Real subprocess harness shared by agent, pairing, transfer and clipboard scenarios.
final class AgentHarness {
    let dataDirectory: URL
    let executable: URL
    /// Set on top of the agent's environment. By default the agent runs without its platform
    /// module and without a display: a test agent must never watch the person's real
    /// clipboard or open a window in their session. A test of capture passes
    /// `["CATFLAP_PLATFORM": "on", "WAYLAND_DISPLAY": <its nested compositor>]`.
    let environment: [String: String]
    var process: Process?
    /// Scoped to this harness only; nil uses the real child operations.
    var stopOperations: ChildProcessOperations?
    init(environment: [String: String] = [:]) throws {
        self.environment = environment
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
        child.environment = agentEnvironment(overrides: environment)
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run(); process = child
        // Only a guard against a hang: a loaded runner can take many seconds to start one.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && child.isRunning {
            if let response = try? ControlClient.request(.init("status"), socket: dataDirectory.appendingPathComponent("control.sock")), response.ok { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stop(); throw HarnessError.startupFailed
    }
    /// Stops the agent. One that has to be killed has failed to stop, and that is reported
    /// as a fault: a bounded wait must not let it pass for a clean stop.
    func stop(reportFault: (String) -> Void = harnessError) {
        guard let child = process else { return }
        process = nil
        let pid = child.processIdentifier
        let operations = stopOperations ?? .live(child)
        var knownEnded = false
        if operations.foundationStatus() == nil {
            switch operations.observe() {
            case .running: operations.signal(SIGTERM)
            case .ended: knownEnded = true
            case .failed(let code): reportFault("agent \(pid) observation failed with errno \(code) before SIGTERM")
            }
        }
        let end = waitForEnd(of: child, limit: 7, operations: operations, knownEnded: knownEnded)
        if case .ended(let status) = end {
            guard let status else {
                reportFault("agent \(pid) ended but its exit status was lost")
                return
            }
            if status != 0 {
                reportFault("agent \(pid) ended abnormally with status \(status)")
            }
            return
        }
        if case .observationFailed(let code) = end {
            reportFault("agent \(pid) observation failed with errno \(code); exit not established")
            return
        }
        // Recheck immediately before escalation: a child ending at the deadline must not
        // cause us to signal a PID which the system has already established dead.
        if let status = operations.foundationStatus() {
            if status != 0 {
                reportFault("agent \(pid) ended abnormally with status \(status)")
            }
            return
        }
        switch operations.observe() {
        case .ended:
            reportFault("agent \(pid) ended but its exit status was lost")
        case .failed(let code):
            reportFault("agent \(pid) observation failed with errno \(code) before SIGKILL")
        case .running:
            reportFault("agent \(pid) did not end within 7 s of SIGTERM; sending SIGKILL")
            operations.signal(SIGKILL)
            switch waitForEnd(of: child, limit: 5, operations: operations) {
            case .stillRunning: reportFault("agent \(pid) is still running 5 s after SIGKILL")
            case .observationFailed(let code): reportFault("agent \(pid) observation failed with errno \(code) after SIGKILL")
            case .ended: break // The forced stop has already faulted, whatever its status.
            }
        }
    }
    func restart() throws { stop(); try start() }
    /// Ends this harness's own agent with SIGKILL, as a crash would, and waits for it.
    func killAgent() {
        guard let child = process else { return }
        process = nil
        kill(child.processIdentifier, SIGKILL)
        _ = waitForEnd(of: child, limit: 10)
    }
    func command(_ arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        try runHarnessProcess(executable, arguments: arguments + ["--data-dir", dataDirectory.path, "--json"], timeout: timeout)
    }
}

/// The environment a test agent runs in: this process's, with the display sockets removed and
/// the platform module off, then the test's overrides on top.
func agentEnvironment(overrides: [String: String]) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for name in ["WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY"] { environment[name] = nil }
    environment["CATFLAP_PLATFORM"] = "off"
    environment.merge(overrides) { _, override in override }
    return environment
}

/// A pipe whose two ends are close-on-exec, so only the child it is given to holds its write
/// end. Without that, an agent another test spawns at the same moment inherits the write end
/// and keeps it open for its whole life, and this side sees no end of output until then.
/// (`Process` puts the write end on the child's descriptor 1 or 2, which is not close-on-exec.)
func harnessPipe() -> Pipe {
    let pipe = Pipe()
    for descriptor in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
        _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) | FD_CLOEXEC)
    }
    return pipe
}

/// Reads both output streams of a child to their end, each on a thread of its own: a full
/// parallel run can occupy every thread of the global dispatch queues, and a reader waiting
/// for one could then miss the drain limit although the child had long ended.
final class HarnessReaders: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data(), started = 0
    private let done = DispatchGroup()
    init(output: Pipe, error: Pipe) {
        for (pipe, isOutput) in [(output, true), (error, false)] {
            done.enter()
            Thread.detachNewThread { [self] in
                lock.lock(); started += 1; lock.unlock()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); if isOutput { out = data } else { err = data }; lock.unlock()
                done.leave()
            }
        }
    }
    /// Waits for both streams to end. The limit only keeps a stuck run from hanging.
    func finish(limit: TimeInterval, command: String) -> (output: Data, error: Data)? {
        guard done.wait(timeout: .now() + limit) == .success else {
            lock.lock(); let count = started; lock.unlock()
            harnessNote("\(command): output still open \(Int(limit)) s after the child ended; readers started: \(count) of 2")
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        return (out, err)
    }
}

func runHarnessProcess(_ executable: URL, arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
    let child = Process(); let output = harnessPipe(); let error = harnessPipe()
    child.executableURL = executable
    child.arguments = arguments
    child.standardOutput = output; child.standardError = error
    try child.run()
    // Both streams are drained at once, so a large reply cannot fill a pipe.
    let readers = HarnessReaders(output: output, error: error)
    let end = waitForEnd(of: child, limit: timeout)
    if end == .stillRunning { kill(child.processIdentifier, SIGKILL); _ = waitForEnd(of: child, limit: 5) }
    // Both pipes close once the child has gone.
    let drained = readers.finish(limit: 30, command: commandName(arguments))
    if case .observationFailed(let code) = end { throw HarnessError.processObservationFailed(code) }
    guard case .ended(let status) = end else { throw HarnessError.commandTimedOut }
    guard let drained else { throw HarnessError.outputNotClosed }
    guard let status else { throw HarnessError.exitStatusLost }
    return CommandResult(code: status, output: drained.output, error: drained.error, command: commandName(arguments))
}

@Suite struct HarnessStopTests {
    @Test(arguments: ["exit 0", "exit 23", "kill -KILL $$"])
    func testEndedAgentVerdict(script: String) throws {
        let agent = try AgentHarness()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", script]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        agent.process = child
        #expect(waitForEnd(of: child, limit: 5) != .stillRunning)
        var faults: [String] = []
        agent.stop { faults.append($0) }
        #expect(faults.isEmpty == (script == "exit 0"))
        // Repeated teardown cannot hide or report the same exit twice.
        agent.stop { faults.append($0) }
        #expect(faults.count == (script == "exit 0" ? 0 : 1))
    }
}
