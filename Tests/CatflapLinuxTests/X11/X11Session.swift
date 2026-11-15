import CatflapCore
import Foundation
import Glibc
import XCTest

enum X11TestError: Error { case missingExecutable, timedOut(String), commandFailed(String), startupFailed(String) }

/// What `ui state --json` reports on Linux.
struct X11UIState: Decodable, Equatable {
    let visible: Bool
    let mode: String
    let hasFocus: Bool
    let display: String?
    let shortcut: String
    let unreadable: [String]?
    enum CodingKeys: String, CodingKey { case visible, mode, display, shortcut, unreadable, hasFocus = "has_focus" }
}

/// A private X11 desktop: Xvfb with its own authorization cookie, xfwm4 with focus-stealing
/// prevention switched on, a session bus of its own and private XDG folders. Input reaches it
/// only through XTEST (`xdotool`). The person's display, bus, config and data are never used:
/// DISPLAY, WAYLAND_DISPLAY, WAYLAND_SOCKET and DBUS_SESSION_BUS_ADDRESS are removed from the
/// inherited environment before anything starts.
final class X11Session {
    static let width = 1280, height = 800
    /// Every program these tests run, beside the catflap executable under test.
    static let tools = ["/usr/bin/Xvfb", "/usr/bin/xfwm4", "/usr/bin/xfconf-query", "/usr/bin/xdotool", "/usr/bin/xclip",
                        "/usr/bin/xprop", "/usr/bin/xwininfo", "/usr/bin/dbus-daemon", "/usr/bin/setsid", "/usr/bin/cc"]

    let root: URL
    let executable: URL
    let data: URL
    var environment: [String: String]
    private var children: [(process: Process, agent: Bool, group: Bool)] = []
    private var groupLeader: Int32 = 0
    private(set) var agentLog: URL?
    private var agentProcess: Process?
    private var helper: URL?

