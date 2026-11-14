#if os(macOS)
import AppKit
import Carbon
import CatflapCore
import Foundation
import Testing

private final class ReviewMarker: NSObject {}
private func offThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in Thread.detachNewThread { c.resume(with: Result { try body() }) } }
}
private func waitChild(_ p: Process) -> Int32? {
    let end = ContinuousClock.now + .seconds(60)
    while ContinuousClock.now < end {
        if !p.isRunning { return p.terminationStatus }
        var info = siginfo_t()
        if waitid(P_PID, id_t(p.processIdentifier), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == p.processIdentifier { return info.si_status }
        Thread.sleep(forTimeInterval: 0.02)
    }
    kill(p.processIdentifier, SIGKILL)
    return nil
}
private func run(_ program: URL, _ arguments: [String], env: [String:String], at dir: URL) throws -> Int32? {
    let p = Process(); p.executableURL = program; p.arguments = arguments; p.environment = env
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); return waitChild(p)
}
@Suite(.serialized) struct ReviewMKResources {
    @Test @MainActor func testInProcessRegistrationFailureMustNotLoadMissingBundle() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rr-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var location = Bundle(for: ReviewMarker.self).bundleURL
        var binary: URL?
        for _ in 0..<8 {
            let candidate = location.appendingPathComponent("catflap")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { binary = candidate; break }
            location.deleteLastPathComponent()
        }
        let source = try #require(binary)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CATFLAP_SIGN_IDENTITY")
        environment["CATFLAP_PLATFORM"] = "on"
        environment["CATFLAP_REVIEW_IN_PROCESS_CONFLICT"] = "1"
        let env = environment
        let built = try await offThread { try run(URL(fileURLWithPath: "/bin/bash"), [root.appendingPathComponent("packaging/macos/bundle.sh").path, "--binary", source.path, "--output", scratch.path], env: env, at: scratch) }
        #expect(built == 0)
        let installed = scratch.appendingPathComponent("Catflap.app/Contents/MacOS/catflap")
        let data = scratch.appendingPathComponent("data")
        let errorFile = scratch.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let profile = "(version 1)(allow default)(deny file-read* (subpath \"\(root.path)\"))"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", profile, installed.path, "agent", "--data-dir", data.path]
        let stdoutFile = scratch.appendingPathComponent("stdout")
        FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdoutFile)
        p.environment = env; p.standardOutput = out
        let err = try FileHandle(forWritingTo: errorFile); p.standardError = err
        try p.run()
        let survived = try await offThread { () -> Bool in
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline, p.isRunning {
                if let state = try? ControlClient.request(ControlRequest("ui.state"), socket: data.appendingPathComponent("control.sock")), state.ok,
                   let object = try? JSONSerialization.jsonObject(with: state.payload) as? [String:Any], object["send_shortcut"] != nil { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return false
        }
        if p.isRunning { p.terminate() }
        let code = try await offThread { waitChild(p) }
        try err.close(); try out.close()
        let text = try String(contentsOf: errorFile, encoding: .utf8)
        let stdout = try String(contentsOf: stdoutFile, encoding: .utf8)
        let resourceFatal = text.localizedCaseInsensitiveContains("bundle")
        func safe(_ value: String) -> String {
            value.replacingOccurrences(of: #"/[^\s]+"#, with: "[path]", options: .regularExpression)
                .replacingOccurrences(of: #"\b(?:tc[A-Za-z0-9_-]{40,}|[A-Za-z0-9+/=_-]{40,})\b"#, with: "[redacted]", options: .regularExpression)
        }
        print("REVIEW macOS stderr first: \(safe(text.split(separator: "\n").prefix(8).joined(separator: " | ")))")
        print("REVIEW macOS stderr last: \(safe(text.split(separator: "\n").suffix(20).joined(separator: " | ")))")
        print("REVIEW macOS stdout: \(safe(stdout))")
        if !p.isRunning { print("REVIEW macOS Foundation exit: status=\(p.terminationStatus) reason=\(p.terminationReason.rawValue)") }
        if let files = FileManager.default.enumerator(at: root.appendingPathComponent(".build"), includingPropertiesForKeys: nil) {
            for file in (files.allObjects as? [URL]) ?? [] where file.lastPathComponent == "resource_bundle_accessor.swift" && file.path.contains("KeyboardShortcuts.build") {
                print("REVIEW accessor: \(safe(try String(contentsOf: file, encoding: .utf8)))")
                break
            }
        }
        let cleanup = try await offThread { try run(installed, ["erase-identity", "--data-dir", data.path], env: env, at: scratch) }
        print("REVIEW macOS in-process conflict: survived=\(survived) resourceFatal=\(resourceFatal) exitNonzero=\(code != 0) cleanup=\(cleanup == 0)")
        #expect(survived, "an installed agent must report the shortcut conflict without crashing")
    }
}
#endif
