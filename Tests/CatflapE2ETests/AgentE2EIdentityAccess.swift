#if os(macOS)
import CatflapCore
import Foundation
import Testing
import Darwin
import Security

private enum IdentityProbeError: Error, LocalizedError {
    case launchFailed
    case python3LaunchFailed
    var errorDescription: String? {
        switch self {
        case .launchFailed: "Could not launch the measurement process."
        case .python3LaunchFailed: "Could not launch /usr/bin/python3 for the fresh-process Keychain reader."
        }
    }
}
private struct IdentityProbeCommand {
    let code: Int32
    let output: Data
    let error: Data
    let timedOut: Bool
}
private final class IdentityProbeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    func setOutput(_ data: Data) { lock.lock(); stdout = data; lock.unlock() }
    func setError(_ data: Data) { lock.lock(); stderr = data; lock.unlock() }
    func read() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (stdout, stderr) }
}
/// Thread stacks of a process that ran past its limit, so that slow can be told from stuck.
private func identityProbeStacks(of pid: pid_t) -> [String] {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("catflap-sample-" + UUID().uuidString + ".txt")
    defer { try? FileManager.default.removeItem(at: file) }
    let sample = Process()
    sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    sample.arguments = [String(pid), "1", "-mayDie", "-file", file.path]
    sample.standardOutput = FileHandle.nullDevice; sample.standardError = FileHandle.nullDevice
    do { try sample.run() } catch { return ["could not start sample"] }
    if waitForEnd(of: sample, limit: 20) == .stillRunning {
        kill(sample.processIdentifier, SIGKILL); _ = waitForEnd(of: sample, limit: 5)
        return ["sample did not finish"]
    }
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return ["sample wrote nothing"] }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let first = lines.firstIndex(where: { $0.hasPrefix("Call graph:") }) else { return ["sample has no call graph"] }
    return lines[first...].prefix { !$0.hasPrefix("Total number in stack") }.prefix(40).map(identityProbeSafeLine)
}
private func identityProbeCommand(_ executable: URL, _ arguments: [String], timeout: TimeInterval, stacksOnTimeout: Bool = false) throws -> IdentityProbeCommand {
    let process = Process()
    let stdout = Pipe(); let stderr = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = stdout; process.standardError = stderr
    do { try process.run() } catch { throw IdentityProbeError.launchFailed }
    let capture = IdentityProbeOutput()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global().async { capture.setOutput(stdout.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
    readers.enter()
    DispatchQueue.global().async { capture.setError(stderr.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
    var end = waitForEnd(of: process, limit: timeout)
    let timedOut = end == .stillRunning
    if timedOut {
        if stacksOnTimeout {
            for line in identityProbeStacks(of: process.processIdentifier) { print("still running after \(Int(timeout)) s: \(line)") }
        }
        kill(process.processIdentifier, SIGKILL); end = waitForEnd(of: process, limit: 5)
    }
    guard readers.wait(timeout: .now() + 10) == .success else { throw HarnessError.outputNotClosed }
    guard case .ended(let status?) = end else { throw HarnessError.exitStatusLost }
    let (output, error) = capture.read()
    return IdentityProbeCommand(code: status, output: output, error: error, timedOut: timedOut)
}
private func identityProbeSafeLine(_ line: String) -> String {
    line.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "<home>")
}
private func identityProbeLines(_ data: Data) -> [String] {
    String(decoding: data, as: UTF8.self).split(separator: "\n").map { identityProbeSafeLine(String($0)) }
}
private struct SecurityAgentObservation {
    let exists: Bool?
    let code: Int32
    var description: String { "\(exists.map(String.init) ?? "unknown") (exit=\(code))" }
}
private func identityProbeSecurityAgent() throws -> SecurityAgentObservation {
    let result = try identityProbeCommand(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-x", "SecurityAgent"], timeout: 2)
    let exists: Bool? = result.timedOut ? nil : result.code == 0 ? true : result.code == 1 ? false : nil
    return SecurityAgentObservation(exists: exists, code: result.code)
}
private struct IdentityProbeArm {
    let deviceID: String?
    let code: Int32
    let normalExit: Bool
    let stderrLines: [String]
    let seconds: Double
    let socketExists: Bool
    let before: SecurityAgentObservation
    let after: SecurityAgentObservation
}

private func identityProbeFreshProcessReader(disableInteraction: Bool = false) throws -> String {
    let control = disableInteraction ? "s.SecKeychainSetUserInteractionAllowed(0); " : ""
    let script = "import ctypes; s=ctypes.CDLL(\"/System/Library/Frameworks/Security.framework/Security\"); "
        + control + "b=ctypes.c_ubyte(2); r=s.SecKeychainGetUserInteractionAllowed(ctypes.byref(b)); print(r, b.value)"
    let result: IdentityProbeCommand
    do {
        // How fast this reader is says nothing about Catflap. The first launch of the system's
        // python3 in a run was once still going after 5 s while the whole suite was starting,
        // and nothing showed whether it was slow or stuck. The limit only keeps a stuck reader
        // from holding the run, and a reader that reaches it prints where it was.
        result = try identityProbeCommand(URL(fileURLWithPath: "/usr/bin/python3"), ["-c", script], timeout: 30, stacksOnTimeout: true)
    } catch { throw IdentityProbeError.python3LaunchFailed }
    if result.timedOut || result.code != 0 {
        print("fresh-process reader failed: exit=\(result.code); timed out=\(result.timedOut); first stderr=\(identityProbeLines(result.error).first ?? "<none>")")
    }
    try #require(!result.timedOut)
    try #require(result.code == 0)
    return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The control and differently signed copies use the same bounded startup/status probe.
private func identityProbeArm(_ executable: URL, directory: URL, label: String, onReady: (() throws -> Void)? = nil) throws -> IdentityProbeArm {
    let before = try identityProbeSecurityAgent()
    let child = Process()
    let stderr = Pipe()
    child.executableURL = executable
    child.arguments = ["agent", "--data-dir", directory.path]
    child.environment = agentEnvironment(overrides: [:])
    child.standardOutput = FileHandle.nullDevice
    child.standardError = stderr
    defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); _ = waitForEnd(of: child, limit: 5) } }
    let start = ContinuousClock.now
    let deadline = start.advanced(by: .seconds(5))
    do { try child.run() } catch { throw IdentityProbeError.launchFailed }
    var deviceID: String?
    var lastExit = "not attempted"
    var lastStderr = "<none>"
    var lastResult = "not attempted"
    while child.isRunning && ContinuousClock.now < deadline {
        let remaining = ContinuousClock.now.duration(to: deadline)
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        if seconds <= 0 { break }
        let attempt = try identityProbeCommand(executable, ["status", "--data-dir", directory.path, "--json"], timeout: min(2, seconds))
        lastExit = String(attempt.code)
        lastStderr = identityProbeLines(attempt.error).first ?? "<none>"
        if attempt.timedOut {
            lastExit += " (timed out)"
            lastResult = "timed out"
        } else if attempt.code != 0 {
            lastResult = "failed"
        } else {
            do {
                deviceID = try ControlJSON.decoder.decode(AgentStatus.self, from: attempt.output).deviceID
                lastResult = "status decoded"
            } catch { lastResult = "invalid status JSON" }
        }
        if deviceID != nil { break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    let elapsed = start.duration(to: .now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    if let onReady, deviceID != nil {
        let runningBeforeReader = child.isRunning
        try #require(runningBeforeReader)
        try onReady()
        let runningAfterReader = child.isRunning
        try #require(runningAfterReader)
    }
    let socketExists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path)
    let after = try identityProbeSecurityAgent()
    if child.isRunning {
        child.terminate()
        if waitForEnd(of: child, limit: 1) == .stillRunning { kill(child.processIdentifier, SIGKILL) }
    }
    // The exit status below is Foundation's, so Foundation has to have recorded the exit.
    guard waitForEnd(of: child, limit: 5) != .stillRunning, !child.isRunning else { throw HarnessError.exitStatusLost }
    let lines = identityProbeLines(stderr.fileHandleForReading.readDataToEndOfFile())
    let status = lines.dropFirst().compactMap(Int32.init).first
    print("\(label): started=\(deviceID != nil); exit=\(child.terminationStatus); first stderr=\(lines.first ?? "<none>"); OSStatus=\(status.map(String.init) ?? "none"); seconds=\(String(format: "%.3f", seconds)); last status exit=\(lastExit); last status stderr=\(lastStderr); last status result=\(lastResult); control.sock=\(socketExists); SecurityAgent before=\(before.description); SecurityAgent after=\(after.description)")
    for line in lines { print("\(label): stderr: \(line)") }
    return IdentityProbeArm(deviceID: deviceID, code: child.terminationStatus, normalExit: child.terminationReason == .exit,
                            stderrLines: lines, seconds: seconds, socketExists: socketExists, before: before, after: after)
}

extension AgentE2E {
    @Test func testDifferentlySignedCopyIsRefusedWithoutDialog() throws {
        let agent = try AgentHarness()
        let parent = agent.executable.deletingLastPathComponent()
        let plain = parent.appendingPathComponent("catflap-control-" + UUID().uuidString)
        let resigned = parent.appendingPathComponent("catflap-resigned-" + UUID().uuidString)
        defer {
            agent.stop()
            try? agent.eraseIdentity()
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: resigned)
        }
        let readerControl = try identityProbeFreshProcessReader(disableInteraction: true)
        print("reader control: \(readerControl)")
        #expect(readerControl == "0 0")
        try FileManager.default.copyItem(at: agent.executable, to: plain)
        try agent.start()
        let originalID = try agent.command(["status"]).decode(AgentStatus.self).deviceID
        agent.stop()
        var readerObservedRunningAgent = false
        let control = try identityProbeArm(plain, directory: agent.dataDirectory, label: "control copy", onReady: {
            let state = try identityProbeFreshProcessReader()
            print("fresh process, agent running: \(state)")
            #expect(state == "0 1")
            readerObservedRunningAgent = true
        })
        #expect(readerObservedRunningAgent)
        #expect(control.deviceID == originalID)
        #expect(control.normalExit)
        #expect(control.code == 0)

        // The control child has exited before another arm is launched.
        try FileManager.default.copyItem(at: agent.executable, to: resigned)
        let signed = try runHarnessProcess(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: [
            "--force", "--sign", "-", "--identifier", "dev.catflap.resigned", resigned.path
        ])
        try #require(signed.code == 0)
        let result = try identityProbeArm(resigned, directory: agent.dataDirectory, label: "resigned copy")
        #expect(result.deviceID == nil)
        #expect(result.normalExit)
        #expect(result.code == 1)
        #expect(result.seconds < 5)
        #expect(!result.socketExists)
        #expect(result.stderrLines == [AgentError.identity.rawValue, String(errSecAuthFailed),
            "macOS refused this copy of Catflap access to its stored keys. A copy signed differently from the one that stored them is refused this way."])
        #expect(result.before.exists != nil)
        #expect(result.after.exists != nil)
        if result.before.exists == true {
            print("SecurityAgent was already running before resigned copy; only the no-new-agent assertion is omitted")
        } else {
            #expect(result.before.exists == false)
            #expect(result.after.exists == false)
        }

        let freshState = try identityProbeFreshProcessReader()
        print("fresh process, after refused copy: \(freshState)")
        #expect(freshState == "0 1")

        try agent.start()
        let sameID = try agent.command(["status"]).decode(AgentStatus.self).deviceID == originalID
        #expect(sameID)
        agent.stop()
        let erased = try agent.eraseIdentity()
        let metadataExists = FileManager.default.fileExists(atPath: agent.dataDirectory.appendingPathComponent("identity.json").path)
        #expect(erased.code == 0)
        #expect(!metadataExists)
        print("original binary after refusal: same-id=\(sameID); cleanup exit=\(erased.code); identity.json=\(metadataExists)")
    }
}
#endif
