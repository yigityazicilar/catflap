#if os(macOS)
@testable import CatflapMac
import CatflapCore
import AppKit
import CoreGraphics
import Darwin
import Foundation
import Testing

private enum PanelTestError: Error { case executableMissing, startup, timeout, decode(String) }
private final class PanelBundleMarker: NSObject {}

// Blocking process waits belong on a real thread, not on Swift's cooperative executor.
private func panelOffPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

private struct PanelCommand: Sendable {
    let code: Int32
    let output: Data
    let error: Data
    var text: String { String(decoding: output, as: UTF8.self) }
    var errorText: String { String(decoding: error, as: UTF8.self) }
    func state() throws -> MacUIState {
        do { return try ControlJSON.decoder.decode(MacUIState.self, from: output) }
        catch { throw PanelTestError.decode("exit \(code), output \(text), error \(errorText)") }
    }
}

// Foundation's unbounded wait can miss a child's exit on macOS. Ask the kernel too and
// always enforce a deadline.
private func panelWait(_ process: Process, seconds: TimeInterval) -> Int32? {
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

private func panelRun(_ tool: String, _ arguments: [String], environment: [String: String]? = nil,
                      in directory: URL, seconds: TimeInterval = 20) throws -> PanelCommand {
    let outputURL = directory.appendingPathComponent(UUID().uuidString)
    let errorURL = directory.appendingPathComponent(UUID().uuidString)
    for url in [outputURL, errorURL] {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    defer { for url in [outputURL, errorURL] { try? FileManager.default.removeItem(at: url) } }
    let output = try FileHandle(forWritingTo: outputURL), error = try FileHandle(forWritingTo: errorURL)
    defer { try? output.close(); try? error.close() }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: tool)
    child.arguments = arguments
    if let environment { child.environment = environment }
    child.standardOutput = output
    child.standardError = error
    child.standardInput = FileHandle.nullDevice
    try child.run()
    guard let code = panelWait(child, seconds: seconds) else {
        kill(child.processIdentifier, SIGKILL); _ = panelWait(child, seconds: 5)
        throw PanelTestError.timeout
    }
    return PanelCommand(code: code, output: try Data(contentsOf: outputURL), error: try Data(contentsOf: errorURL))
}

private func locateExecutable() throws -> URL {
    if let override = ProcessInfo.processInfo.environment["CATFLAP_EXECUTABLE"] { return URL(fileURLWithPath: override) }
    var location = Bundle(for: PanelBundleMarker.self).bundleURL
    for _ in 0..<7 {
        let candidate = location.appendingPathComponent("catflap")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        location.deleteLastPathComponent()
    }
    throw PanelTestError.executableMissing
}

private func scratchDirectory(_ prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory
}

/// An agent with its platform module on, in a private data directory. The menu bar item is
/// switched on for it, and the preferences domain an unbundled `catflap` writes to (the item's
/// position) is saved before the agent starts and put back after it stops.
///
/// Every call that waits runs on its own thread; assertions stay in the test's own context.
private final class PanelAgent: @unchecked Sendable {
    static let preferencesDomain = "catflap"
    let directory: URL
    let executable: URL
    private var process: Process?
    private var savedPreferences: Data?

    init() throws {
        executable = try locateExecutable()
        directory = try scratchDirectory("cp-")
    }

    func command(_ arguments: [String]) async throws -> PanelCommand {
        try await panelOffPool { try self.runCommand(arguments) }
    }

    func invoke(_ action: String) async throws -> MacUIState { try await command(["ui", "invoke", action]).state() }
    func state() async throws -> MacUIState { try await command(["ui", "state"]).state() }

    /// Polls `ui state` until `done` holds or ten seconds pass, and returns the last state.
    func waitForState(_ done: @escaping @Sendable (MacUIState) -> Bool) async throws -> MacUIState {
        try await panelOffPool {
            let deadline = Date().addingTimeInterval(10)
            var last = try self.runCommand(["ui", "state"]).state()
            while !done(last), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                last = try self.runCommand(["ui", "state"]).state()
            }
            return last
        }
    }

    func start() async throws { try await panelOffPool { try self.startAgent() } }

    /// Stops the agent and removes what it left; returns the problems found on the way.
    func close() async -> [String] { (try? await panelOffPool { self.closeAgent() }) ?? ["could not stop the panel agent"] }

    private func runCommand(_ arguments: [String]) throws -> PanelCommand {
        try panelRun(executable.path, arguments + ["--data-dir", directory.path, "--json"], in: directory)
    }

    private func startAgent() throws {
        let export = try panelRun("/usr/bin/defaults", ["export", Self.preferencesDomain, "-"], in: directory)
        savedPreferences = export.code == 0 ? export.output : nil
        let child = Process()
        child.executableURL = executable
        child.arguments = ["agent", "--data-dir", directory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CATFLAP_PLATFORM"] = "on"
        environment["CATFLAP_STATUS_ITEM"] = "on"
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, child.isRunning {
            if let state = try? runCommand(["ui", "state"]).state(), state.eventLoop, state.shortcut != "unavailable" { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw PanelTestError.startup
    }

    private func closeAgent() -> [String] {
        var problems: [String] = []
        if let child = process {
            process = nil
            if child.isRunning { child.terminate() }
            if panelWait(child, seconds: 7) == nil {
                FileHandle.standardError.write(Data("harness-error: panel agent failed to stop within 7 s\n".utf8))
                problems.append("Panel agent failed to stop within 7 s")
                kill(child.processIdentifier, SIGKILL); _ = panelWait(child, seconds: 5)
            }
            restorePreferences()
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            if let result = try? panelRun(executable.path, ["erase-identity", "--data-dir", directory.path], in: directory) {
                if result.code != 0 { problems.append("erase-identity exited \(result.code)") }
            } else { problems.append("Could not erase test identity") }
            try? FileManager.default.removeItem(at: directory)
        }
        return problems
    }

    private func restorePreferences() {
        if let saved = savedPreferences {
            let file = directory.appendingPathComponent("preferences.plist")
            if (try? saved.write(to: file)) != nil {
                _ = try? panelRun("/usr/bin/defaults", ["import", Self.preferencesDomain, file.path], in: directory)
            }
        } else {
            _ = try? panelRun("/usr/bin/defaults", ["delete", Self.preferencesDomain], in: directory)
        }
    }
}

@Suite(.serialized)
struct MacPanelE2E {
    private func withAgent(_ body: (PanelAgent) async throws -> Void) async throws {
        let agent = try PanelAgent()
        var failure: (any Error)?
        do {
            try await agent.start()
            try await body(agent)
        } catch { failure = error }
        for problem in await agent.close() { Issue.record(Comment(rawValue: problem)) }
        if let failure { throw failure }
    }

    private static func check(_ state: MacUIState, visible: Bool, mode: String, focus: Bool, _ step: String) {
        #expect(state.visible == visible, "\(step): visible")
        #expect(state.mode == mode, "\(step): mode")
        #expect(state.hasFocus == focus, "\(step): has_focus")
    }

    @Test func testToggleOpensFocusedAtTopCentreAndSecondToggleHides() async throws {
        let transparency = await MainActor.run { NSWorkspaceSettings.current }
        try await withAgent { agent in
            let (frontBefore, frontName) = await MainActor.run { () -> (pid_t?, String) in
                let front = NSWorkspace.shared.frontmostApplication
                return (front?.processIdentifier, front?.bundleIdentifier ?? "none")
            }
            print("MacPanelE2E frontmost app before toggle: \(frontName)")
            let first = try await agent.command(["toggle"])
            #expect(first.code == 0, "toggle: \(first.errorText)")
            Self.check(try first.state(), visible: true, mode: "focused", focus: true, "toggle")
            let shown = try await agent.state()
            Self.check(shown, visible: true, mode: "focused", focus: true, "ui state after toggle")
            print("MacPanelE2E focused: \(shown.summary)")
            #expect(shown.eventLoop)
            #expect(!shown.appFrontmost, "the panel takes the keyboard without bringing the app to the front")
            #expect(shown.activations == 0, "the app is never activated")
            let frontWhileFocused = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            #expect(frontWhileFocused == frontBefore, "the app in front stays in front")
            #expect(shown.activationPolicy == "accessory", "no Dock or app-switcher entry")
            #expect(shown.level == Int(CGWindowLevelForKey(.statusWindow)))
            #expect(shown.display != nil)
            #expect(shown.statusItem)
            #expect(shown.background == transparency.background)
            #expect(shown.motion == transparency.motion)
            if let frame = shown.frame, let display = shown.displayFrame, let below = shown.visibleFrame {
                #expect(abs((frame.x + frame.width / 2) - (display.x + display.width / 2)) <= 1, "top centre")
                #expect(abs((frame.y + frame.height) - (below.y + below.height - 8)) <= 1, "8 points below the menu bar")
                #expect(frame.width == 420)
            } else { Issue.record("a visible panel reports its frame and display") }

            let second = try await agent.command(["toggle"])
            #expect(second.code == 0)
            Self.check(try second.state(), visible: false, mode: "hidden", focus: false, "second toggle")
            let hidden = try await agent.state()
            Self.check(hidden, visible: false, mode: "hidden", focus: false, "ui state after second toggle")
            print("MacPanelE2E hidden: \(hidden.summary)")
            #expect(!hidden.appFrontmost)
            #expect(hidden.activations == 0)
            let frontAfter = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            #expect(frontAfter == frontBefore, "the keyboard is back with the app that was in front")
        }
    }

    @Test func testSimulatedHoverOpensWithoutFocusAndClosesAfterThePointerLeaves() async throws {
        try await withAgent { agent in
            let hover = try await agent.invoke("simulate-hover")
            Self.check(hover, visible: true, mode: "hover", focus: false, "simulate-hover")
            let state = try await agent.state()
            Self.check(state, visible: true, mode: "hover", focus: false, "ui state after simulate-hover")
            print("MacPanelE2E hover: \(state.summary)")
            #expect(try await agent.invoke("simulate-escape").mode == "hover", "Esc goes to the app in front")
            // Leaving starts the 300 ms grace; the panel is still there in the same moment.
            #expect(try await agent.invoke("simulate-leave").mode == "hover")
            let closed = try await agent.waitForState { $0.mode == "hidden" }
            Self.check(closed, visible: false, mode: "hidden", focus: false, "after the pointer left")

            _ = try await agent.invoke("simulate-hover")
            Self.check(try await agent.invoke("toggle"), visible: true, mode: "focused", focus: true, "hotkey on a hover panel")
            Self.check(try await agent.invoke("toggle"), visible: false, mode: "hidden", focus: false, "hotkey again")

            _ = try await agent.invoke("simulate-hover")
            Self.check(try await agent.invoke("simulate-click-inside"), visible: true, mode: "focused", focus: true, "click inside")
            _ = try await agent.invoke("hide")

            _ = try await agent.invoke("simulate-hover")
            Self.check(try await agent.invoke("simulate-click-outside"), visible: false, mode: "hidden", focus: false, "click outside a hover panel")
        }
    }

    @Test func testFocusedPanelClosesOnEscapeAndOnAClickOutside() async throws {
        try await withAgent { agent in
            _ = try await agent.command(["toggle"])
            _ = try await agent.invoke("simulate-leave")
            Self.check(try await agent.state(), visible: true, mode: "focused", focus: true, "focused panel when the pointer leaves")
            Self.check(try await agent.invoke("simulate-escape"), visible: false, mode: "hidden", focus: false, "Esc")
            _ = try await agent.command(["toggle"])
            Self.check(try await agent.invoke("simulate-click-outside"), visible: false, mode: "hidden", focus: false, "click outside")
        }
    }

    @Test func testDragOpensWithoutFocusAndClosesAfterTheDragLeaves() async throws {
        try await withAgent { agent in
            let drag = try await agent.invoke("simulate-drag")
            Self.check(drag, visible: true, mode: "drag", focus: false, "simulate-drag")
            print("MacPanelE2E drag: \(drag.summary)")
            #expect(try await agent.invoke("simulate-drag-leave").mode == "drag", "the drag has 500 ms to come back")
            let closed = try await agent.waitForState { $0.mode == "hidden" }
            Self.check(closed, visible: false, mode: "hidden", focus: false, "after the drag left")
        }
    }

    @Test func testShortcutIsBound() async throws {
        try await withAgent { agent in
            let state = try await agent.state()
            print("MacPanelE2E shortcut: \(state.shortcut) \(state.shortcutKeys)")
            #expect(state.shortcut == "bound")
            #expect(!state.shortcutKeys.isEmpty)
        }
    }

    @Test func testListsFollowTheAgentWhileThePanelIsOpen() async throws {
        try await withAgent { agent in
            let open = try await agent.command(["toggle"]).state()
            #expect(open.list == "clipboard")
            #expect(open.devices == 0)
            #expect(open.sendLabel == "Pair a device to send")
            let text = "panel list note " + UUID().uuidString
            let added = try await agent.command(["clip", "add", "--text", text])
            #expect(added.code == 0, "clip add: \(added.errorText)")
            let listed = try await agent.waitForState { $0.clipboardRows == 1 }
            #expect(listed.clipboardRows == 1, "a new clipboard row appears in the open panel")
            #expect(listed.rows == 1)
            print("MacPanelE2E live: \(listed.summary)")
        }
    }

    @Test func testBundleScriptSignsTheAppAdHoc() async throws {
        let executable = try locateExecutable()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = try scratchDirectory("cb-")
        defer { try? FileManager.default.removeItem(at: output) }
        let results = try await panelOffPool { () throws -> [PanelCommand] in
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "CATFLAP_SIGN_IDENTITY")
            let script = root.appendingPathComponent("packaging/macos/bundle.sh").path
            let bundle = try panelRun("/bin/bash", [script, "--binary", executable.path, "--output", output.path],
                                      environment: environment, in: output, seconds: 120)
            let app = output.appendingPathComponent("Catflap.app").path
            let verify = try panelRun("/usr/bin/codesign", ["--verify", "--strict", "--deep", app], in: output)
            let details = try panelRun("/usr/bin/codesign", ["-dv", app], in: output)
            return [bundle, verify, details]
        }
        let (bundle, verify, details) = (results[0], results[1], results[2])
        print("MacPanelE2E bundle: exit \(bundle.code)\n\(bundle.errorText)")
        #expect(bundle.code == 0, "bundle.sh: \(bundle.errorText)")
        let warnings = bundle.errorText.components(separatedBy: "\n").filter { $0.hasPrefix("warning: CATFLAP_SIGN_IDENTITY is not set") }
        #expect(warnings.count == 1, "one warning for the ad hoc signature")
        #expect(verify.code == 0, "codesign --verify: \(verify.errorText)")
        #expect(details.errorText.contains("Signature=adhoc"))
        #expect(details.errorText.contains("Identifier=io.github.yigityazicilar.Catflap"))
        let plist = output.appendingPathComponent("Catflap.app/Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        #expect(info?["LSUIElement"] as? Bool == true, "no Dock entry")
        #expect(info?["CFBundleExecutable"] as? String == "catflap")
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("Catflap.app/Contents/Frameworks/libtailcat.dylib").path))
    }
}

/// The accessibility settings the test machine has, and what the panel must show for them.
private struct NSWorkspaceSettings {
    let background: String
    let motion: String
    static var current: NSWorkspaceSettings {
        let workspace = NSWorkspace.shared
        let opaque = workspace.accessibilityDisplayShouldReduceTransparency || workspace.accessibilityDisplayShouldIncreaseContrast
        return .init(background: opaque ? "opaque" : "material", motion: workspace.accessibilityDisplayShouldReduceMotion ? "fade" : "flap")
    }
}

private extension MacUIState {
    var summary: String {
        let frame = self.frame.map { "\($0.x),\($0.y) \($0.width)x\($0.height)" } ?? "none"
        return "visible=\(visible) mode=\(mode) has_focus=\(hasFocus) display=\(display ?? "none") frame=\(frame) level=\(level) app_active=\(appActive) app_frontmost=\(appFrontmost) activations=\(activations) background=\(background) motion=\(motion) shortcut=\(shortcut)"
    }
}
#endif
