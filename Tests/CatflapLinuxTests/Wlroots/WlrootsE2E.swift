import CatflapCore
import Foundation
import Glibc
import XCTest

private enum WlrootsError: Error { case failed(String) }

/// The opt-in rig has no host sockets or home mounted. Each test still owns its display and bus.
private final class SwaySession {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sway-" + UUID().uuidString.prefix(8))
    let executable: URL
    var environment = ProcessInfo.processInfo.environment
    var children: [(Process, Bool)] = []
    var agentLog: URL?
    var logs: [Int32: URL] = [:]
    var proxyLog: URL?
    var controlLog: URL?
    var lastCommandFailure: String?
    var data: URL { root.appendingPathComponent("data") }

    init() throws {
        guard environment["CATFLAP_WLROOTS_TESTS"] == "1" else {
            throw XCTSkip("Set CATFLAP_WLROOTS_TESTS=1 inside ci/wlroots rig; never uses a login display")
        }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("catflap")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { found = candidate; break }
            directory.deleteLastPathComponent()
        }
        guard let found else { throw WlrootsError.failed("catflap executable missing") }
        executable = found
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for key in ["WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "SWAYSOCK", "AT_SPI_BUS_ADDRESS", "XDG_ACTIVATION_TOKEN"] { environment[key] = nil }
        for (key, subdirectory) in [("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "share"), ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state")] {
            let path = root.appendingPathComponent(subdirectory)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            environment[key] = path.path
        }
        environment["XDG_RUNTIME_DIR"] = root.path
        environment["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + root.appendingPathComponent("bus").path
        environment["CATFLAP_PLATFORM"] = "on"
        environment["GDK_BACKEND"] = "wayland"
        environment["GSK_RENDERER"] = "cairo"
        environment["GTK_A11Y"] = "none"
        environment["WLR_BACKENDS"] = "headless"
        environment["WLR_LIBINPUT_NO_DEVICES"] = "1"
        environment["WLR_RENDERER"] = "pixman"
        environment["XDG_CURRENT_DESKTOP"] = "sway"
        environment["XDG_SESSION_TYPE"] = "wayland"
    }

    deinit {
        for (child, agent) in children.reversed() {
            if child.isRunning {
                child.terminate()
                if !wait(child, 7) { XCTFail("isolated helper failed to stop"); kill(child.processIdentifier, SIGKILL); _ = wait(child, 5) }
                if agent { XCTAssertEqual(child.terminationStatus, 0) }
            } else if agent { XCTAssertEqual(child.terminationStatus, 0, "agent ended unexpectedly") }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func wait(_ child: Process, _ seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while child.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        return !child.isRunning
    }

    func eventually(_ predicate: () throws -> Bool) rethrows -> Bool {
        let end = Date().addingTimeInterval(15)
        repeat {
            if try predicate() { return true }
            Thread.sleep(forTimeInterval: 0.03)
        } while Date() < end
        return false
    }

    @discardableResult
    func launch(_ path: String, _ arguments: [String], agent: Bool = false, output: URL? = nil) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: path)
        child.arguments = arguments
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        let log = root.appendingPathComponent("log-" + UUID().uuidString)
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        child.standardError = try FileHandle(forWritingTo: log)
        if let output {
            _ = FileManager.default.createFile(atPath: output.path, contents: nil)
            child.standardOutput = try FileHandle(forWritingTo: output)
        } else { child.standardOutput = FileHandle.nullDevice }
        if agent { child.environment?["WAYLAND_DEBUG"] = "client"; agentLog = log }
        try child.run()
        children.append((child, agent))
        logs[child.processIdentifier] = log
        return child
    }

    func run(_ path: String, _ arguments: [String]) throws -> Data {
        let output = root.appendingPathComponent("output-" + UUID().uuidString)
        let child = try launch(path, arguments, output: output)
        guard wait(child, 15) else { throw WlrootsError.failed("command timed out") }
        guard child.terminationStatus == 0 else {
            let stderr = logs[child.processIdentifier].flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let stdout = String(decoding: (try? Data(contentsOf: output)) ?? Data(), as: UTF8.self)
            let diagnostic = "Command \(arguments), exit \(child.terminationStatus), reason \(child.terminationReason.rawValue)\nStderr\n" + stderr + "\nStdout\n" + stdout + "\nAgent stderr\n" + trace()
            lastCommandFailure = diagnostic
            throw WlrootsError.failed(diagnostic)
        }
        return try Data(contentsOf: output)
    }

    func command(_ arguments: [String]) throws -> Data {
        try run(executable.path, arguments + ["--data-dir", data.path, "--json"])
    }
    func object(_ arguments: [String]) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: command(arguments)) as? [String: Any] else {
            throw WlrootsError.failed("expected JSON object")
        }
        return result
    }
    func trace() -> String { agentLog.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "" }
    func items() throws -> [ClipboardItem] { try ControlJSON.decoder.decode([ClipboardItem].self, from: command(["clip", "list"])) }

    func markedSource() throws -> URL {
        let tree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = tree.appendingPathComponent("Sources/CDataControl")
        let program = root.appendingPathComponent("marked-source")
        _ = try run("/usr/bin/cc", [tree.appendingPathComponent("ci/wlroots/marked-source.c").path,
                                  sources.appendingPathComponent("wlr-data-control-unstable-v1-protocol.c").path,
                                  "-I" + sources.path, "-lwayland-client", "-o", program.path])
        let log = root.appendingPathComponent("marked-owner.log")
        let child = try launch(program.path, [log.path])
        guard eventually({ child.isRunning && ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("READY") }) else {
            let stderr = logs[child.processIdentifier].flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            throw WlrootsError.failed("marked source did not publish selection\n" + stderr)
        }
        return log
    }

    func controlFocus() throws {
        let source = root.appendingPathComponent("control.c")
        let program = root.appendingPathComponent("control")
        try """
        #include <gtk/gtk.h>
        #include <stdio.h>
        static void pressed(GtkGestureClick *g, int n, double x, double y, void *d) {
            (void)g; (void)n; (void)x; (void)y; (void)d;
            printf("GTK_CONTROL_BUTTON=1\\n"); fflush(stdout);
        }
        static void active(GObject *w, GParamSpec *p, void *d) {
            (void)p; (void)d;
            printf("GTK_CONTROL_FOCUS=%d\\n", gtk_window_is_active(GTK_WINDOW(w))); fflush(stdout);
        }
        int main(void) {
            gtk_init();
            GtkWidget *w = gtk_window_new();
            gtk_window_set_title(GTK_WINDOW(w), "wlroots-focus-control");
            g_signal_connect(w, "notify::is-active", G_CALLBACK(active), NULL);
            GtkGesture *click = gtk_gesture_click_new();
            gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(click), GTK_PHASE_CAPTURE);
            g_signal_connect(click, "pressed", G_CALLBACK(pressed), NULL);
            gtk_widget_add_controller(w, GTK_EVENT_CONTROLLER(click));
            gtk_window_present(GTK_WINDOW(w));
            g_main_loop_run(g_main_loop_new(NULL, FALSE));
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let flags = String(decoding: try run("/usr/bin/pkg-config", ["--cflags", "--libs", "gtk4"]), as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        _ = try run("/usr/bin/cc", [source.path, "-o", program.path] + flags)
        let output = root.appendingPathComponent("control-focus")
        controlLog = output
        try launch(program.path, [], output: output)
        let focused = eventually { ((try? String(contentsOf: output, encoding: .utf8)) ?? "").contains("GTK_CONTROL_FOCUS=1") }
        var diagnostic = ""
        if !focused { diagnostic = try focusDiagnostics() }
        XCTAssertTrue(focused, "ordinary GTK control must focus before the panel\n" + diagnostic)
        guard focused else { throw WlrootsError.failed("rig cannot focus ordinary GTK window\n" + diagnostic) }
    }

    func pointerDevice() throws {
        let tree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let program = root.appendingPathComponent("input-device")
        _ = try run("/usr/bin/cc", [tree.appendingPathComponent("ci/wlroots/input-device.c").path, "-lwayland-client", "-o", program.path])
        let log = root.appendingPathComponent("pointer-ready")
        let child = try launch(program.path, [], output: log)
        guard eventually({ child.isRunning && ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("POINTER_READY") }) else { throw WlrootsError.failed("virtual pointer device not ready") }
    }

    func foreignProbe() throws -> URL {
        let tree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = tree.appendingPathComponent("Sources/CDataControl")
        let program = root.appendingPathComponent("foreign-probe")
        _ = try run("/usr/bin/cc", [tree.appendingPathComponent("ci/wlroots/foreign-probe.c").path,
                                  sources.appendingPathComponent("wlr-foreign-toplevel-management-unstable-v1-protocol.c").path,
                                  "-I" + sources.path, "-lwayland-client", "-o", program.path])
        let log = root.appendingPathComponent("foreign.log")
        let child = try launch(program.path, [], output: log)
        guard eventually({ child.isRunning && ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("READY") }) else { throw WlrootsError.failed("foreign toplevel listener not ready") }
        return log
    }

    func outsideClickEvidence(_ log: URL) throws -> (controlID: Int, diagnostic: String) {
        let before = try String(contentsOf: log, encoding: .utf8)
        let placement = try object(["ui", "invoke", "describe"])["placement"] as? [String: Any]
        func control(_ node: [String: Any]) -> [String: Any]? {
            if node["name"] as? String == "wlroots-focus-control" { return node }
            for child in (node["nodes"] as? [[String: Any]] ?? []) + (node["floating_nodes"] as? [[String: Any]] ?? []) {
                if let found = control(child) { return found }
            }
            return nil
        }
        let tree = try XCTUnwrap(JSONSerialization.jsonObject(with: run("/usr/bin/swaymsg", ["-t", "get_tree", "-r"])) as? [String: Any])
        let node = try XCTUnwrap(control(tree))
        let rect = try XCTUnwrap(node["rect"] as? [String: Int])
        let x = try XCTUnwrap(rect["x"]) + 50
        let y = try XCTUnwrap(rect["y"]) + XCTUnwrap(rect["height"]) - 50
        _ = try run("/usr/bin/swaymsg", ["seat", "seat0", "cursor", "set", String(x), String(y)])
        _ = try run("/usr/bin/swaymsg", ["seat", "seat0", "cursor", "press", "button1"])
        _ = try run("/usr/bin/swaymsg", ["seat", "seat0", "cursor", "release", "button1"])
        let pressed = eventually { controlLog.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("GTK_CONTROL_BUTTON=1") == true }
        let activated = eventually {
            let current = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return current.dropFirst(before.count).contains("STATE title=wlroots-focus-control activated=1")
        }
        let after = String(try String(contentsOf: log, encoding: .utf8).dropFirst(before.count))
        let seats = String(decoding: try run("/usr/bin/swaymsg", ["-t", "get_seats", "-r"]), as: UTF8.self)
        let panel = String(decoding: try command(["ui", "state"]), as: UTF8.self)
        let diagnostic = "Keyboard before click: \(placement?["keyboard"] ?? "missing")\nControl: \(node["id"] ?? "missing"), rect \(rect), click \(x),\(y)\nButton received: \(pressed), foreign activated: \(activated)\nForeign before\n" + before + "\nForeign after\n" + after + "\nSeat after\n" + seats + "\nPanel after\n" + panel
        XCTAssertEqual(placement?["keyboard"] as? String, "exclusive", diagnostic)
        XCTAssertTrue(pressed, diagnostic)
        XCTAssertTrue(activated, diagnostic)
        return (try XCTUnwrap(node["id"] as? Int), diagnostic)
    }

    func focusDiagnostics() throws -> String {
        let protocolLines = trace().components(separatedBy: .newlines).filter { $0.contains("get_layer_surface") || $0.contains("set_keyboard_interactivity") || $0.contains(".commit()") }.joined(separator: "\n")
        let seats = String(decoding: try run("/usr/bin/swaymsg", ["-t", "get_seats", "-r"]), as: UTF8.self)
        let tree = String(decoding: try run("/usr/bin/swaymsg", ["-t", "get_tree", "-r"]), as: UTF8.self)
        return "Layer-shell protocol\n" + protocolLines + "\nSeats\n" + seats + "\nTree\n" + tree
    }

    func start(splitDelivery: Bool = false) throws {
        try launch("/usr/bin/dbus-daemon", ["--session", "--nofork", "--address=" + environment["DBUS_SESSION_BUS_ADDRESS"]!])
        guard eventually({ FileManager.default.fileExists(atPath: root.appendingPathComponent("bus").path) }) else { throw WlrootsError.failed("private bus missing") }
        // An argv wrapper supplies only the fixture data directory, not a replacement toggle action.
        let toggle = root.appendingPathComponent("toggle")
        try "#!/bin/sh\nexec '\(executable.path)' toggle --data-dir '\(data.path)'\n".write(to: toggle, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: toggle.path)
        let config = root.appendingPathComponent("sway.conf")
        try "output HEADLESS-1 mode 1280x800\nseat seat0 fallback true\nxwayland disable\nbindsym Ctrl+Mod1+space exec '\(toggle.path)'\n".write(to: config, atomically: true, encoding: .utf8)
        try launch("/usr/bin/sway", ["--unsupported-gpu", "-c", config.path])
        guard eventually({
            let sockets = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            if let socket = sockets.first(where: { $0.hasPrefix("wayland-") && !$0.hasSuffix(".lock") }) { environment["WAYLAND_DISPLAY"] = socket; return true }
            return false
        }) else { throw WlrootsError.failed("private sway socket missing") }
        if let ipc = try FileManager.default.contentsOfDirectory(atPath: root.path).first(where: { $0.hasPrefix("sway-ipc.") }) {
            environment["SWAYSOCK"] = root.appendingPathComponent(ipc).path
        }
        // Sway must retain an input device after an injection command exits, or the
        // seat loses keyboard capability and GTK correctly reports no keyboard focus.
        try launch("/usr/bin/wtype", ["-s", "600000"])
        if splitDelivery {
            let tree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let endpoint = root.appendingPathComponent("split")
            let log = root.appendingPathComponent("split.log")
            let upstream = root.appendingPathComponent(environment["WAYLAND_DISPLAY"]!).path
            try launch("/usr/bin/python3", [tree.appendingPathComponent("ci/wlroots/split-proxy.py").path, upstream, endpoint.path, log.path])
            guard eventually({ FileManager.default.fileExists(atPath: endpoint.path) }) else { throw WlrootsError.failed("split proxy socket missing") }
            proxyLog = log
            environment["WAYLAND_DISPLAY"] = endpoint.path
        }
        try launch(executable.path, ["agent", "--data-dir", data.path], agent: true)
        guard eventually({ (try? object(["ui", "state"])["mode"] as? String) != nil }) else { throw WlrootsError.failed("panel did not register\n" + (lastCommandFailure ?? trace())) }
    }
}

final class WlrootsE2E: XCTestCase {
    func testWlrSplitDeliveryKeepsIntroducedOffersAndMarkerUnread() throws {
        let session = try SwaySession(); try session.start(splitDelivery: true)
        XCTAssertTrue(try session.eventually { try session.object(["status"])["clipboard_capture"] as? String == "active" })
        let first = "first split sway clipboard copy " + UUID().uuidString
        try session.launch("/usr/bin/wl-copy", ["--foreground", first])
        XCTAssertTrue(try session.eventually { try session.items().contains { $0.text == first } })
        let ownerLog = try session.markedSource()
        XCTAssertTrue(session.eventually { session.trace().contains(".offer(\"x-kde-passwordManagerHint\"") })
        let last = "last split sway clipboard copy " + UUID().uuidString
        try session.launch("/usr/bin/wl-copy", ["--foreground", last])
        XCTAssertTrue(try session.eventually { try session.items().contains { $0.text == last } })
        XCTAssertEqual(try session.items().map(\.text), [last, first])
        XCTAssertTrue(session.eventually { ((try? String(contentsOf: ownerLog, encoding: .utf8)) ?? "").contains("CANCELLED") })
        XCTAssertFalse(try String(contentsOf: ownerLog, encoding: .utf8).contains("PAYLOAD_REQUEST"))
        let proxy = try String(contentsOf: XCTUnwrap(session.proxyLog), encoding: .utf8)
        for event in ["split data_offer", "split MIME offer", "split selection"] { XCTAssertTrue(proxy.contains(event), proxy) }
        XCTAssertFalse(proxy.contains("PROXY_ERROR"), proxy)
        XCTAssertFalse(session.trace().contains("unknown object"))
    }

    func testWlrCopyCaptured() throws {
        let session = try SwaySession(); try session.start()
        XCTAssertTrue(try session.eventually { try session.object(["status"])["clipboard_capture"] as? String == "active" })
        let text = "ordinary sway clipboard copy " + UUID().uuidString
        try session.launch("/usr/bin/wl-copy", ["--foreground", text])
        XCTAssertTrue(try session.eventually { try session.items().contains { $0.text == text } })
        XCTAssertTrue(session.trace().contains("bind("))
        XCTAssertTrue(session.trace().contains("zwlr_data_control_manager_v1\""))
        XCTAssertFalse(session.trace().contains("\"ext_data_control_manager_v1\""), "mandatory Ubuntu rig must exercise wlr-only")
    }

    func testWlrMarkedCopyHasZeroPayloadRequests() throws {
        let session = try SwaySession(); try session.start()
        XCTAssertTrue(try session.eventually { try session.object(["status"])["clipboard_capture"] as? String == "active" })
        let ownerLog = try session.markedSource()
        XCTAssertTrue(session.eventually { session.trace().contains(".offer(\"x-kde-passwordManagerHint\"") })
        let trace = session.trace()
        let marker = try XCTUnwrap(trace.components(separatedBy: .newlines).first { $0.contains(".offer(\"x-kde-passwordManagerHint\"") })
        let expression = try NSRegularExpression(pattern: "zwlr_data_control_offer_v1[@#][0-9]+")
        let match = try XCTUnwrap(expression.firstMatch(in: marker, range: NSRange(marker.startIndex..., in: marker)))
        let range = try XCTUnwrap(Range(match.range, in: marker))
        let offer = String(marker[range])
        let after = "sway copy after marked barrier " + UUID().uuidString
        try session.launch("/usr/bin/wl-copy", ["--foreground", after])
        XCTAssertTrue(try session.eventually { try session.items().contains { $0.text == after } })
        XCTAssertEqual(try session.items().map(\.text), [after])
        let start = try XCTUnwrap(session.trace().range(of: marker)).upperBound
        let lifetime = session.trace()[start...].components(separatedBy: offer + ".destroy()").first ?? ""
        XCTAssertFalse(lifetime.contains(offer + ".receive("))
        XCTAssertTrue(session.eventually { ((try? String(contentsOf: ownerLog, encoding: .utf8)) ?? "").contains("CANCELLED") })
        XCTAssertFalse(try String(contentsOf: ownerLog, encoding: .utf8).contains("PAYLOAD_REQUEST"))
    }

    func testPanelMapsFocusedThroughLayerShellAndBindingToggles() throws {
        let session = try SwaySession(); try session.start()
        XCTAssertTrue(try session.eventually { try session.object(["ui", "state"])["shortcut"] as? String == "unavailable" })
        try session.pointerDevice()
        try session.controlFocus()
        let foreignLog = try session.foreignProbe()
        let chord = ["-M", "ctrl", "-M", "alt", "-k", "space", "-m", "alt", "-m", "ctrl"]
        _ = try session.run("/usr/bin/wtype", chord)
        let focused = try session.eventually { try session.object(["ui", "state"])["has_focus"] as? Bool == true }
        var initialDiagnostic = ""
        if !focused { initialDiagnostic = try session.focusDiagnostics() }
        XCTAssertTrue(focused, initialDiagnostic)
        // Exercise the live seat past the old handover, not just its transient focus.
        let beforeKeyboard = session.trace()
        _ = try session.run("/usr/bin/wtype", ["-s", "3000"])
        let afterKeyboard = session.trace()
        let retainedFocus = try session.object(["ui", "state"])["has_focus"] as? Bool == true
        var keyboardDiagnostic = ""
        if !retainedFocus {
            let map = beforeKeyboard.components(separatedBy: .newlines).last { $0.contains("get_layer_surface") && $0.contains("catflap-panel") } ?? "panel map missing"
            let beforeEvents = beforeKeyboard.components(separatedBy: .newlines).filter { $0.contains("wl_keyboard@") && ($0.contains(".enter(") || $0.contains(".leave(")) }.suffix(4).joined(separator: "\n")
            let duringEvents = afterKeyboard.dropFirst(beforeKeyboard.count).components(separatedBy: .newlines).filter { $0.contains("wl_keyboard@") && ($0.contains(".enter(") || $0.contains(".leave(")) }.joined(separator: "\n")
            keyboardDiagnostic = "Panel surface\n" + map + "\nKeyboard before\n" + beforeEvents + "\nKeyboard recreation\n" + duringEvents
        }
        XCTAssertTrue(retainedFocus, "keyboard recreation must not close a focused panel\n" + keyboardDiagnostic)
        let description = try session.object(["ui", "invoke", "describe"])
        let placement = try XCTUnwrap(description["placement"] as? [String: Any])
        XCTAssertEqual(placement["layer"] as? String, "overlay")
        XCTAssertEqual(placement["keyboard"] as? String, "exclusive")
        XCTAssertEqual(placement["outside_click"] as? String, "foreign-toplevel")
        XCTAssertTrue(session.trace().contains(".get_layer_surface("))
        let clickEvidence = try session.outsideClickEvidence(foreignLog)
        let outsideClosed = try session.eventually { try session.object(["ui", "state"])["visible"] as? Bool == false }
        var outsideDiagnostic = clickEvidence.diagnostic
        if !outsideClosed {
            let latest = try session.focusDiagnostics()
            outsideDiagnostic += "\n" + latest
        }
        XCTAssertTrue(outsideClosed, outsideDiagnostic)
        let seats = try XCTUnwrap(JSONSerialization.jsonObject(with: session.run("/usr/bin/swaymsg", ["-t", "get_seats", "-r"])) as? [[String: Any]])
        XCTAssertEqual(seats.first?["focus"] as? Int, clickEvidence.controlID, outsideDiagnostic)
        _ = try session.run("/usr/bin/wtype", chord)
        XCTAssertTrue(try session.eventually { try session.object(["ui", "state"])["has_focus"] as? Bool == true })
        let shown = try ControlClient.request(ControlRequest("panel.show"), socket: session.data.appendingPathComponent("control.sock"))
        XCTAssertTrue(shown.ok)
        XCTAssertEqual(try session.object(["ui", "state"])["visible"] as? Bool, true)
        _ = try session.run("/usr/bin/wtype", ["-k", "Escape"])
        XCTAssertTrue(try session.eventually { try session.object(["ui", "state"])["visible"] as? Bool == false })
        _ = try session.command(["toggle"])
        XCTAssertTrue(try session.eventually { try session.object(["ui", "state"])["has_focus"] as? Bool == true })
        _ = try session.command(["toggle"])
        XCTAssertEqual(try session.object(["ui", "state"])["visible"] as? Bool, false)
    }
}