    /// Throws XCTSkip when the X11 tools are missing, unless CATFLAP_X11_REQUIRED=1 (the x11 CI
    /// job and `ci/x11/run.sh` set it), which turns a missing tool into a failure.
    init() throws {
        let missing = Self.tools.filter { !FileManager.default.isExecutableFile(atPath: $0) }
        if !missing.isEmpty {
            let names = missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            if ProcessInfo.processInfo.environment["CATFLAP_X11_REQUIRED"] == "1" {
                XCTFail("CATFLAP_X11_REQUIRED=1 but these are missing: \(names)")
                throw X11TestError.startupFailed("missing \(names)")
            }
            throw XCTSkip("the X11 tests need \(names); ci/x11/run.sh runs them in a container that has them")
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("x11-" + UUID().uuidString.prefix(8))
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
            throw X11TestError.missingExecutable
        }
        executable = path
        environment = ProcessInfo.processInfo.environment
        for name in ["WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "XAUTHORITY", "XDG_SESSION_TYPE",
                     "XDG_ACTIVATION_TOKEN", "DESKTOP_STARTUP_ID", "AT_SPI_BUS_ADDRESS", "GDK_BACKEND", "XDG_CURRENT_DESKTOP"] {
            environment[name] = nil
        }
        environment["CATFLAP_PLATFORM"] = "on"
        environment["HOME"] = root.appendingPathComponent("home").path
        environment["XDG_RUNTIME_DIR"] = root.path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_DATA_HOME"] = root.appendingPathComponent("share").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        environment["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        environment["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + root.appendingPathComponent("bus").path
        environment["XAUTHORITY"] = root.appendingPathComponent("xauthority").path
        environment["GTK_A11Y"] = "none"
        for name in ["home", "config", "share", "cache", "state"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    deinit {
        for child in children.reversed() { stop(child.process, agent: child.agent, group: child.group) }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Processes

    private func stop(_ child: Process, agent: Bool, group: Bool) {
        if group {
            // The bus leads a session of its own, so its group also holds what it started on
            // demand (xfconfd).
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
            kill(child.processIdentifier, SIGKILL)
            XCTAssertTrue(wait(child, seconds: 5))
        }
        if agent { XCTAssertEqual(child.terminationStatus, 0, "the agent ended abnormally") }
    }

    func wait(_ child: Process, seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while child.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        return !child.isRunning
    }

    @discardableResult
    func launch(_ path: String, _ arguments: [String], agent: Bool = false, group: Bool = false, extra: [String: String] = [:],
                input: URL? = nil, output: URL? = nil, log name: String? = nil) throws -> Process {
        let child = Process()
        // `setsid -w` gives the program a session of its own and stays as its parent, so the
        // test runner still sees every process it starts.
        child.executableURL = URL(fileURLWithPath: group ? "/usr/bin/setsid" : path)
        child.arguments = group ? ["-w", path] + arguments : arguments
        child.environment = environment.merging(extra) { $1 }
        let pidFile = root.appendingPathComponent("pid-" + UUID().uuidString)
        if group {
            _ = FileManager.default.createFile(atPath: pidFile.path, contents: nil)
            child.standardOutput = try FileHandle(forWritingTo: pidFile)
        } else if let output {
            _ = FileManager.default.createFile(atPath: output.path, contents: nil)
            child.standardOutput = try FileHandle(forWritingTo: output)
        } else {
            child.standardOutput = FileHandle.nullDevice
        }
        child.standardInput = try input.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        let log = root.appendingPathComponent("log-" + (name ?? UUID().uuidString))
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        child.standardError = try FileHandle(forWritingTo: log)
        try child.run()
        children.append((child, agent, group))
        if agent { agentLog = log; agentProcess = child }
        if group {
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
    func run(_ path: String, _ arguments: [String], seconds: TimeInterval = 15, extra: [String: String] = [:],
             allowFailure: Bool = false) throws -> Data {
        let output = root.appendingPathComponent("output-" + UUID().uuidString)
        let errors = root.appendingPathComponent("errors-" + UUID().uuidString)
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errors.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: errors)
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: path)
        child.arguments = arguments
        child.environment = environment.merging(extra) { $1 }
        child.standardOutput = try FileHandle(forWritingTo: output)
        child.standardError = try FileHandle(forWritingTo: errors)
        child.standardInput = FileHandle.nullDevice
        try child.run()
        if !wait(child, seconds: seconds) {
            kill(child.processIdentifier, SIGKILL)
            _ = wait(child, seconds: 5)
            throw X11TestError.timedOut(([path] + arguments).joined(separator: " "))
        }
        guard allowFailure || child.terminationStatus == 0 else {
            let said = String(decoding: (try? Data(contentsOf: errors)) ?? Data(), as: UTF8.self)
            throw X11TestError.commandFailed(([path] + arguments).joined(separator: " ") + " exited \(child.terminationStatus): " + said)
        }
        return try Data(contentsOf: output)
    }

    func text(_ path: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
        String(decoding: try run(path, arguments, allowFailure: allowFailure), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A value for a failure message, read without throwing.
    func show(_ read: () throws -> Any) -> String {
        (try? read()).map { "\($0)" } ?? "(could not be read)"
    }

    /// Polls `condition` until it holds or `seconds` pass. The bound only guards against a
    /// hang; the condition is the event being waited for.
    func eventually(_ seconds: TimeInterval = 20, _ condition: () throws -> Bool) rethrows -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.03)
        } while Date() < end
        return false
    }

    // MARK: The desktop

    /// The session bus, Xvfb and, unless `windowManager` is false, xfwm4.
    func startDesktop(windowManager: Bool = true) throws {
        let address = environment["DBUS_SESSION_BUS_ADDRESS"]!
        // It prints its pid, which leads its session: the group stop() ends.
        let bus = try launch("/usr/bin/dbus-daemon", ["--session", "--nofork", "--print-pid", "--address=" + address], group: true, log: "bus")
        // A bus that printed its pid has started; one that could not start says why in its log.
        guard groupLeader > 0, bus.isRunning,
              eventually(10, { FileManager.default.fileExists(atPath: root.appendingPathComponent("bus").path) }) else {
            throw X11TestError.startupFailed("session bus: " + log("bus"))
        }
        try writeAuthority()
        let number = root.appendingPathComponent("display-number")
        let server = try launch("/usr/bin/Xvfb", ["-displayfd", "1", "-nolisten", "tcp", "-auth", environment["XAUTHORITY"]!,
                                                  "-screen", "0", "\(Self.width)x\(Self.height)x24"], output: number, log: "xvfb")
        var display = ""
        guard eventually(20, {
            display = String(decoding: (try? Data(contentsOf: number)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return server.isRunning && !display.isEmpty
        }) else { throw X11TestError.startupFailed("Xvfb: " + log("xvfb")) }
        environment["DISPLAY"] = ":" + display
        guard windowManager else { return }
        // Focus-stealing prevention on: the hotkey must still give the panel the keyboard.
        try run("/usr/bin/xfconf-query", ["-c", "xfwm4", "-p", "/general/prevent_focus_stealing", "-n", "-t", "bool", "-s", "true"])
        try run("/usr/bin/xfconf-query", ["-c", "xfwm4", "-p", "/general/use_compositing", "-n", "-t", "bool", "-s", "false"])
        try launch("/usr/bin/xfwm4", ["--compositor=off"], log: "xfwm4")
        guard eventually(20, { (try? text("/usr/bin/xprop", ["-root", "_NET_SUPPORTING_WM_CHECK"]))?.contains("window id") == true }) else {
            throw X11TestError.startupFailed("xfwm4: " + log("xfwm4"))
        }
    }

    /// An authorization file with one random cookie for any display number, so only the
    /// processes of this test reach this X server.
    private func writeAuthority() throws {
        var cookie = [UInt8](repeating: 0, count: 16)
        for index in cookie.indices { cookie[index] = UInt8.random(in: 0...255) }
        func field(_ bytes: [UInt8]) -> [UInt8] { [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)] + bytes }
        let entry: [UInt8] = [0xff, 0xff] + field([]) + field([]) + field(Array("MIT-MAGIC-COOKIE-1".utf8)) + field(cookie)
        let path = environment["XAUTHORITY"]!
        guard FileManager.default.createFile(atPath: path, contents: Data(entry), attributes: [.posixPermissions: 0o600]) else {
            throw X11TestError.startupFailed("authority file")
        }
    }

    func log(_ name: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent("log-" + name), encoding: .utf8)) ?? ""
    }

    // MARK: The agent

    /// Starts the agent and waits until it answers; what it reports is the test's to check.
    func startAgent(extra: [String: String] = [:]) throws {
        let child = try launch(executable.path, ["agent", "--data-dir", data.path], agent: true, extra: extra, log: "agent")
        guard eventually(30, { child.isRunning && (try? status()) != nil }) else {
            throw X11TestError.startupFailed("agent: " + log("agent"))
        }
    }

    /// Waits until the agent's status satisfies `ready`; a failed assertion naming what it
    /// reported otherwise.
    func expectStatus(_ message: String, file: StaticString = #filePath, line: UInt = #line, _ ready: (X11Status) -> Bool) {
        var last: X11Status?
        let reached = eventually(30) {
            last = try? status()
            return last.map(ready) ?? false
        }
        XCTAssertTrue(reached, "\(message): \(last.map { "\($0)" } ?? "no status")", file: file, line: line)
    }

    func catflap(_ arguments: [String], extra: [String: String] = [:]) throws -> Data {
        try run(executable.path, arguments + ["--data-dir", data.path, "--json"], extra: extra)
    }

    func status() throws -> X11Status { try ControlJSON.decoder.decode(X11Status.self, from: catflap(["status"])) }
    func state() throws -> X11UIState { try ControlJSON.decoder.decode(X11UIState.self, from: catflap(["ui", "state"])) }
    func items() throws -> [ClipboardItem] { try ControlJSON.decoder.decode([ClipboardItem].self, from: catflap(["clip", "list"])) }

    // MARK: X clients

    func xdotool(_ arguments: String...) throws { try run("/usr/bin/xdotool", arguments) }

    /// The visible top-level window called `name`, if there is one.
    func window(named name: String) throws -> String? {
        let found = try text("/usr/bin/xdotool", ["search", "--onlyvisible", "--name", "^" + name + "$"], allowFailure: true)
        return found.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    func activeWindow() throws -> String? {
        let found = try text("/usr/bin/xdotool", ["getactivewindow"], allowFailure: true)
        return found.isEmpty ? nil : found
    }

    /// What `xprop` prints for one property of a window.
    func property(_ window: String, _ name: String) throws -> String {
        try text("/usr/bin/xprop", ["-id", window, name])
    }

    /// The window's frame-independent position and size on the screen, as xwininfo reports it.
    func geometry(_ window: String) throws -> (x: Int, y: Int, width: Int, height: Int) {
        let info = try text("/usr/bin/xwininfo", ["-id", window])
        func value(_ label: String) -> Int {
            info.split(whereSeparator: \.isNewline).first { $0.contains(label) }
                .flatMap { Int($0.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)) } ?? -1
        }
        return (value("Absolute upper-left X"), value("Absolute upper-left Y"), value("Width"), value("Height"))
    }

    /// The test's own X client (`X11Helper.source`), built once per session.
    func helperPath() throws -> String {
        if let helper { return helper.path }
        let source = root.appendingPathComponent("x11-helper.c")
        let program = root.appendingPathComponent("x11-helper")
        try X11Helper.source.write(to: source, atomically: true, encoding: .utf8)
        try run("/usr/bin/cc", [source.path, "-o", program.path, "-lX11"], seconds: 60)
        helper = program
        return program.path
    }

    /// A normal application window called `title`, made the active window.
    @discardableResult
    func otherWindow(_ title: String = "Other") throws -> String {
        let ready = root.appendingPathComponent("ready-" + title)
        try launch(try helperPath(), ["window", title, ready.path], log: "window-" + title)
        guard eventually(20, { FileManager.default.fileExists(atPath: ready.path) }), let id = try eventuallyWindow(title) else {
            throw X11TestError.startupFailed("window " + title)
        }
        try xdotool("windowactivate", "--sync", id)
        guard try eventually(20, { try activeWindow() == id }) else { throw X11TestError.startupFailed("activating " + title) }
        return id
    }

    /// Starts writing every FocusIn and FocusOut `window` receives, with mode and detail, to
    /// the file returned, as a plain X client sees them.
    func watchFocus(_ window: String) throws -> URL {
        let log = root.appendingPathComponent("focus-\(window)")
        let ready = root.appendingPathComponent("ready-focus-\(window)")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        try launch(try helperPath(), ["focus", window, log.path, ready.path], log: "focus-watch")
        guard eventually(20, { FileManager.default.fileExists(atPath: ready.path) }) else {
            throw X11TestError.startupFailed("focus watch: " + self.log("focus-watch"))
        }
        return log
    }

    /// Starts recording the desktop notifications asked of the session bus. No notification
    /// server runs; the call itself is what the tests look for.
    func watchNotifications() throws {
        let monitor = root.appendingPathComponent("notify-calls")
        try launch("/usr/bin/dbus-monitor", ["--session", "type='method_call',interface='org.freedesktop.Notifications',member='Notify'"],
                   output: monitor, log: "dbus-monitor")
        // The monitor announces itself with a NameAcquired signal before it records anything.
        guard eventually(10, { ((try? String(contentsOf: monitor, encoding: .utf8)) ?? "").contains("NameAcquired") }) else {
            throw X11TestError.startupFailed("dbus-monitor: " + log("dbus-monitor"))
        }
    }

    /// What the recorded Notify calls carried.
    func notifyCalls() -> String {
        (try? String(contentsOf: root.appendingPathComponent("notify-calls"), encoding: .utf8)) ?? ""
    }

    /// The panel's report beyond `ui state`.
    func describe() throws -> X11Describe { try ControlJSON.decoder.decode(X11Describe.self, from: catflap(["ui", "invoke", "describe"])) }

    func eventuallyWindow(_ name: String) throws -> String? {
        var id: String?
        _ = try eventually { id = try window(named: name); return id != nil }
        return id
    }
}

/// The part of `catflap ui invoke describe` these tests read: both shortcuts' setup.
struct X11Describe: Decodable {
    let sendClipboardShortcut: String
    let shortcutSetup: String
    enum CodingKeys: String, CodingKey { case sendClipboardShortcut = "send_clipboard_shortcut", shortcutSetup = "shortcut_setup" }
}

/// What `catflap status --json` reports about the desktop.
struct X11Status: Decodable {
    let desktop: String
    let clipboardCapture: String
    enum CodingKeys: String, CodingKey { case desktop, clipboardCapture = "clipboard_capture" }
}

/// A small X client the tests drive, so they see exactly what Catflap asked of other clients.
///
///   x11-helper window TITLE READY        maps a normal window called TITLE, then touches READY
///   x11-helper owner LOG BODY TYPE...    owns CLIPBOARD offering TYPEs; answers TARGETS, and
///                                        any other request with BODY; writes each requested
///                                        target's name to LOG, one per line, as it is asked
///   x11-helper grab READY                grabs Ctrl+Alt+Space on the root window with every
///                                        lock-key variant, then touches READY (or exits 3)
///   x11-helper focus WINDOW LOG READY    selects FocusChangeMask on WINDOW (another client's),
///                                        touches READY, and writes each FocusIn/FocusOut to
///                                        LOG with its mode and detail
enum X11Helper {
    static let source = #"""
    #include <X11/Xlib.h>
    #include <X11/Xatom.h>
    #include <X11/keysym.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>

    static int failed;
    static int on_error(Display *d, XErrorEvent *e) { (void)d; failed = e->error_code; return 0; }
    static void touch(const char *path) { FILE *f = fopen(path, "w"); if (f) fclose(f); }

    static int window(Display *d, const char *title, const char *ready) {
        Window w = XCreateSimpleWindow(d, DefaultRootWindow(d), 100, 300, 400, 300, 0, 0, 0xffffff);
        XStoreName(d, w, title);
        XSelectInput(d, w, ExposureMask | KeyPressMask | FocusChangeMask);
        XMapWindow(d, w);
        XSync(d, False);
        touch(ready);
        for (;;) { XEvent e; XNextEvent(d, &e); }
    }

    static int owner(Display *d, const char *logpath, const char *body, char **types, int count) {
        FILE *log = fopen(logpath, "a");
        if (!log) return 2;
        setvbuf(log, NULL, _IOLBF, 0);
        Window w = XCreateSimpleWindow(d, DefaultRootWindow(d), 0, 0, 1, 1, 0, 0, 0);
        Atom clipboard = XInternAtom(d, "CLIPBOARD", False), targets = XInternAtom(d, "TARGETS", False);
        Atom offered[34];
        int n = 0;
        offered[n++] = targets;
        for (int i = 0; i < count && n < 34; i++) offered[n++] = XInternAtom(d, types[i], False);
        XSetSelectionOwner(d, clipboard, w, CurrentTime);
        XSync(d, False);
        if (XGetSelectionOwner(d, clipboard) != w) return 3;
        fprintf(log, "owner\n");
        for (;;) {
            XEvent e;
            XNextEvent(d, &e);
            if (e.type == SelectionClear) { fprintf(log, "cleared\n"); return 0; }
            if (e.type != SelectionRequest) continue;
            XSelectionRequestEvent *r = &e.xselectionrequest;
            char *name = XGetAtomName(d, r->target);
            fprintf(log, "%s\n", name ? name : "?");
            XSelectionEvent reply = { .type = SelectionNotify, .display = d, .requestor = r->requestor,
                                      .selection = r->selection, .target = r->target, .property = r->property, .time = r->time };
            if (r->property == None) reply.property = None;
            else if (r->target == targets)
                XChangeProperty(d, r->requestor, r->property, XA_ATOM, 32, PropModeReplace, (unsigned char *)offered, n);
            else
                XChangeProperty(d, r->requestor, r->property, r->target, 8, PropModeReplace, (const unsigned char *)body, (int)strlen(body));
            XSendEvent(d, r->requestor, False, 0, (XEvent *)&reply);
            XFlush(d);
            if (name) XFree(name);
        }
    }

    static int grab(Display *d, const char *ready) {
        XSetErrorHandler(on_error);
        KeyCode code = XKeysymToKeycode(d, XK_space);
        unsigned int locks[] = { 0, LockMask, Mod2Mask, LockMask | Mod2Mask };
        for (int i = 0; i < 4; i++)
            XGrabKey(d, code, ControlMask | Mod1Mask | locks[i], DefaultRootWindow(d), False, GrabModeAsync, GrabModeAsync);
        XSync(d, False);
        if (failed) return 3;
        touch(ready);
        for (;;) { XEvent e; XNextEvent(d, &e); }
    }

    static const char *mode_name(int mode) {
        switch (mode) { case NotifyNormal: return "NotifyNormal"; case NotifyGrab: return "NotifyGrab";
                        case NotifyUngrab: return "NotifyUngrab"; case NotifyWhileGrabbed: return "NotifyWhileGrabbed"; }
        return "?";
    }

    static const char *detail_name(int detail) {
        switch (detail) { case NotifyAncestor: return "NotifyAncestor"; case NotifyVirtual: return "NotifyVirtual";
                          case NotifyInferior: return "NotifyInferior"; case NotifyNonlinear: return "NotifyNonlinear";
                          case NotifyNonlinearVirtual: return "NotifyNonlinearVirtual"; case NotifyPointer: return "NotifyPointer";
                          case NotifyPointerRoot: return "NotifyPointerRoot"; case NotifyDetailNone: return "NotifyDetailNone"; }
        return "?";
    }

    static int focus(Display *d, const char *window, const char *logpath, const char *ready) {
        FILE *log = fopen(logpath, "a");
        if (!log) return 2;
        setvbuf(log, NULL, _IOLBF, 0);
        XSetErrorHandler(on_error);
        Window w = (Window)strtoul(window, NULL, 0);
        XSelectInput(d, w, FocusChangeMask);
        XSync(d, False);
        if (failed) return 3;
        touch(ready);
        for (;;) {
            XEvent e;
            XNextEvent(d, &e);
            if (e.type != FocusIn && e.type != FocusOut) continue;
            fprintf(log, "%s %s %s\n", e.type == FocusIn ? "FocusIn" : "FocusOut", mode_name(e.xfocus.mode), detail_name(e.xfocus.detail));
        }
    }

    int main(int argc, char **argv) {
        Display *d = XOpenDisplay(NULL);
        if (!d || argc < 2) return 2;
        if (!strcmp(argv[1], "window") && argc == 4) return window(d, argv[2], argv[3]);
        if (!strcmp(argv[1], "owner") && argc >= 4) return owner(d, argv[2], argv[3], argv + 4, argc - 4);
        if (!strcmp(argv[1], "grab") && argc == 3) return grab(d, argv[2]);
        if (!strcmp(argv[1], "focus") && argc == 5) return focus(d, argv[2], argv[3], argv[4]);
        return 2;
    }
    """#
}
