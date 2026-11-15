import CatflapCore
import Foundation
import Glibc
import XCTest

enum ActionsTestError: Error { case missingExecutable, timedOut(String), commandFailed(String), startupFailed(String) }

/// A nested `kwin_wayland --virtual` with its own runtime directory and session bus (the
/// desktop portal starts on demand there), a stand-in notification server and tray host, a
/// fake keyboard and pointer, the panel's agent, and a second agent without a desktop to pair
/// and exchange items with. Nothing reaches the person's own session, home or clipboard.
final class ActionsSession {
    static let socket = "actions-test"
    static let width = 1280, height = 800
    let root: URL
    let executable: URL
    let data: URL
    let peerData: URL
    var environment: [String: String]
    private var children: [(process: Process, agent: Bool, group: Bool)] = []
    private var groupLeader: Int32 = 0
    private var kwinLog: URL?
    private var fakeInput: URL?
    private(set) var panelAgent: Process?
    private(set) var peerAgent: Process?
    /// What the stand-in notification server and tray host saw, one JSON object per line.
    let busLog: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ac-" + UUID().uuidString.prefix(8).lowercased())
        data = root.appendingPathComponent("data")
        peerData = root.appendingPathComponent("peer")
        busLog = root.appendingPathComponent("bus-events")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("catflap")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { found = candidate; break }
            directory.deleteLastPathComponent()
        }
        guard let path = ProcessInfo.processInfo.environment["CATFLAP_EXECUTABLE"].map(URL.init(fileURLWithPath:)) ?? found else {
            throw ActionsTestError.missingExecutable
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
        environment["KDE_DEBUG"] = "1"
        environment["LIBGL_ALWAYS_SOFTWARE"] = "1"
        for name in ["home", "config", "share/applications", "data", "peer", "config/xdg-desktop-portal"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "[preferred]\ndefault=kde;gtk;\norg.freedesktop.impl.portal.FileChooser=gtk;\n"
            .write(to: root.appendingPathComponent("config/xdg-desktop-portal/kde-portals.conf"), atomically: true, encoding: .utf8)
        // The portal gives a host application an ID only if a desktop file names it.
        try "[Desktop Entry]\nType=Application\nName=Catflap\nExec=\(executable.path) agent\nNoDisplay=true\n"
            .write(to: root.appendingPathComponent("share/applications/io.github.yigityazicilar.Catflap.desktop"), atomically: true, encoding: .utf8)
    }

    deinit {
        for child in children.reversed() { stop(child.process, agent: child.agent, group: child.group) }
        let mounts = (try? String(contentsOfFile: "/proc/self/mounts", encoding: .utf8)) ?? ""
        XCTAssertFalse(mounts.contains(root.path), "a mount is left under the test directory")
        try? FileManager.default.removeItem(at: root)
    }

    private func stop(_ child: Process, agent: Bool, group: Bool) {
        let pid = child.processIdentifier
        if group {
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
        if name == "kwin" { kwinLog = log }
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
    func run(_ path: String, _ arguments: [String], seconds: TimeInterval = 15, allowFailure: Bool = false) throws -> Data {
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
            throw ActionsTestError.timedOut(([path] + arguments.prefix(3)).joined(separator: " "))
        }
        guard allowFailure || child.terminationStatus == 0 else {
            throw ActionsTestError.commandFailed(([path] + arguments.prefix(3)).joined(separator: " "))
        }
        return try Data(contentsOf: output)
    }

    /// `catflap <arguments> --json` against the panel's agent, or the peer's.
    func catflap(_ arguments: [String], peer: Bool = false, seconds: TimeInterval = 15) throws -> Data {
        try run(executable.path, arguments + ["--data-dir", (peer ? peerData : data).path, "--json"], seconds: seconds)
    }

    /// A `ui invoke` action with arguments, sent on the panel agent's control socket as the
    /// command line sends it.
    func invoke(_ action: String, _ arguments: [String: String] = [:]) throws -> ControlResponse {
        var all = arguments
        all["action"] = action
        return try ControlClient.request(ControlRequest("ui.invoke", arguments: all), socket: data.appendingPathComponent("control.sock"))
    }

    func describe() throws -> ActionsDescription {
        try ControlJSON.decoder.decode(ActionsDescription.self, from: catflap(["ui", "invoke", "describe"]))
    }

    /// The lists `ui state` says the panel could not read at its latest refresh; nil when it
    /// does not report them. Read without a typed state, so this runs against an agent that
    /// lacks the field.
    func unreadable() throws -> [String]? {
        let object = try JSONSerialization.jsonObject(with: catflap(["ui", "state"])) as? [String: Any]
        return object?["unreadable"] as? [String]
    }

    func history(peer: Bool = false) throws -> [TransferRecord] {
        try ControlJSON.decoder.decode([TransferRecord].self, from: catflap(["history"], peer: peer))
    }

    func devices(peer: Bool = false) throws -> [DeviceSummary] {
        try ControlJSON.decoder.decode([DeviceSummary].self, from: catflap(["devices"], peer: peer))
    }

    /// The text on the nested session's clipboard, read with wl-paste as any other client would.
    func paste(types: Bool = false) -> String? {
        guard let data = try? run("/usr/bin/wl-paste", types ? ["--list-types"] : ["--no-newline"], seconds: 5) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func eventually(_ seconds: TimeInterval = 20, _ condition: () throws -> Bool) rethrows -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < end
        return false
    }

    /// Writes a setting into an agent's store before that agent starts.
    func setSetting(_ key: String, _ value: String, peer: Bool) throws {
        let store = try Store(paths: AgentPaths(directory: peer ? peerData : data))
        let done = DispatchSemaphore(value: 0)
        let failed = Flag()
        Task.detached {
            do { try await store.setSetting(key, value: value) } catch { failed.set() }
            done.signal()
        }
        done.wait()
        if failed.value { throw ActionsTestError.startupFailed("setting \(key)") }
    }

    /// The nested compositor, the bus with the stand-in services, and the panel's agent.
    /// With `peer`, also a second agent without a desktop.
    func start(peer: Bool = true) throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/kwin_wayland") else {
            if ProcessInfo.processInfo.environment["CI"] == "true" {
                throw XCTSkip("CI=true: no nested KWin compositor installed")
            }
            XCTFail("Nested KWin is required; the live display is never used")
            throw ActionsTestError.startupFailed("no kwin_wayland")
        }
        try launch("/usr/bin/dbus-daemon", ["--session", "--nofork", "--print-pid", "--address=" + environment["DBUS_SESSION_BUS_ADDRESS"]!],
                   group: true, extra: ["WAYLAND_DISPLAY": Self.socket, "QT_QPA_PLATFORM": "wayland"], log: "bus")
        guard eventually(5, { FileManager.default.fileExists(atPath: root.appendingPathComponent("bus").path) }) else {
            throw ActionsTestError.startupFailed("bus")
        }
        try startStandIns()
        let kwin = try launch("/usr/bin/kwin_wayland",
                              ["--virtual", "--socket", Self.socket, "--no-lockscreen", "--no-kactivities",
                               "--width", String(Self.width), "--height", String(Self.height)],
                              extra: ["QT_QPA_PLATFORM": "offscreen", "KWIN_COMPOSE": "Q", "KWIN_WAYLAND_NO_PERMISSION_CHECKS": "1",
                                      "QT_FORCE_STDERR_LOGGING": "1", "QT_LOGGING_RULES": "kwin_scripting.debug=true"],
                              log: "kwin")
        guard eventually(10, { kwin.isRunning && FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.socket).path) }) else {
            throw ActionsTestError.startupFailed("kwin")
        }
        environment["WAYLAND_DISPLAY"] = Self.socket
        try buildFakeInput()
        try setSetting("inbox", data.appendingPathComponent("inbox").path, peer: false)
        try startPanelAgent()
        if peer {
            try setSetting("inbox", peerData.appendingPathComponent("inbox").path, peer: true)
            peerAgent = try launch(executable.path, ["agent", "--data-dir", peerData.path], agent: true,
                                   extra: ["CATFLAP_PLATFORM": "off"], log: "peer")
            guard eventually(15, { (try? catflap(["status"], peer: true)) != nil }) else { throw ActionsTestError.startupFailed("peer") }
        }
    }

    func startPanelAgent() throws {
        let agent = try launch(executable.path, ["agent", "--data-dir", data.path], agent: true, log: "agent")
        panelAgent = agent
        guard eventually(20, { agent.isRunning && (try? describe()) != nil }) else { throw ActionsTestError.startupFailed("agent") }
    }

    /// Stops the panel's agent as logging out does, and starts it again.
    func restartPanelAgent() throws {
        guard let agent = panelAgent else { return }
        agent.terminate()
        XCTAssertTrue(wait(agent, seconds: 7), "Agent did not stop within 7 s of SIGTERM")
        XCTAssertEqual(agent.terminationStatus, 0)
        children.removeAll { $0.process === agent }
        try startPanelAgent()
    }

    /// Answers each "Global Shortcuts Requested" dialog with Return, as the person would,
    /// until both of the agent's shortcuts are settled.
    func confirmShortcuts() throws {
        guard try eventually(30, {
            let description = try describe()
            if description.shortcut != "pending" && description.sendClipboardShortcut != "pending" { return true }
            if (try? windows().contains { $0.caption == "Global Shortcuts Requested" }) == true {
                try input("key 28")
                Thread.sleep(forTimeInterval: 0.5)
            }
            return false
        }) else { throw ActionsTestError.timedOut("shortcuts") }
        _ = eventually(5) { (try? windows().contains { $0.caption == "Global Shortcuts Requested" }) == false }
    }

    /// Pairs the two agents through the command line, both confirming.
    func pairWithCommandLine() throws {
        var status = try ControlJSON.decoder.decode(PairingStatus.self, from: catflap(["pair", "start"], seconds: 60))
        _ = try eventually(60) {
            status = try ControlJSON.decoder.decode(PairingStatus.self, from: catflap(["pair", "status"]))
            return status.code != nil
        }
        guard let code = status.code else { throw ActionsTestError.timedOut("pairing code") }
        _ = try catflap(["pair", "join", code], peer: true, seconds: 60)
        for peer in [false, true] {
            guard try eventually(60, { try ControlJSON.decoder.decode(PairingStatus.self, from: catflap(["pair", "status"], peer: peer)).state == .confirm }) else {
                throw ActionsTestError.timedOut("digits")
            }
            _ = try catflap(["pair", "confirm"], peer: peer)
        }
        for peer in [false, true] {
            guard try eventually(60, { try devices(peer: peer).count == 1 }) else { throw ActionsTestError.timedOut("paired") }
        }
    }

    // MARK: Stand-ins on the private bus

    /// A notification server and a tray host (StatusNotifierWatcher) that record what they
    /// are asked, and a test interface that makes the server report a clicked action.
    private func startStandIns() throws {
        let script = root.appendingPathComponent("standins.py")
        try """
        import gi, json, sys
        gi.require_version("Gio", "2.0")
        from gi.repository import Gio, GLib
        log = open(sys.argv[1], "a", buffering=1)
        def record(event): log.write(json.dumps(event) + "\\n")
        xml = '''<node>
        <interface name="org.freedesktop.Notifications">
          <method name="GetCapabilities"><arg type="as" direction="out"/></method>
          <method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
            <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/>
            <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
          <method name="CloseNotification"><arg type="u" direction="in"/></method>
          <method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/>
            <arg type="s" direction="out"/><arg type="s" direction="out"/></method>
          <signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
          <signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
        </interface>
        <interface name="org.kde.StatusNotifierWatcher">
          <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
          <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
          <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
          <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
          <property name="ProtocolVersion" type="i" access="read"/>
        </interface>
        <interface name="test.Control">
          <method name="Invoke"><arg type="u" direction="in"/><arg type="s" direction="in"/></method>
        </interface>
        </node>'''
        node = Gio.DBusNodeInfo.new_for_xml(xml)
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        state = {"next": 0, "items": []}
        def call(connection, sender, path, interface, method, params, invocation):
            if method == "GetCapabilities":
                invocation.return_value(GLib.Variant("(as)", (["actions", "body"],)))
            elif method == "GetServerInformation":
                invocation.return_value(GLib.Variant("(ssss)", ("stand-in", "test", "1", "1.2")))
            elif method == "Notify":
                app, replaces, icon, title, body, actions, hints, timeout = params.unpack()
                state["next"] += 1
                record({"event": "notify", "id": state["next"], "app": app, "title": title, "body": body, "actions": actions,
                        "urgency": hints.get("urgency"), "suppress_sound": hints.get("suppress-sound"),
                        "desktop_entry": hints.get("desktop-entry")})
                invocation.return_value(GLib.Variant("(u)", (state["next"],)))
            elif method == "CloseNotification":
                invocation.return_value(None)
            elif method == "RegisterStatusNotifierItem":
                service = params.unpack()[0]
                state["items"].append(service)
                record({"event": "tray", "service": service, "sender": sender})
                invocation.return_value(None)
            elif method == "RegisterStatusNotifierHost":
                invocation.return_value(None)
            elif method == "Invoke":
                nid, action = params.unpack()
                connection.emit_signal(None, "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
                                       "ActionInvoked", GLib.Variant("(us)", (nid, action)))
                invocation.return_value(None)
        def prop(connection, sender, path, interface, name):
            if name == "RegisteredStatusNotifierItems": return GLib.Variant("as", state["items"])
            if name == "IsStatusNotifierHostRegistered": return GLib.Variant("b", True)
            return GLib.Variant("i", 0)
        bus.register_object("/org/freedesktop/Notifications", node.interfaces[0], call, None, None)
        bus.register_object("/StatusNotifierWatcher", node.interfaces[1], call, prop, None)
        bus.register_object("/test", node.interfaces[2], call, None, None)
        for name in ["org.freedesktop.Notifications", "org.kde.StatusNotifierWatcher", "test.StandIns"]:
            bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                          GLib.Variant("(su)", (name, 4)), None, Gio.DBusCallFlags.NONE, -1, None)
        record({"event": "ready"})
        GLib.MainLoop().run()
        """.write(to: script, atomically: true, encoding: .utf8)
        try launch("/usr/bin/python3", [script.path, busLog.path], log: "standins")
        guard eventually(10, { events().contains { $0["event"] as? String == "ready" } }) else {
            throw ActionsTestError.startupFailed("stand-in services")
        }
    }

    /// What the stand-ins recorded so far.
    func events() -> [[String: Any]] {
        let text = (try? String(contentsOf: busLog, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func notifications() -> [[String: Any]] { events().filter { $0["event"] as? String == "notify" } }

    /// The stand-in notification server reports that the person clicked `action`.
    func clickNotification(_ id: Int, _ action: String) throws {
        try run("/usr/bin/busctl", ["--user", "call", "test.StandIns", "/test", "test.Control", "Invoke", "us", String(id), action])
    }

    // MARK: Input and windows

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

    /// Fake keyboard and pointer: `key CODE`, `down CODE`, `up CODE`, `move X Y`, `click`, `wait MS`.
    func input(_ commands: String...) throws { try input(commands) }

    func input(_ commands: [String]) throws {
        guard let fakeInput else { throw ActionsTestError.startupFailed("fake input") }
        try run(fakeInput.path, commands.flatMap { $0.split(separator: " ").map(String.init) })
    }

    /// Types lowercase letters, digits, spaces and `.`, `/`, `-`, with one fake device.
    func type(_ text: String) throws {
        try input(text.map { "key " + (EvdevKey.codes[$0] ?? EvdevKey.codes[" "]!) })
    }

    /// The windows KWin shows, with the geometry it gave them.
    func windows() throws -> [ActionsPlaced] {
        guard let kwinLog else { return [] }
        let marker = "T" + UUID().uuidString.prefix(8)
        let script = root.appendingPathComponent("list-\(marker).js")
        try """
        for (const w of workspace.stackingOrder) { const g = w.frameGeometry;
          print("\(marker) " + JSON.stringify({caption: w.caption, cls: w.resourceClass, x: g.x, y: g.y, w: g.width, h: g.height})); }
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
            return try? JSONDecoder().decode(ActionsPlaced.self, from: Data(line[range.upperBound...].utf8))
        }
    }

    func panelWindow() throws -> ActionsPlaced? { try windows().last { $0.cls == "catflap" && $0.h > 100 } }
}

struct ActionsPlaced: Decodable {
    let caption: String
    let cls: String
    let x: Int, y: Int, w: Int, h: Int
}

/// The parts of `ui invoke describe` these tests read.
struct ActionsDescription: Decodable {
    let visible: Bool
    let mode: String
    let hasFocus: Bool
    let shortcut: String
    let sendClipboardShortcut: String
    let openedFrom: String
    let placement: Placement
    let field: String
    let rows: [String]
    let devices: [String]
    let sendLabel: String
    let page: String
    let attachments: [String]
    let message: String
    let messageActions: [String]
    let pairing: Pairing
    let settings: Settings
    let tray: String
    let controls: [Control]
    struct Placement: Decodable { let anchor: String }
    struct Control: Decodable { let role: String; let label: String }
    struct Pairing: Decodable {
        let step: String
        let state: String
        let hasCode: Bool
        let digits: String?
        let peerName: String?
        enum CodingKeys: String, CodingKey { case step, state, digits, hasCode = "has_code", peerName = "peer_name" }
    }
    struct Settings: Decodable, Equatable {
        let hoverBand: Bool
        let startAtLogin: Bool
        let receivedTextToClipboard: Bool
        let inbox: String?
        enum CodingKeys: String, CodingKey {
            case inbox
            case hoverBand = "hover_band", startAtLogin = "start_at_login", receivedTextToClipboard = "received_text_to_clipboard"
        }
    }
    enum CodingKeys: String, CodingKey {
        case visible, mode, shortcut, placement, field, rows, devices, page, attachments, message, pairing, settings, tray, controls
        case hasFocus = "has_focus", sendClipboardShortcut = "send_clipboard_shortcut", openedFrom = "opened_from"
        case sendLabel = "send_label", messageActions = "message_actions"
    }
}

/// What a `ui invoke` action answers.
struct ActionsResult: Decodable {
    struct Outcome: Decodable, Equatable { let file: String?; let status: String; let error: String? }
    let action: String
    let transfers: [TransferRecord]
    let outcomes: [Outcome]
    let attachments: [String]
    let copied: String?
    let message: String
}

/// Evdev key codes the fake keyboard sends.
enum EvdevKey {
    static let escape = "1", enter = "28", ctrl = "29", alt = "56", shift = "42", space = "57", v = "47", down = "108"
    static let codes: [Character: String] = {
        var codes: [Character: String] = [" ": "57", ".": "52", "/": "53", "-": "12"]
        for (row, start) in [("qwertyuiop", 16), ("asdfghjkl", 30), ("zxcvbnm", 44)] {
            for (offset, letter) in row.enumerated() { codes[letter] = String(start + offset) }
        }
        for (offset, digit) in "1234567890".enumerated() { codes[digit] = String(2 + offset) }
        return codes
    }()
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
