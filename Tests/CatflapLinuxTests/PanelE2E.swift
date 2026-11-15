import CatflapCore
import Foundation
import Glibc
import XCTest

private enum PanelTestError: Error { case missingExecutable, timedOut(String), commandFailed(String), startupFailed(String) }

/// What `ui state --json` reports.
private struct State: Decodable, Equatable {
    let visible: Bool
    let mode: String
    let hasFocus: Bool
    let display: String?
    let shortcut: String
    enum CodingKeys: String, CodingKey { case visible, mode, display, shortcut, hasFocus = "has_focus" }
}

/// The parts of `ui invoke describe` these tests read.
private struct Description: Decodable {
    let mode: String
    let placement: Placement
    let bands: [String]
    let reducedMotion: Bool
    let highContrast: Bool
    let opaque: Bool
    let motion: String
    let rows: [String]
    let selectedRow: Int?
    let field: String
    let sendLabel: String
    let lastReturn: String?
    let shortcut: String
    let shortcutTrigger: String?
    let sendClipboardShortcut: String
    let shortcutSetup: String?
    let focusLostTo: String?
    struct Placement: Decodable {
        let layer: String
        let anchor: String
        let keyboard: String
        let exclusiveZone: Int
        enum CodingKeys: String, CodingKey { case layer, anchor, keyboard, exclusiveZone = "exclusive_zone" }
    }
    enum CodingKeys: String, CodingKey {
        case mode, placement, bands, opaque, motion, rows, field
        case reducedMotion = "reduced_motion", highContrast = "high_contrast", selectedRow = "selected_row"
        case sendLabel = "send_label", lastReturn = "last_return", shortcutTrigger = "shortcut_trigger", shortcut
        case sendClipboardShortcut = "send_clipboard_shortcut", shortcutSetup = "shortcut_setup", focusLostTo = "focus_lost_to"
    }
}

/// A window as KWin itself places it.
private struct Placed: Decodable {
    let caption: String
    let cls: String
    let x: Int, y: Int, w: Int, h: Int
    let layer: Int
    let output: String?
}

