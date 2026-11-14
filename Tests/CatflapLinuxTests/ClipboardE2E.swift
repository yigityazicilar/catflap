import CatflapCore
import Foundation
import Glibc
import XCTest

private enum ClipboardTestError: Error { case missingExecutable, timedOut, commandFailed, startupFailed }

/// Every process uses a private runtime directory and an explicitly isolated display.
private final class ClipboardSession {
    let root: URL
    let executable: URL
    var environment: [String: String]
    private var children: [(Process, Bool)] = []
    private(set) var agentLog: URL?
    let data: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cb-" + UUID().uuidString.prefix(8))
        data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("catflap")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { found = candidate; break }
            directory.deleteLastPathComponent()
        }
        guard let path = ProcessInfo.processInfo.environment["CATFLAP_EXECUTABLE"].map(URL.init(fileURLWithPath:)) ?? found else {
            throw ClipboardTestError.missingExecutable
        }
        executable = path
        environment = ProcessInfo.processInfo.environment
        for name in ["WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY"] { environment[name] = nil }
        environment["CATFLAP_PLATFORM"] = "on"
        // Capture only: the panel (T10) would start GTK, which adds seconds and tests nothing here.
        environment["CATFLAP_PANEL"] = "off"
        environment["XDG_RUNTIME_DIR"] = root.path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_DATA_HOME"] = root.appendingPathComponent("share").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
    }

    deinit {
        for (child, agent) in children.reversed() { stop(child, agent: agent) }
        try? FileManager.default.removeItem(at: root)
    }

    private func stop(_ child: Process, agent: Bool) {
        guard child.isRunning else { return }
        child.terminate()
        if !wait(child, seconds: agent ? 7 : 5) {
            XCTFail(agent ? "Agent did not stop within 7 s of SIGTERM" : "Clipboard helper did not stop")
            kill(child.processIdentifier, SIGKILL)
            XCTAssertTrue(wait(child, seconds: 5))
        }
        if agent { XCTAssertEqual(child.terminationStatus, 0) }
    }

    private func wait(_ child: Process, seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while child.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        return !child.isRunning
    }

    @discardableResult
    func launch(_ path: String, _ arguments: [String], agent: Bool = false, trace: Bool = false, input: URL? = nil) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: path)
        child.arguments = arguments
        child.environment = environment
        if trace { child.environment?["WAYLAND_DEBUG"] = "client" }
        child.standardOutput = FileHandle.nullDevice
        if let input { child.standardInput = try FileHandle(forReadingFrom: input) }
        let log = root.appendingPathComponent("log-" + UUID().uuidString)
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        child.standardError = try FileHandle(forWritingTo: log)
        try child.run()
        children.append((child, agent))
        if agent { agentLog = log }
        return child
    }

    func command(_ arguments: [String]) throws -> Data {
        let output = root.appendingPathComponent("output-" + UUID().uuidString)
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments + ["--data-dir", data.path, "--json"]
        child.environment = environment
        child.standardOutput = try FileHandle(forWritingTo: output)
        child.standardError = FileHandle.nullDevice
        try child.run()
        if !wait(child, seconds: 10) {
            kill(child.processIdentifier, SIGKILL)
            _ = wait(child, seconds: 5)
            throw ClipboardTestError.timedOut
        }
        guard child.terminationStatus == 0 else { throw ClipboardTestError.commandFailed }
        return try Data(contentsOf: output)
    }

    func startAgent(expected: String) throws {
        let child = try launch(executable.path, ["agent", "--data-dir", data.path], agent: true, trace: true)
        let deadline = Date().addingTimeInterval(10)
        while child.isRunning && Date() < deadline {
            if let bytes = try? command(["status"]),
               let status = try? ControlJSON.decoder.decode(AgentStatus.self, from: bytes),
               status.clipboardCapture == expected {
                // Unsupported is also the initial state. Require a completed protocol probe
                // when a display was configured, not just the initial control reply.
                if expected != "unsupported" || environment["WAYLAND_DISPLAY"] == nil || trace().contains(".done(") {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw ClipboardTestError.startupFailed
    }

    func trace() -> String {
        guard let agentLog else { return "" }
        return (try? String(contentsOf: agentLog, encoding: .utf8)) ?? ""
    }

    func items() throws -> [ClipboardItem] {
        try ControlJSON.decoder.decode([ClipboardItem].self, from: command(["clip", "list"]))
    }

    func waitForText(_ text: String, seconds: TimeInterval = 2) throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if try items().contains(where: { $0.text == text }) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < end
        return false
    }

    func copy(_ text: String, sensitive: Bool = false, mime: String = "text/plain;charset=utf-8") throws {
        var args = ["--foreground", "--type", mime]
        if sensitive { args.append("--sensitive") }
        args.append(text)
        _ = try launch("/usr/bin/wl-copy", args)
    }

    func copyBytes(_ bytes: Data, mime: String) throws {
        let input = root.appendingPathComponent("input-" + UUID().uuidString)
        try bytes.write(to: input)
        _ = try launch("/usr/bin/wl-copy", ["--foreground", "--type", mime], input: input)
    }

    func startCompositor() throws {
        // CI=true is the explicit CI gate: only these desktop E2Es may skip when
        // the runner has no headless ext-data-control compositor. Status tests still run.
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/kwin_wayland") else {
            if ProcessInfo.processInfo.environment["CI"] == "true" {
                throw XCTSkip("CI=true: no nested KWin/ext-data-control compositor installed")
            }
            XCTFail("Nested KWin is required; the live display is never used")
            throw ClipboardTestError.startupFailed
        }
        environment["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + root.appendingPathComponent("bus").path
        _ = try launch("/usr/bin/dbus-daemon", ["--session", "--nofork", "--address=" + environment["DBUS_SESSION_BUS_ADDRESS"]!])
        environment["QT_QPA_PLATFORM"] = "offscreen"
        environment["KWIN_COMPOSE"] = "Q"
        environment["LIBGL_ALWAYS_SOFTWARE"] = "1"
        environment["WAYLAND_DISPLAY"] = "clipboard-test"
        let child = try launch("/usr/bin/kwin_wayland", ["--virtual", "--socket", "clipboard-test", "--no-lockscreen", "--no-global-shortcuts", "--no-kactivities", "--width", "320", "--height", "240"])
        let deadline = Date().addingTimeInterval(10)
        while child.isRunning && Date() < deadline {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("clipboard-test").path) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw ClipboardTestError.startupFailed
    }

    func startWithoutDataControl() throws {
        // A real Wayland server answers registry/sync, but advertises no data-control
        // global. No connection to the person's display is possible in this fixture.
        let source = root.appendingPathComponent("compositor.c")
        let program = root.appendingPathComponent("compositor")
        try """
        #include <wayland-server-core.h>
        int main(void) {
            struct wl_display *d = wl_display_create();
            if (!d || wl_display_add_socket(d, "unsupported") < 0) return 1;
            wl_display_run(d);
            wl_display_destroy(d);
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = try launch("/usr/bin/cc", [source.path, "-lwayland-server", "-o", program.path])
        guard wait(compiler, seconds: 10), compiler.terminationStatus == 0 else { throw ClipboardTestError.commandFailed }
        environment["WAYLAND_DISPLAY"] = "unsupported"
        let child = try launch(program.path, [])
        let end = Date().addingTimeInterval(5)
        while child.isRunning && Date() < end {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("unsupported").path) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw ClipboardTestError.startupFailed
    }
}

final class LinuxClipboardE2E: XCTestCase {
    func testOrdinaryCopyAppearsWithinTwoSeconds() throws {
        let session = try ClipboardSession()
        try session.startCompositor()
        try session.startAgent(expected: "active")
        let text = "ordinary clipboard copy " + UUID().uuidString
        let start = ContinuousClock.now
        try session.copy(text)
        XCTAssertTrue(try session.waitForText(text))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertTrue(session.trace().contains("ext_data_control_manager_v1"))
    }

    func testMarkedCopyIsUnreadAndStoresNothing() throws {
        let session = try ClipboardSession()
        try session.startCompositor()
        try session.startAgent(expected: "active")
        try session.copy("marked clipboard copy " + UUID().uuidString, sensitive: true)
        let end = Date().addingTimeInterval(3)
        while Date() < end && !session.trace().contains("x-kde-passwordManagerHint") { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(session.trace().contains("x-kde-passwordManagerHint"))
        // A following ordinary copy is a barrier proving the watcher handled the marked
        // offer, not just that the test looked before the event was delivered.
        let text = "following ordinary clipboard copy " + UUID().uuidString
        try session.copy(text)
        XCTAssertTrue(try session.waitForText(text))
        let items = try session.items()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.text, text)
        let trace = session.trace()
        let markedLine = try XCTUnwrap(trace.components(separatedBy: .newlines).first { $0.contains(".offer(\"x-kde-passwordManagerHint\"") })
        let expression = try NSRegularExpression(pattern: "ext_data_control_offer_v1[@#][0-9]+")
        let match = try XCTUnwrap(expression.firstMatch(in: markedLine, range: NSRange(markedLine.startIndex..., in: markedLine)))
        let range = try XCTUnwrap(Range(match.range, in: markedLine))
        let object = String(markedLine[range])
        let afterMarker = try XCTUnwrap(trace.range(of: markedLine)).upperBound
        // Object ids may be reused after destroy, so only inspect this offer's lifetime.
        let lifetime = trace[afterMarker...].components(separatedBy: object + ".destroy()").first ?? ""
        XCTAssertFalse(lifetime.contains(object + ".receive("))
    }

    func testAllowedTypesAndUnknownSizeLimit() throws {
        let session = try ClipboardSession()
        try session.startCompositor()
        try session.startAgent(expected: "active")
        let fileURL = session.root.appendingPathComponent("reference-only.txt").absoluteString
        for text in [fileURL, "https://example.org/clipboard"] {
            try session.copy(text, mime: "text/uri-list")
            XCTAssertTrue(try session.waitForText(text))
            XCTAssertEqual(try session.items().first?.kind, text == fileURL ? .files : .url)
        }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0WQAAAAASUVORK5CYII="))
        try session.copyBytes(png, mime: "image/png")
        let end = Date().addingTimeInterval(5)
        var captured = false
        repeat {
            captured = try session.items().contains { $0.kind == .image && $0.mime == "image/png" && $0.content == png }
            if captured { break }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < end
        XCTAssertTrue(captured)
        let readsBeforeOversize = session.trace().components(separatedBy: ".receive(").count
        try session.copyBytes(Data(repeating: 97, count: ClipboardHistory.textLimit + 1), mime: "text/plain")
        let readEnd = Date().addingTimeInterval(5)
        while Date() < readEnd && session.trace().components(separatedBy: ".receive(").count == readsBeforeOversize {
            Thread.sleep(forTimeInterval: 0.02)
        }
        // wl-copy can add UTF-8 aliases, and the watcher prefers one of those. Require a
        // receive for this offer without assuming which equivalent text MIME it chose.
        XCTAssertGreaterThan(session.trace().components(separatedBy: ".receive(").count, readsBeforeOversize)
        let text = "copy after an oversize clipboard item " + UUID().uuidString
        try session.copy(text)
        XCTAssertTrue(try session.waitForText(text))
        XCTAssertEqual(try session.items().count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.root.appendingPathComponent("reference-only.txt").path))
    }

    func testPausedAgentRecordsNothing() throws {
        let session = try ClipboardSession()
        try session.startCompositor()
        try session.startAgent(expected: "active")
        _ = try session.command(["clip", "pause", "on"])
        let paused = "paused ordinary clipboard copy " + UUID().uuidString
        try session.copy(paused)
        let end = Date().addingTimeInterval(3)
        while Date() < end && !session.trace().contains("text/plain;charset=utf-8") { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(session.trace().contains("text/plain;charset=utf-8"))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(try session.items().isEmpty)
        XCTAssertFalse(session.trace().contains(".receive("))
        _ = try session.command(["clip", "pause", "off"])
        let text = "resumed ordinary clipboard copy " + UUID().uuidString
        try session.copy(text)
        XCTAssertTrue(try session.waitForText(text))
        XCTAssertEqual(try session.items().count, 1)
    }
}

final class ClipboardStatusTests: XCTestCase {
    func testMissingDataControlReportsUnsupported() throws {
        let session = try ClipboardSession()
        try session.startWithoutDataControl()
        try session.startAgent(expected: "unsupported")
        let status = try ControlJSON.decoder.decode(AgentStatus.self, from: session.command(["status"]))
        XCTAssertEqual(status.clipboardCapture, "unsupported")
        XCTAssertFalse(session.trace().contains("ext_data_control_manager_v1@"))
        XCTAssertTrue(try session.items().isEmpty)
    }
}
