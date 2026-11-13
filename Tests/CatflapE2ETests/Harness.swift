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

enum HarnessError: Error { case executableMissing, startupFailed, commandTimedOut }
struct CommandResult {
    let code: Int32
    let output: Data
    let error: Data
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try ControlJSON.decoder.decode(type, from: output) }
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
        if child.isRunning { child.terminate() }
        let deadline = Date().addingTimeInterval(7)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit(); process = nil
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
    let deadline = Date().addingTimeInterval(timeout)
    while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit(); group.wait(); throw HarnessError.commandTimedOut }
    child.waitUntilExit(); group.wait()
    return CommandResult(code: child.terminationStatus, output: buffers.output, error: buffers.error)
}
private final class HarnessBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(); private var err = Data()
    var output: Data { lock.lock(); defer { lock.unlock() }; return out }
    var error: Data { lock.lock(); defer { lock.unlock() }; return err }
    func setOutput(_ value: Data) { lock.lock(); out = value; lock.unlock() }
    func setError(_ value: Data) { lock.lock(); err = value; lock.unlock() }
}