/// A nested `kwin_wayland --virtual` with its own runtime directory, its own session bus (with
/// the desktop portal, kglobalaccel inside KWin, and AT-SPI), an ordinary application window
/// and a fake input device. Nothing reaches the person's own session.
private final class PanelSession {
    static let socket = "panel-test"
    static let width = 1280, height = 800
    let root: URL
    let executable: URL
    let data: URL
    var environment: [String: String]
    private var children: [(process: Process, agent: Bool, group: Bool)] = []
    private var groupLeader: Int32 = 0
    private(set) var agentLog: URL?
    private var kwinLog: URL?
    private var fakeInput: URL?
    /// The portal's front end while `holdPortal()` keeps it stopped.
    private var heldPortal: Int32 = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pn-" + UUID().uuidString.prefix(8))
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
            throw PanelTestError.missingExecutable
        }
        executable = path
        environment = ProcessInfo.processInfo.environment
        for name in ["WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "XDG_SESSION_TYPE",
                     "XDG_ACTIVATION_TOKEN", "DESKTOP_STARTUP_ID", "AT_SPI_BUS_ADDRESS"] {
            environment[name] = nil
        }
        environment["CATFLAP_PLATFORM"] = "on"
        environment["HOME"] = root.appendingPathComponent("home").path
        environment["XDG_RUNTIME_DIR"] = root.path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_DATA_HOME"] = root.appendingPathComponent("share").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        environment["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        environment["XDG_CURRENT_DESKTOP"] = "KDE"
        environment["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + root.appendingPathComponent("bus").path
        // No crash dialog for a nested compositor: it would appear in the person's session.
        environment["KDE_DEBUG"] = "1"
        environment["LIBGL_ALWAYS_SOFTWARE"] = "1"
        for name in ["home", "config", "share/applications"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        // The portal gives a host application an ID only if a desktop file names it.
        try "[Desktop Entry]\nType=Application\nName=Catflap\nExec=\(executable.path) agent\nNoDisplay=true\n"
            .write(to: root.appendingPathComponent("share/applications/io.github.yigityazicilar.Catflap.desktop"), atomically: true, encoding: .utf8)
    }

    deinit {
        if heldPortal > 0 { kill(heldPortal, SIGCONT) }
        for child in children.reversed() { stop(child.process, agent: child.agent, group: child.group) }
        // Nothing may stay behind: the document portal's FUSE mount ends with the bus group.
        let mounts = (try? String(contentsOfFile: "/proc/self/mounts", encoding: .utf8)) ?? ""
        XCTAssertFalse(mounts.contains(root.path), "a mount is left under the test directory")
        try? FileManager.default.removeItem(at: root)
    }

    private func stop(_ child: Process, agent: Bool, group: Bool) {
        let pid = child.processIdentifier
        if group {
            // The bus leads its own session, so its group also holds the services it started
            // on demand (the portal and its backends, AT-SPI). SIGTERM first: the document
            // portal unmounts its FUSE directory on the way out.
            let leader = groupLeader
            guard leader > 0 else { child.terminate(); _ = wait(child, seconds: 5); return }
            kill(-leader, SIGTERM)
            let end = Date().addingTimeInterval(5)
            while kill(-leader, 0) == 0 && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
            if kill(-leader, 0) == 0 { kill(-leader, SIGKILL) }
            XCTAssertTrue(wait(child, seconds: 5))
            return
        }
        guard child.isRunning else { return }
        child.terminate()
        if !wait(child, seconds: agent ? 7 : 5) {
            XCTFail(agent ? "Agent did not stop within 7 s of SIGTERM" : "Helper \(child.executableURL?.lastPathComponent ?? "") did not stop")
            kill(pid, SIGKILL)
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
    func launch(_ path: String, _ arguments: [String], agent: Bool = false, group: Bool = false,
                extra: [String: String] = [:], log name: String? = nil) throws -> Process {
        let child = Process()
        // `setsid -w` gives the program a session of its own and stays as its parent, so the
        // test runner still sees every process the program starts.
        child.executableURL = URL(fileURLWithPath: group ? "/usr/bin/setsid" : path)
        child.arguments = group ? ["-w", path] + arguments : arguments
        child.environment = environment.merging(extra) { $1 }
        let pidFile = root.appendingPathComponent("pid-" + UUID().uuidString)
        if group {
            _ = FileManager.default.createFile(atPath: pidFile.path, contents: nil)
            child.standardOutput = try FileHandle(forWritingTo: pidFile)
        } else {
            child.standardOutput = FileHandle.nullDevice
        }
        child.standardInput = FileHandle.nullDevice
        let log = root.appendingPathComponent("log-" + (name ?? UUID().uuidString))
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        child.standardError = try FileHandle(forWritingTo: log)
        try child.run()
        children.append((child, agent, group))
        if agent { agentLog = log }
        if name == "kwin" { kwinLog = log }
        if group {
            // The program prints its own pid, which is also its session's process group.
            _ = eventually(5) {
                groupLeader = Int32(String(decoding: (try? Data(contentsOf: pidFile)) ?? Data(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                return groupLeader > 0
            }
        }
        return child
    }

    /// Runs a short command to completion and returns its standard output.
    @discardableResult
    func run(_ path: String, _ arguments: [String], seconds: TimeInterval = 10) throws -> Data {
        let output = root.appendingPathComponent("output-" + UUID().uuidString)
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: path)
        child.arguments = arguments
        child.environment = environment
        child.standardOutput = try FileHandle(forWritingTo: output)
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        try child.run()
        if !wait(child, seconds: seconds) {
            kill(child.processIdentifier, SIGKILL)
            _ = wait(child, seconds: 5)
            throw PanelTestError.timedOut(([path] + arguments).joined(separator: " "))
        }
        guard child.terminationStatus == 0 else { throw PanelTestError.commandFailed(([path] + arguments).joined(separator: " ")) }
        return try Data(contentsOf: output)
    }

    func catflap(_ arguments: [String]) throws -> Data {
        try run(executable.path, arguments + ["--data-dir", data.path, "--json"])
    }

    func state() throws -> State { try ControlJSON.decoder.decode(State.self, from: catflap(["ui", "state"])) }
    func describe() throws -> Description { try ControlJSON.decoder.decode(Description.self, from: catflap(["ui", "invoke", "describe"])) }
    func invoke(_ action: String) throws -> State { try ControlJSON.decoder.decode(State.self, from: catflap(["ui", "invoke", action])) }
    func toggle() throws -> State { try ControlJSON.decoder.decode(State.self, from: catflap(["toggle"])) }

    /// `panel.show`, sent on the control socket as a second launch of the app sends it.
    func show() throws -> State {
        let response = try ControlClient.request(ControlRequest("panel.show"), socket: data.appendingPathComponent("control.sock"))
        guard response.ok else { throw PanelTestError.commandFailed("panel.show: " + (response.error ?? "no error text")) }
        return try response.decode(State.self)
    }

    /// Polls `condition` until it holds or `seconds` pass. Waiting on the event, not a sleep.
    func eventually(_ seconds: TimeInterval = 5, _ condition: () throws -> Bool) rethrows -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.03)
        } while Date() < end
        return false
    }

    func start(topPanel: Bool = true, agentEnvironment: [String: String] = [:], before: () throws -> Void = {}) throws {
        // CI=true is the explicit CI gate, as for the clipboard tests: the Linux runner has no
        // nested KWin, so only these desktop end-to-end tests skip there.
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/kwin_wayland") else {
            if ProcessInfo.processInfo.environment["CI"] == "true" {
                throw XCTSkip("CI=true: no nested KWin compositor installed")
            }
            XCTFail("Nested KWin is required; the live display is never used")
            throw PanelTestError.startupFailed("no kwin_wayland")
        }
        // Services the bus starts on demand inherit its environment: they show on the nested
        // display, so the portal's confirmation dialog can be answered there.
        try launch("/usr/bin/dbus-daemon", ["--session", "--nofork", "--print-pid", "--address=" + environment["DBUS_SESSION_BUS_ADDRESS"]!],
                   group: true, extra: ["WAYLAND_DISPLAY": Self.socket, "QT_QPA_PLATFORM": "wayland"], log: "bus")
        guard eventually(5, { FileManager.default.fileExists(atPath: root.appendingPathComponent("bus").path) }) else {
            throw PanelTestError.startupFailed("bus")
        }
        // KWin serves kglobalaccel itself, so global shortcuts stay on. Its script output
        // (window geometry) goes to its log.
        let kwin = try launch("/usr/bin/kwin_wayland",
                              ["--virtual", "--socket", Self.socket, "--no-lockscreen", "--no-kactivities",
                               "--width", String(Self.width), "--height", String(Self.height)],
                              extra: ["QT_QPA_PLATFORM": "offscreen", "KWIN_COMPOSE": "Q", "KWIN_WAYLAND_NO_PERMISSION_CHECKS": "1",
                                      "QT_FORCE_STDERR_LOGGING": "1", "QT_LOGGING_RULES": "kwin_scripting.debug=true"],
                              log: "kwin")
        guard eventually(10, { kwin.isRunning && FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.socket).path) }) else {
            throw PanelTestError.startupFailed("kwin")
        }
        environment["WAYLAND_DISPLAY"] = Self.socket
        try buildFakeInput()
        // AT-SPI, so the test can read the labels a screen reader gets.
        try launch("/usr/lib/at-spi-bus-launcher", ["--launch-immediately"])
        _ = eventually(5) { (try? run("/usr/bin/busctl", ["--user", "status", "org.a11y.Bus"], seconds: 3)) != nil }
        try launch("/usr/lib/at-spi2-registryd", [])
        try watchFocus()
        if topPanel { try launchWindows() }
        try before()
        let agent = try launch(executable.path, ["agent", "--data-dir", data.path], agent: true,
                               extra: agentEnvironment, log: "agent")
        // The control channel answers at once; the panel registers its commands when GTK is up.
        guard eventually(15, { agent.isRunning && (try? describe()) != nil }) else { throw PanelTestError.startupFailed("agent") }
    }

    /// A panel that reserves 40 px at the top, as a top panel does, and an ordinary window
    /// filling the rest, to click outside on.
    private func launchWindows() throws {
        let script = root.appendingPathComponent("windows.py")
        try """
        import gi
        gi.require_version("Gtk", "4.0"); gi.require_version("Gtk4LayerShell", "1.0")
        from gi.repository import Gtk, GLib, Gtk4LayerShell as L
        Gtk.init()
        top = Gtk.Window(); L.init_for_window(top); L.set_namespace(top, "test-top-panel"); L.set_layer(top, L.Layer.TOP)
        for edge in (L.Edge.TOP, L.Edge.LEFT, L.Edge.RIGHT): L.set_anchor(top, edge, True)
        L.set_exclusive_zone(top, 40); top.set_default_size(10, 40); top.set_child(Gtk.Label(label="top panel")); top.present()
        other = Gtk.Window(title="other application"); other.set_child(Gtk.Label(label="other application")); other.maximize(); other.present()
        GLib.MainLoop().run()
        """.write(to: script, atomically: true, encoding: .utf8)
        try launch("/usr/bin/python3", [script.path],
                   extra: ["LD_PRELOAD": "/usr/lib/libgtk4-layer-shell.so", "GSK_RENDERER": "cairo"])
        guard eventually(10, { (try? windows().contains { $0.caption == "other application" }) == true }) else {
            throw PanelTestError.startupFailed("windows")
        }
    }

    /// org_kde_kwin_fake_input (plasma-wayland-protocols), the requests used here, so the
    /// test drives a real pointer and keyboard in the nested session.
    private func buildFakeInput() throws {
        let source = root.appendingPathComponent("fakeinput.c")
        let program = root.appendingPathComponent("fakeinput")
        try """
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        #include <wayland-client.h>
        static const struct wl_interface *none[4];
        static const struct wl_message requests[] = {
            {"authenticate", "ss", none}, {"pointer_motion", "ff", none}, {"button", "uu", none}, {"axis", "uf", none},
            {"touch_down", "2uff", none}, {"touch_motion", "2uff", none}, {"touch_up", "2u", none}, {"touch_cancel", "2", none},
            {"touch_frame", "2", none}, {"pointer_motion_absolute", "3ff", none}, {"keyboard_key", "4uu", none},
        };
        static const struct wl_interface fake_interface = {"org_kde_kwin_fake_input", 4, 11, requests, 0, NULL};
        static struct wl_proxy *fake;
        static void global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t v) {
            if (!strcmp(iface, fake_interface.name)) fake = wl_registry_bind(r, name, &fake_interface, v < 4 ? v : 4);
        }
        static void removed(void *d, struct wl_registry *r, uint32_t name) {}
        static const struct wl_registry_listener listener = { global, removed };
        static void key(struct wl_display *d, uint32_t code, uint32_t state) {
            wl_proxy_marshal_flags(fake, 10, NULL, 4, 0, code, state); wl_display_roundtrip(d);
        }
        int main(int argc, char **argv) {
            struct wl_display *d = wl_display_connect(NULL);
            if (!d) return 2;
            struct wl_registry *registry = wl_display_get_registry(d);
            wl_registry_add_listener(registry, &listener, NULL);
            wl_display_roundtrip(d);
            if (!fake) return 3;
            wl_proxy_marshal_flags(fake, 0, NULL, 4, 0, "catflap test", "drive the nested test session");
            wl_display_roundtrip(d);
            usleep(150000);
            for (int i = 1; i < argc; i++) {
                const char *c = argv[i];
                if (!strcmp(c, "move") && i + 2 < argc) {
                    wl_fixed_t x = wl_fixed_from_int(atoi(argv[i + 1])), y = wl_fixed_from_int(atoi(argv[i + 2]));
                    i += 2;
                    wl_proxy_marshal_flags(fake, 9, NULL, 4, 0, x, y);
                } else if (!strcmp(c, "click")) {
                    wl_proxy_marshal_flags(fake, 2, NULL, 4, 0, 0x110, 1); wl_display_roundtrip(d);
                    wl_proxy_marshal_flags(fake, 2, NULL, 4, 0, 0x110, 0);
                } else if (!strcmp(c, "key") && i + 1 < argc) {
                    uint32_t code = atoi(argv[++i]); key(d, code, 1); key(d, code, 0);
                } else if (!strcmp(c, "down") && i + 1 < argc) { key(d, atoi(argv[++i]), 1);
                } else if (!strcmp(c, "up") && i + 1 < argc) { key(d, atoi(argv[++i]), 0);
                } else if (!strcmp(c, "wait") && i + 1 < argc) { wl_display_roundtrip(d); usleep(atoi(argv[++i]) * 1000); }
                wl_display_roundtrip(d);
            }
            wl_display_disconnect(d);
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        try run("/usr/bin/cc", [source.path, "-lwayland-client", "-o", program.path], seconds: 30)
        fakeInput = program
    }

    /// Pointer and keyboard commands for the fake device: `move X Y`, `click`, `key CODE`,
    /// `down CODE`, `up CODE`, `wait MS`. Each run adds a device, after which the first motion
    /// can arrive before the clients have bound the new pointer, so moves are sent twice.
    func input(_ commands: String...) throws { try input(commands) }

    func input(_ commands: [String]) throws {
        guard let fakeInput else { throw PanelTestError.startupFailed("fake input") }
        var arguments: [String] = []
        for command in commands {
            let parts = command.split(separator: " ").map(String.init)
            arguments += parts
            if parts.first == "move" { arguments += ["wait", "60"] + parts }
        }
        try run(fakeInput.path, arguments)
    }

    /// Moves the pointer to the top-edge band of the display and keeps it there.
    func pointAtBand() throws { try input("move 640 40") }

    /// The windows KWin shows, with the geometry it gave them.
    func windows() throws -> [Placed] {
        guard let kwinLog else { return [] }
        let marker = "T" + UUID().uuidString.prefix(8)
        let script = root.appendingPathComponent("list-\(marker).js")
        try """
        for (const w of workspace.stackingOrder) { const g = w.frameGeometry;
          print("\(marker) " + JSON.stringify({caption: w.caption, cls: w.resourceClass, x: g.x, y: g.y, w: g.width, h: g.height,
            layer: w.layer, output: w.output ? w.output.name : null})); }
        """.write(to: script, atomically: true, encoding: .utf8)
        try run("/usr/bin/busctl", ["--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "loadScript", "ss", script.path, marker])
        try run("/usr/bin/busctl", ["--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "start"])
        var lines: [Substring] = []
        _ = eventually(3) {
            let log = (try? String(contentsOf: kwinLog, encoding: .utf8)) ?? ""
            lines = log.split(separator: "\n").filter { $0.contains(marker + " ") }
            return !lines.isEmpty
        }
        try run("/usr/bin/busctl", ["--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "unloadScript", "s", marker])
        return lines.compactMap { line in
            guard let range = line.range(of: marker + " ") else { return nil }
            return try? JSONDecoder().decode(Placed.self, from: Data(line[range.upperBound...].utf8))
        }
    }

    /// The panel as KWin placed it: the catflap surface taller than the band.
    func panelWindow() throws -> Placed? {
        try windows().last { $0.cls == "catflap" && $0.h > 100 }
    }

    /// Answers the system's question about each of the agent's two shortcuts with Return, as
    /// the person would: first the panel's, then the send-clipboard one, which the agent asks
    /// for only once the first is settled. Returns when the agent reports both settled and the
    /// last question has closed.
    func confirmShortcut() throws {
        for (number, request) in [(1, \Description.shortcut), (2, \Description.sendClipboardShortcut)] {
            // The question is up and has the keyboard, or the system settled it without asking.
            guard try eventually(30, { try describe()[keyPath: request] != "pending" || questionUp(number) }) else {
                throw PanelTestError.timedOut("portal question \(number)")
            }
            if try describe()[keyPath: request] == "pending" { try input("key 28") }
            guard try eventually(10, { try describe()[keyPath: request] != "pending" }) else {
                throw PanelTestError.timedOut("shortcut \(number) settled")
            }
        }
        guard try eventually(10, { try describe().shortcutSetup == "settled" && !questionOpen() }) else {
            throw PanelTestError.timedOut("portal questions closed")
        }
    }

    // MARK: Focus as KWin sees it

    /// From the start of the session, KWin logs every window it adds, removes and activates,
    /// in order. Catflap's windows are `catflap` (only the panel ever takes the keyboard, so an
    /// activated one is `panel`), the portal's "Global Shortcuts Requested" is `question`, any
    /// other window `other`, and no active window `none`.
    private func watchFocus() throws {
        let script = root.appendingPathComponent("focus.js")
        try """
        function name(w, activated) {
          if (!w) return "none";
          if (w.resourceClass == "catflap") return activated ? "panel" : "catflap";
          return w.caption == "Global Shortcuts Requested" ? "question" : "other";
        }
        workspace.windowActivated.connect(function (w) { print("FOCUS activated " + name(w, true)); });
        workspace.windowAdded.connect(function (w) { print("FOCUS added " + name(w, false)); });
        workspace.windowRemoved.connect(function (w) { print("FOCUS removed " + name(w, false)); });
        """.write(to: script, atomically: true, encoding: .utf8)
        // KWin's scripting interface can join the bus a moment after its display socket appears.
        guard eventually(10, { (try? run("/usr/bin/busctl", ["--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting",
                                                          "loadScript", "ss", script.path, "focus"])) != nil }) else {
            throw PanelTestError.startupFailed("focus log")
        }
        try run("/usr/bin/busctl", ["--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "start"])
    }

    /// KWin's focus log so far, oldest first: `activated panel`, `added question`, ...
    func focusLog() -> [String] {
        guard let kwinLog else { return [] }
        let log = (try? String(contentsOf: kwinLog, encoding: .utf8)) ?? ""
        return log.split(separator: "\n").compactMap { line in line.range(of: "FOCUS ").map { String(line[$0.upperBound...]) } }
    }

    /// The window KWin activated last, after the first `since` entries of the focus log.
    func lastActivated(since: Int = 0) -> String? {
        focusLog().dropFirst(since).last { $0.hasPrefix("activated ") }.map { String($0.dropFirst(10)) }
    }

    func questionOpen() -> Bool {
        let log = focusLog()
        return log.filter { $0 == "added question" }.count > log.filter { $0 == "removed question" }.count
    }

    /// The system's `number`th shortcut question is on screen and has the keyboard.
    func questionUp(_ number: Int) -> Bool {
        focusLog().filter { $0 == "added question" }.count >= number && questionOpen() && lastActivated() == "question"
    }

    /// Gives the open question the keyboard, as the person's click on it would.
    func activateQuestion() throws {
        let marker = "A" + UUID().uuidString.prefix(8)
        let script = root.appendingPathComponent("activate-\(marker).js")
        try """
        for (const w of workspace.stackingOrder) { if (w.caption == "Global Shortcuts Requested") workspace.activeWindow = w; }
        """.write(to: script, atomically: true, encoding: .utf8)
        try run("/usr/bin/busctl", ["--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "loadScript", "ss", script.path, marker])
        try run("/usr/bin/busctl", ["--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "start"])
        guard eventually(10, { lastActivated() == "question" }) else { throw PanelTestError.timedOut("question activated") }
        try run("/usr/bin/busctl", ["--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "unloadScript", "s", marker])
    }

    /// Stops the desktop portal's front end, so an answer the person gives reaches the agent
    /// only at `releasePortal()`: the question closes, its answer is held back.
    func holdPortal() throws {
        let status = String(decoding: try run("/usr/bin/busctl", ["--user", "status", "org.freedesktop.portal.Desktop"]), as: UTF8.self)
        guard let line = status.split(separator: "\n").first(where: { $0.hasPrefix("PID=") }), let pid = Int32(line.dropFirst(4)), pid > 0 else {
            throw PanelTestError.startupFailed("portal process")
        }
        heldPortal = pid
        kill(pid, SIGSTOP)
    }

    func releasePortal() {
        if heldPortal > 0 { kill(heldPortal, SIGCONT) }
        heldPortal = 0
    }

    /// Accessible roles and names of the agent's windows, as AT-SPI reports them.
    func accessibleTree() throws -> [String] {
        let script = root.appendingPathComponent("atspi.py")
        try """
        import gi
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi
        def walk(node, depth):
            print(str(depth) + "\\t" + node.get_role_name() + "\\t" + (node.get_name() or ""))
            for i in range(node.get_child_count()):
                child = node.get_child_at_index(i)
                if child is not None: walk(child, depth + 1)
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(i)
            if app is not None and (app.get_name() or "").lower() == "catflap": walk(app, 0)
        """.write(to: script, atomically: true, encoding: .utf8)
        return String(decoding: try run("/usr/bin/python3", [script.path], seconds: 20), as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }
}

/// Evdev key codes the fake keyboard sends.
private enum Key {
    static let escape = "1", enter = "28", down = "108", ctrl = "29", alt = "56", space = "57"
    static let letters: [Character: String] = ["n": "49", "o": "24", "t": "20", "e": "18", "s": "31", "x": "45", "m": "50", "a": "30"]
}

final class LinuxPanelE2E: XCTestCase {
    func testToggleOpensFocusedAndAgainCloses() throws {
        let session = try PanelSession()
        try session.start()
        try session.confirmShortcut()
        let opened = try session.toggle()
        XCTAssertTrue(opened.visible)
        XCTAssertEqual(opened.mode, "focused")
        XCTAssertTrue(try session.eventually { try session.state().hasFocus })
        let state = try session.state()
        XCTAssertTrue(state.visible)
        XCTAssertEqual(state.mode, "focused")
        XCTAssertEqual(state.display, "Virtual-0")
        // Top centre, below the 40 px the top panel reserves, above other windows.
        let panel = try XCTUnwrap(try session.panelWindow())
        XCTAssertEqual(panel.y, 40)
        XCTAssertEqual(panel.x + panel.w / 2, PanelSession.width / 2)
        XCTAssertEqual(panel.w, 420)
        XCTAssertEqual(panel.output, "Virtual-0")
        let description = try session.describe()
        XCTAssertEqual(description.placement.layer, "overlay")
        XCTAssertEqual(description.placement.anchor, "top")
        XCTAssertEqual(description.placement.exclusiveZone, 0)
        XCTAssertEqual(description.placement.keyboard, "on_demand")
        let closed = try session.toggle()
        XCTAssertFalse(closed.visible)
        XCTAssertEqual(closed.mode, "hidden")
        XCTAssertFalse(try session.state().visible)
        XCTAssertTrue(try session.eventually { try session.panelWindow() == nil })
    }

    /// The first start's two shortcut questions, with the panel open while they come: the
    /// system's question takes the keyboard without closing the panel, the panel gets it back
    /// once both are answered, and a click outside closes it again from then on.
    func testShortcutQuestionTakesTheKeyboardWithoutClosingThePanel() throws {
        let session = try PanelSession()
        try session.start()
        guard session.eventually(30, { session.questionUp(1) }) else { throw PanelTestError.timedOut("first question") }
        // The first question is up, unanswered: the panel opens over it with the keyboard.
        var mark = session.focusLog().count
        try session.openFocused()
        XCTAssertEqual(session.lastActivated(since: mark), "panel")
        // The person clicks the question: Catflap's own, so the panel stays, without the keyboard.
        mark = session.focusLog().count
        try session.activateQuestion()
        try session.expectWaitingForQuestion()
        XCTAssertEqual(session.lastActivated(since: mark), "question")
        // Answered: the second question comes up while the panel waits, and takes the keyboard.
        try session.input("key \(Key.enter)")
        guard session.eventually(30, { session.questionUp(2) }) else { throw PanelTestError.timedOut("second question") }
        try session.expectWaitingForQuestion()
        XCTAssertEqual(try session.describe().shortcutSetup, "send")
        // Answered too: the panel has the keyboard again.
        mark = session.focusLog().count
        try session.input("key \(Key.enter)")
        XCTAssertTrue(try session.eventually(10) { let s = try session.state(); return s.mode == "focused" && s.visible && s.hasFocus })
        XCTAssertEqual(try session.describe().shortcutSetup, "settled")
        XCTAssertNil(try session.describe().focusLostTo)
        XCTAssertEqual(session.lastActivated(since: mark), "panel")
        XCTAssertEqual(session.focusLog().filter { $0 == "removed catflap" }.count, 0, "the panel never closed")
        // With nothing Catflap asked still open, a click outside closes the panel.
        try session.input("move 100 700", "click")
        XCTAssertTrue(try session.eventually { let s = try session.state(); return s.mode == "hidden" && !s.visible })
    }

    /// The panel opened at each point where the portal holds an answer back: after the first
    /// question closed (the moment the second one is asked), while the second question is up,
    /// and after the second closed. It ends focused each time.
    func testPanelOpenedWhileAnAnswerIsHeldBackKeepsTheKeyboard() throws {
        let session = try PanelSession()
        try session.start()
        guard session.eventually(30, { session.questionUp(1) }) else { throw PanelTestError.timedOut("first question") }
        // Answered, but the answer is held back: the question has closed, the agent still waits.
        try session.holdPortal()
        try session.input("key \(Key.enter)")
        guard session.eventually(10, { !session.questionOpen() }) else { throw PanelTestError.timedOut("first question closed") }
        XCTAssertEqual(try session.describe().shortcut, "pending")
        try session.openFocused()
        // The answer arrives, the agent asks for the second shortcut, and its question comes up
        // over the open panel and takes the keyboard. The panel stays.
        var mark = session.focusLog().count
        session.releasePortal()
        guard session.eventually(30, { session.questionUp(2) }) else { throw PanelTestError.timedOut("second question") }
        try session.expectWaitingForQuestion()
        XCTAssertEqual(session.lastActivated(since: mark), "question")
        // The second question is up: the panel opened again goes over it with the keyboard.
        _ = try session.toggle()
        XCTAssertEqual(try session.state().mode, "hidden")
        try session.openFocused()
        try session.activateQuestion()
        try session.expectWaitingForQuestion()
        // Answered and held back again; the panel opened now has the keyboard, and keeps it when
        // the answer arrives.
        try session.holdPortal()
        try session.input("key \(Key.enter)")
        guard session.eventually(10, { !session.questionOpen() }) else { throw PanelTestError.timedOut("second question closed") }
        XCTAssertEqual(try session.describe().sendClipboardShortcut, "pending")
        if try session.state().mode == "focused" { _ = try session.toggle() }
        XCTAssertEqual(try session.state().mode, "hidden")
        try session.openFocused()
        mark = session.focusLog().count
        session.releasePortal()
        XCTAssertTrue(try session.eventually { try session.describe().shortcutSetup == "settled" })
        let state = try session.state()
        XCTAssertEqual(state.mode, "focused")
        XCTAssertTrue(state.hasFocus)
        XCTAssertNil(session.lastActivated(since: mark), "nothing took the keyboard")
        XCTAssertEqual(try session.describe().sendClipboardShortcut, "bound")
        XCTAssertFalse(try session.toggle().visible)
    }

    /// `panel.show`, which a second launch sends: from hidden and from hover it opens the
    /// panel with the keyboard; a focused panel stays as it is, also while the system's
    /// shortcut question has the keyboard; it never hides the panel; and it answers with what
    /// `ui.state` says.
    func testPanelShowOpensFocusedAndNeverHides() throws {
        let session = try PanelSession()
        try session.start()
        guard session.eventually(30, { session.questionUp(1) }) else { throw PanelTestError.timedOut("first question") }
        // Hidden, with the first question up: the panel opens over it with the keyboard.
        XCTAssertFalse(try session.state().visible)
        var mark = session.focusLog().count
        let opened = try session.show()
        XCTAssertEqual(opened.mode, "focused")
        XCTAssertTrue(opened.visible)
        XCTAssertTrue(opened.hasFocus)
        XCTAssertEqual(opened, try session.state())
        XCTAssertTrue(session.eventually(10) { session.lastActivated(since: mark) == "panel" })
        // The person clicks the question: the panel waits for it, and panel.show leaves it so,
        // without taking the keyboard back and without closing it.
        try session.activateQuestion()
        try session.expectWaitingForQuestion()
        mark = session.focusLog().count
        let waiting = try session.show()
        XCTAssertEqual(waiting.mode, "focused")
        XCTAssertTrue(waiting.visible)
        XCTAssertFalse(waiting.hasFocus)
        XCTAssertEqual(waiting, try session.state())
        XCTAssertEqual(try session.describe().focusLostTo, "system-dialog")
        XCTAssertNil(session.lastActivated(since: mark), "panel.show took the keyboard from the question")
        // Both questions answered: the panel has the keyboard again, and panel.show keeps it so.
        try session.confirmShortcut()
        XCTAssertTrue(try session.eventually(10) { let s = try session.state(); return s.mode == "focused" && s.hasFocus })
        let focused = try session.show()
        XCTAssertEqual(focused.mode, "focused")
        XCTAssertTrue(focused.visible)
        XCTAssertTrue(focused.hasFocus)
        XCTAssertEqual(focused, try session.state())
        XCTAssertEqual(try session.show(), focused)
        XCTAssertEqual(session.focusLog().filter { $0 == "removed catflap" }.count, 0, "panel.show closed the panel")
        // Opened by hover, without the keyboard: panel.show gives it the keyboard where it is.
        XCTAssertEqual(try session.invoke("hide").mode, "hidden")
        let hover = try session.invoke("simulate-hover")
        XCTAssertEqual(hover.mode, "hover")
        XCTAssertFalse(hover.hasFocus)
        let shown = try session.show()
        XCTAssertEqual(shown.mode, "focused")
        XCTAssertTrue(shown.visible)
        XCTAssertTrue(shown.hasFocus)
        XCTAssertEqual(shown, try session.state())
    }

    func testShortcutIsBoundThroughThePortalAndToggles() throws {
        let session = try PanelSession()
        try session.start()
        try session.confirmShortcut()
        XCTAssertEqual(try session.state().shortcut, "bound")
        XCTAssertEqual(try session.describe().shortcutTrigger, "Ctrl+Alt+Space")
        // kglobalaccel, inside the nested KWin, holds the binding for the application.
        let infos = String(decoding: try session.run("/usr/bin/busctl", ["--user", "call", "org.kde.kglobalaccel",
            "/component/io_github_yigityazicilar_Catflap", "org.kde.kglobalaccel.Component", "allShortcutInfos"]), as: UTF8.self)
        XCTAssertTrue(infos.contains("\"toggle-panel\""))
        XCTAssertTrue(infos.contains("\"io.github.yigityazicilar.Catflap\""))
        try session.input("down \(Key.ctrl)", "down \(Key.alt)", "key \(Key.space)", "up \(Key.alt)", "up \(Key.ctrl)")
        XCTAssertTrue(try session.eventually { let s = try session.state(); return s.mode == "focused" && s.visible && s.hasFocus })
        try session.input("down \(Key.ctrl)", "down \(Key.alt)", "key \(Key.space)", "up \(Key.alt)", "up \(Key.ctrl)")
        XCTAssertTrue(try session.eventually { let s = try session.state(); return s.mode == "hidden" && !s.visible })
    }

    func testHoverBandOpensWithoutFocusAndLeavingCloses() throws {
        let session = try PanelSession()
        try session.start()
        try session.confirmShortcut()
        let simulated = try session.invoke("simulate-hover")
        XCTAssertEqual(simulated.mode, "hover")
        XCTAssertTrue(simulated.visible)
        XCTAssertFalse(simulated.hasFocus)
        let state = try session.state()
        XCTAssertEqual(state.mode, "hover")
        XCTAssertFalse(state.hasFocus)
        XCTAssertEqual(try session.invoke("simulate-leave").mode, "hidden")

        // The real pointer: one band per display, below the top panel, at the top centre.
        let bands = try session.windows().filter { $0.cls == "catflap" && $0.h < 10 }
        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(bands.first?.y, 40)
        XCTAssertEqual(bands.first.map { $0.x + $0.w / 2 }, PanelSession.width / 2)
        XCTAssertEqual(try session.describe().bands, ["Virtual-0"])
        try session.pointAtBand()
        // How long the dwell is (200 ms) is checked by PanelMachineTests; here, that resting
        // on the band opens the panel without the keyboard.
        XCTAssertTrue(try session.eventually { try session.state().mode == "hover" })
        let hover = try session.state()
        XCTAssertTrue(hover.visible)
        XCTAssertFalse(hover.hasFocus)
        let panel = try XCTUnwrap(try session.panelWindow())
        XCTAssertEqual(panel.y, 40)
        XCTAssertEqual(try session.describe().placement.keyboard, "none")
        // Into the panel and down it keeps it open; leaving both closes it after 300 ms.
        try session.input("move 640 300")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(try session.state().mode, "hover")
        let mark = Date()
        try session.input("move 640 700")
        let soon = try session.state()
        // Read before 300 ms have passed since the pointer left, the panel is still there.
        if Date().timeIntervalSince(mark) < 0.28 { XCTAssertEqual(soon.mode, "hover") }
        XCTAssertTrue(try session.eventually { try session.state().mode == "hidden" })
        XCTAssertFalse(try session.state().visible)
    }

    func testClickInsideFocusesAndClickOutsideCloses() throws {
        let session = try PanelSession()
        try session.start()
        try session.confirmShortcut()
        try session.pointAtBand()
        XCTAssertTrue(try session.eventually { try session.state().mode == "hover" })
        try session.input("move 640 200", "click")
        XCTAssertTrue(try session.eventually { let s = try session.state(); return s.mode == "focused" && s.hasFocus })
        // Moving away no longer closes a focused panel.
        try session.input("move 640 700")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(try session.state().mode, "focused")
        try session.input("move 100 700", "click")
        XCTAssertTrue(try session.eventually { let s = try session.state(); return s.mode == "hidden" && !s.visible })
    }

    func testReturnAndEscapeFollowTheDesignBrief() throws {
        let session = try PanelSession()
        try session.start()
        try session.confirmShortcut()
        for text in ["notes for the meeting", "a second clipboard line"] {
            _ = try session.catflap(["clip", "add", "--text", text])
        }
        _ = try session.toggle()
        XCTAssertTrue(try session.eventually { try session.state().hasFocus })
        XCTAssertTrue(try session.eventually { try session.describe().rows.count == 2 })
        // Typing filters the list and never selects a row.
        try session.input(contentsOf: "notes")
        XCTAssertTrue(try session.eventually { try session.describe().field == "notes" })
        var description = try session.describe()
        XCTAssertEqual(description.rows, ["notes for the meeting"])
        XCTAssertNil(description.selectedRow)
        // Return without a selection takes the text in the field.
        try session.input("key \(Key.enter)")
        XCTAssertTrue(try session.eventually { try session.describe().lastReturn == "text" })
        // An arrow key selects a row; Return then takes the row.
        try session.input("key \(Key.down)")
        XCTAssertTrue(try session.eventually { try session.describe().selectedRow == 0 })
        try session.input("key \(Key.enter)")
        XCTAssertTrue(try session.eventually { try session.describe().lastReturn?.hasPrefix("row:") == true })
        // Esc clears the selection first and closes on the second press.
        try session.input("key \(Key.escape)")
        XCTAssertTrue(try session.eventually { try session.describe().selectedRow == nil })
        description = try session.describe()
        XCTAssertEqual(description.mode, "focused")
        try session.input("key \(Key.escape)")
        XCTAssertTrue(try session.eventually { try session.state().mode == "hidden" })
    }

    func testDragOpensWithoutFocusAndClosesOnDropOrLeave() throws {
        let session = try PanelSession()
        try session.start()
        try session.confirmShortcut()
        let dragging = try session.invoke("simulate-drag")
        XCTAssertEqual(dragging.mode, "drag")
        XCTAssertTrue(dragging.visible)
        XCTAssertFalse(dragging.hasFocus)
        XCTAssertEqual(try session.describe().placement.keyboard, "none")
        let mark = Date()
        let left = try session.invoke("simulate-drag-leave")
        XCTAssertEqual(left.mode, "hidden")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(mark), 0.5)
        XCTAssertEqual(try session.invoke("simulate-drag").mode, "drag")
        XCTAssertEqual(try session.invoke("simulate-drop").mode, "hidden")
    }

    func testReducedMotionAndHighContrastAreHonoured() throws {
        let plain = try PanelSession()
        try plain.start(topPanel: false)
        var description = try plain.describe()
        XCTAssertFalse(description.reducedMotion)
        XCTAssertEqual(description.motion, "slide")
        XCTAssertFalse(description.highContrast)
        // The nested KWin offers no blur, so the background stays opaque.
        XCTAssertTrue(description.opaque)

        let adjusted = try PanelSession()
        // The desktop's reduced-motion setting as GTK reads it through the settings portal;
        // on Plasma, KDE's GTK settings module keeps this key in step with the animation speed.
        try adjusted.start(topPanel: false, agentEnvironment: ["ADW_DEBUG_HIGH_CONTRAST": "1"], before: {
            try adjusted.run("/usr/bin/gsettings", ["set", "org.gnome.desktop.interface", "enable-animations", "false"])
        })
        // The portal's settings reach GTK shortly after start.
        XCTAssertTrue(try adjusted.eventually { try adjusted.describe().reducedMotion })
        description = try adjusted.describe()
        XCTAssertTrue(description.reducedMotion)
        XCTAssertEqual(description.motion, "none")
        XCTAssertTrue(description.highContrast)
        XCTAssertTrue(description.opaque)
    }

    func testEveryControlHasAnAccessibleLabel() throws {
        let session = try PanelSession()
        try session.start()
        try session.confirmShortcut()
        _ = try session.catflap(["clip", "add", "--text", "row for a screen reader"])
        _ = try session.toggle()
        XCTAssertTrue(try session.eventually { try session.state().hasFocus })
        var tree: [String] = []
        XCTAssertTrue(try session.eventually(10) {
            tree = try session.accessibleTree()
            return tree.contains { $0.hasSuffix("\tSettings") } && tree.contains { $0.contains("\tlist item\t") }
        })
        let entries = tree.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }.filter { $0.count == 3 }
        let controls = entries.filter { ["button", "push button", "toggle button", "switch", "entry", "list item", "check box", "radio button"].contains($0[1]) }
        XCTAssertGreaterThanOrEqual(controls.count, 8, tree.joined(separator: "\n"))
        for control in controls { XCTAssertFalse(control[2].isEmpty, "unlabelled \(control[1])") }
        let names = Set(controls.map { $0[2] })
        // Icon-only controls and the field carry their own labels; buttons with text are
        // named by that text.
        for label in ["Search the list, or type text to send", "Attach…", "Clipboard", "History",
                      "Don't keep what you send", "Pause clipboard history", "Settings", "Pair a device to send"] {
            XCTAssertTrue(names.contains(label), "missing \(label)")
        }
        XCTAssertTrue(controls.contains { $0[1] == "list item" && $0[2].hasPrefix("row for a screen reader, Text") })
        _ = try session.toggle()
    }
}

private extension PanelSession {
    /// Opens the panel with the hotkey's command and waits until it has the keyboard.
    func openFocused(file: StaticString = #filePath, line: UInt = #line) throws {
        let opened = try toggle()
        XCTAssertEqual(opened.mode, "focused", file: file, line: line)
        XCTAssertTrue(try eventually(10) { let s = try state(); return s.visible && s.hasFocus }, "panel never had the keyboard", file: file, line: line)
        // KWin's own account agrees, so a later look at its log starts after this activation.
        XCTAssertTrue(eventually(10) { lastActivated() == "panel" }, file: file, line: line)
    }

    /// The system's question has the keyboard; the panel the person opened stays open and
    /// waits for it. Decided once the panel has seen the keyboard go, not before.
    func expectWaitingForQuestion(file: StaticString = #filePath, line: UInt = #line) throws {
        guard try eventually(10, { try !state().hasFocus }) else { throw PanelTestError.timedOut("keyboard to the question") }
        let after = try state()
        XCTAssertEqual(after.mode, "focused", "the question closed the panel", file: file, line: line)
        XCTAssertTrue(after.visible, file: file, line: line)
        XCTAssertEqual(try describe().focusLostTo, "system-dialog", file: file, line: line)
    }

    /// Types `text` with one fake device, so no key is lost to a new device.
    func input(contentsOf text: String) throws {
        try input(text.map { "key " + (Key.letters[$0] ?? Key.space) })
    }
}
