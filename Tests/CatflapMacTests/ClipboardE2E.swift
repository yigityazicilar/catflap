#if os(macOS)
import AppKit
@testable import CatflapMac
import CatflapCore
import Darwin
import Foundation
import Testing

private enum ClipboardTestError: Error { case executableMissing, startup, timeout, exitStatus, snapshot }
private final class ClipboardBundleMarker: NSObject {}

// Blocking process waits belong on a real thread, not Swift's cooperative executor.
private func clipboardOffPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

private struct ClipboardCommand {
    let code: Int32
    let output: Data
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try ControlJSON.decoder.decode(type, from: output) }
}

// Foundation's unbounded wait can miss a child's exit on macOS. Ask the kernel too and
// always enforce a deadline, including when cleaning up after an assertion fails.
private func clipboardWait(_ process: Process, seconds: TimeInterval) -> Int32? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if !process.isRunning { return process.terminationStatus }
        var info = siginfo_t()
        if waitid(P_PID, id_t(process.processIdentifier), &info, WEXITED | WNOHANG | WNOWAIT) == 0,
           info.si_pid == process.processIdentifier { return info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return nil
}

// Only immutable command paths cross into the timing probe; lifecycle operations remain
// with the test owner, which awaits the probe before teardown.
private final class ClipboardAgent: @unchecked Sendable {
    let directory: URL
    let executable: URL
    private var process: Process?
    init() throws {
        var location = Bundle(for: ClipboardBundleMarker.self).bundleURL
        var found: URL?
        if let override = ProcessInfo.processInfo.environment["CATFLAP_EXECUTABLE"] {
            found = URL(fileURLWithPath: override)
        } else {
            for _ in 0..<7 {
                let candidate = location.appendingPathComponent("catflap")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { found = candidate; break }
                location.deleteLastPathComponent()
            }
        }
        guard let found else { throw ClipboardTestError.executableMissing }
        executable = found
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    deinit { close() }
    func run(_ tool: URL, _ arguments: [String], input: Data? = nil) throws -> ClipboardCommand {
        let outputURL = directory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
        let child = Process()
        child.executableURL = tool; child.arguments = arguments
        child.standardOutput = output; child.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        if input != nil { child.standardInput = pipe }
        try child.run()
        if let input { pipe.fileHandleForWriting.write(input); try pipe.fileHandleForWriting.close() }
        guard let code = clipboardWait(child, seconds: 10) else {
            kill(child.processIdentifier, SIGKILL); _ = clipboardWait(child, seconds: 5)
            throw ClipboardTestError.timeout
        }
        return ClipboardCommand(code: code, output: try Data(contentsOf: outputURL))
    }
    func command(_ arguments: [String]) throws -> ClipboardCommand {
        try run(executable, arguments + ["--data-dir", directory.path, "--json"])
    }
    func start() throws {
        let child = Process()
        child.executableURL = executable; child.arguments = ["agent", "--data-dir", directory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CATFLAP_PLATFORM"] = "on"
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); process = child
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, child.isRunning {
            if let status = try? command(["status"]).decode(AgentStatus.self), status.clipboardCapture == "active" { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ClipboardTestError.startup
    }
    func close() {
        if let child = process {
            process = nil
            if child.isRunning { child.terminate() }
            if clipboardWait(child, seconds: 7) == nil {
                FileHandle.standardError.write(Data("harness-error: clipboard agent failed to stop within 7 s\n".utf8))
                Issue.record("Clipboard agent failed to stop within 7 s")
                kill(child.processIdentifier, SIGKILL); _ = clipboardWait(child, seconds: 5)
            }
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            if let result = try? run(executable, ["erase-identity", "--data-dir", directory.path]) {
                #expect(result.code == 0)
            } else { Issue.record("Could not erase test identity") }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

@MainActor
private struct PasteboardSnapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]]
    init() throws {
        let board = NSPasteboard.general
        let count = board.changeCount
        items = try (board.pasteboardItems ?? []).map { item in
            try item.types.map { type in
                guard let data = item.data(forType: type) else { throw ClipboardTestError.snapshot }
                return (type, data)
            }
        }
        guard board.changeCount == count else { throw ClipboardTestError.snapshot }
    }
    func restore() {
        let board = NSPasteboard.general
        board.clearContents()
        let restored = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { #expect(board.writeObjects(restored)) }
    }
}

@Suite(.serialized)
@MainActor
struct MacClipboardE2E {
    private func withAgent(_ body: (ClipboardAgent) async throws -> Void) async throws {
        let saved = try PasteboardSnapshot()
        defer { saved.restore() }
        let agent = try ClipboardAgent()
        defer { agent.close() }
        try agent.start()
        try await body(agent)
    }
    private func copy(_ text: String, agent: ClipboardAgent) throws {
        #expect(try agent.run(URL(fileURLWithPath: "/usr/bin/pbcopy"), [], input: Data(text.utf8)).code == 0)
    }
    private func copyAndWaitFor(_ text: String, agent: ClipboardAgent) async throws {
        // Keep blocking process waits off both the main actor and the cooperative pool.
        // Measure pbcopy and CLI polling on one dedicated thread, without changing the
        // two-second acceptance deadline.
        let observed = try await clipboardOffPool { () throws -> (Bool, Duration) in
            let clock = ContinuousClock()
            let start = clock.now
            let copied = try agent.run(URL(fileURLWithPath: "/usr/bin/pbcopy"), [], input: Data(text.utf8))
            guard copied.code == 0 else { throw ClipboardTestError.exitStatus }
            while clock.now - start < .seconds(2) {
                let result = try agent.command(["clip", "list"])
                guard result.code == 0 else { throw ClipboardTestError.exitStatus }
                if try result.decode([ClipboardItem].self).contains(where: { $0.text == text }) {
                    return (true, clock.now - start)
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            return (false, clock.now - start)
        }
        print("MacClipboardE2E pbcopy listed=\(observed.0) elapsed=\(observed.1)")
        #expect(observed.0 && observed.1 < .seconds(2), "pbcopy content must be listed by catflap clip within 2 s")
    }
    @Test func testOrdinaryCopyAndPasteboardAccessStatus() async throws {
        try await withAgent { agent in
            let response = try agent.command(["status"])
            #expect(response.code == 0)
            let status = try response.decode(AgentStatus.self)
            #expect(status.clipboardCapture == "active")
            #expect(["default", "ask", "alwaysAllow", "alwaysDeny"].contains(status.pasteboardAccess ?? ""))
            let json = try JSONSerialization.jsonObject(with: response.output) as? [String: Any]
            #expect(json?["pasteboard_access"] as? String == status.pasteboardAccess)
            print("MacClipboardE2E status: pasteboard_access=\(status.pasteboardAccess ?? "missing") clipboard_capture=\(status.clipboardCapture)")
            let text = "ordinary clipboard note " + UUID().uuidString
            try await copyAndWaitFor(text, agent: agent)
        }
    }
    @Test func testMarkedCopyStoresNothing() async throws {
        try await withAgent { agent in
            let text = "marked clipboard note " + UUID().uuidString
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
            NSPasteboard.general.clearContents()
            #expect(NSPasteboard.general.writeObjects([item]))
            try await Task.sleep(for: .milliseconds(500))
            #expect(try agent.command(["clip", "list"]).decode([ClipboardItem].self).isEmpty)
            // A following ordinary copy proves the watcher remains live after the marker.
            let next = "following clipboard note " + UUID().uuidString
            try await copyAndWaitFor(next, agent: agent)
            let items = try agent.command(["clip", "list"]).decode([ClipboardItem].self)
            #expect(items.count == 1)
            #expect(!items.contains { $0.text == text })
            for url in try FileManager.default.contentsOfDirectory(at: agent.directory, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix("store.sqlite") {
                #expect(try Data(contentsOf: url).range(of: Data(text.utf8)) == nil)
            }
        }
    }
    @Test func testPausedAgentStoresNothing() async throws {
        try await withAgent { agent in
            #expect(try agent.command(["clip", "pause", "on"]).code == 0)
            let text = "paused clipboard note " + UUID().uuidString
            try copy(text, agent: agent)
            try await Task.sleep(for: .milliseconds(500))
            #expect(try agent.command(["clip", "list"]).decode([ClipboardItem].self).isEmpty)
            #expect(try agent.command(["clip", "pause", "off"]).code == 0)
            try await Task.sleep(for: .milliseconds(250))
            #expect(try agent.command(["clip", "list"]).decode([ClipboardItem].self).isEmpty)
            let next = "resumed clipboard note " + UUID().uuidString
            try await copyAndWaitFor(next, agent: agent)
            let items = try agent.command(["clip", "list"]).decode([ClipboardItem].self)
            #expect(items.count == 1)
            #expect(!items.contains { $0.text == text })
        }
    }
}
#endif
