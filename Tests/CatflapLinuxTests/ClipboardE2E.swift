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
    private var agentProcess: Process?
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
        if agent { agentLog = log; agentProcess = child }
        return child
    }

    /// Stops the agent as logout does; it must exit 0 within the usual bound.
    func stopAgent() {
        if let agentProcess { stop(agentProcess, agent: true) }
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

    /// One item whole: `clip list` has previews, without image bodies or long texts' ends.
    func item(_ id: String) throws -> ClipboardItem {
        try ControlJSON.decoder.decode(ClipboardItem.self, from: command(["clip", "get", id]))
    }

    func waitForText(_ text: String, seconds: TimeInterval = 2) throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if try items().contains(where: { listed in try (listed.truncated ? item(listed.id) : listed).text == text }) { return true }
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

    /// A compositor of its own that offers only ext-data-control and plays `steps` to the
    /// watcher: `offer:X` (data_offer), `type:X:MIME`, `select:X`, `primary:X`, `body:X:TEXT`
    /// (what a read of X returns) and `read:X` (wait until the client asked to read X). Every
    /// event goes alone: it is flushed, and the next step waits until the client has read all of
    /// it (the socket's send queue is empty), so the watcher gets each one in a dispatch of its
    /// own. Nothing is sent before `begin()`. The log says what was sent, what the client asked
    /// to read and when it destroyed each offer: `EARLY` for an offer destroyed before a
    /// selection named it.
    func startScriptedDataControl(_ steps: [String]) throws -> (server: Process, log: URL) {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CDataControl")
        let header = root.appendingPathComponent("ext-data-control-v1-server-protocol.h")
        let scanner = try launch("/usr/bin/wayland-scanner", ["server-header", sources.appendingPathComponent("ext-data-control-v1.xml").path, header.path])
        guard wait(scanner, seconds: 30), scanner.terminationStatus == 0 else { throw ClipboardTestError.commandFailed }
        let source = root.appendingPathComponent("scripted.c")
        let program = root.appendingPathComponent("scripted")
        try Self.scriptedServer.write(to: source, atomically: true, encoding: .utf8)
        let compiler = try launch("/usr/bin/cc", [source.path, sources.appendingPathComponent("ext-data-control-v1-protocol.c").path,
                                                  "-I" + root.path, "-lwayland-server", "-o", program.path])
        guard wait(compiler, seconds: 30), compiler.terminationStatus == 0 else { throw ClipboardTestError.commandFailed }
        let log = root.appendingPathComponent("scripted-log")
        environment["WAYLAND_DISPLAY"] = "scripted"
        let server = try launch(program.path, [log.path] + steps)
        let end = Date().addingTimeInterval(10)
        while server.isRunning && Date() < end {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("scripted").path) { return (server, log) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw ClipboardTestError.startupFailed
    }

    /// Waits for a captured row with `text`. False as soon as capture is no longer active; the
    /// long bound only guards against a hang.
    func waitForCapture(_ text: String) throws -> Bool {
        let end = Date().addingTimeInterval(30)
        repeat {
            if try items().contains(where: { $0.text == text }) { return true }
            if let status = try? ControlJSON.decoder.decode(AgentStatus.self, from: command(["status"])),
               status.clipboardCapture != "active" { return false }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < end
        return false
    }

    private static let scriptedServer = """
    #include <wayland-server.h>
    #include <linux/sockios.h>
    #include <signal.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/ioctl.h>
    #include <unistd.h>
    #include "ext-data-control-v1-server-protocol.h"

    struct offer { char name; struct wl_resource *resource; const char *body; int named, replaced, received; };
    static struct wl_display *display;
    static struct wl_client *client;
    static struct wl_resource *device;
    static struct wl_event_source *timer;
    static struct wl_listener gone;
    static struct offer offers[16], *selection, *primary, *awaited;
    static int count, total, next, go;
    static char **steps;
    static FILE *out;

    static void note(const char *what, const struct offer *o, const char *detail) {
        fprintf(out, "%s %c %s\\n", what, o ? o->name : '-', detail);
        fflush(out);
    }
    static struct offer *find(char name) {
        for (int i = 0; i < count; i++) if (offers[i].name == name) return &offers[i];
        if (count == 16) abort();
        offers[count].name = name;
        return &offers[count++];
    }
    static void receive(struct wl_client *c, struct wl_resource *r, const char *mime, int32_t fd) {
        (void)c;
        struct offer *o = wl_resource_get_user_data(r);
        note("receive", o, mime);
        const char *body = o->body ? o->body : "";
        size_t left = strlen(body);
        while (left) { ssize_t n = write(fd, body, left); if (n <= 0) break; body += n; left -= (size_t)n; }
        close(fd);
        o->received++;
        if (awaited == o) awaited = NULL;
    }
    static void destroy_offer(struct wl_client *c, struct wl_resource *r) {
        (void)c;
        struct offer *o = wl_resource_get_user_data(r);
        /* The resource stays until the client goes, as events already on their way would. */
        note("destroy", o, !o->named ? "EARLY" : o->replaced ? "replaced" : o == primary ? "primary" : "current");
    }
    static const struct ext_data_control_offer_v1_interface offer_impl = { .receive = receive, .destroy = destroy_offer };
    static void offer_gone(struct wl_resource *r) { ((struct offer *)wl_resource_get_user_data(r))->resource = NULL; }
    static void destroy_resource(struct wl_client *c, struct wl_resource *r) { (void)c; wl_resource_destroy(r); }
    static void source_offer(struct wl_client *c, struct wl_resource *r, const char *mime) { (void)c; (void)r; (void)mime; }
    static const struct ext_data_control_source_v1_interface source_impl = { .offer = source_offer, .destroy = destroy_resource };
    static void set_selection(struct wl_client *c, struct wl_resource *r, struct wl_resource *source) { (void)c; (void)r; (void)source; }
    static const struct ext_data_control_device_v1_interface device_impl = {
        .set_selection = set_selection, .destroy = destroy_resource, .set_primary_selection = set_selection };
    static void device_gone(struct wl_resource *r) { if (r == device) device = NULL; }
    static int unread(void) { int n = 0; return ioctl(wl_client_get_fd(client), SIOCOUTQ, &n) < 0 ? -1 : n; }
    static int is(const char *step, size_t verb, const char *name) { return strlen(name) == verb && !strncmp(step, name, verb); }

    /* One step; 1 when it sent an event, which the client must then read on its own. */
    static int perform(const char *step) {
        const char *colon = strchr(step, ':');
        if (!colon || !colon[1]) { note("end", NULL, step); return 0; }
        size_t verb = (size_t)(colon - step);
        struct offer *o = find(colon[1]);
        const char *rest = colon[2] == ':' ? colon + 3 : "";
        if (is(step, verb, "body")) { o->body = rest; return 0; }
        if (is(step, verb, "read")) { if (!o->received) awaited = o; return 0; }
        if (is(step, verb, "offer")) {
            o->resource = wl_resource_create(client, &ext_data_control_offer_v1_interface, 1, 0);
            wl_resource_set_implementation(o->resource, &offer_impl, o, offer_gone);
            ext_data_control_device_v1_send_data_offer(device, o->resource);
        } else if (is(step, verb, "type")) {
            ext_data_control_offer_v1_send_offer(o->resource, rest);
        } else if (is(step, verb, "select")) {
            if (selection) selection->replaced = 1;
            selection = o; o->named = 1;
            ext_data_control_device_v1_send_selection(device, o->resource);
        } else if (is(step, verb, "primary")) {
            if (primary) primary->replaced = 1;
            primary = o; o->named = 1;
            ext_data_control_device_v1_send_primary_selection(device, o->resource);
        } else {
            note("unknown", o, step);
            return 0;
        }
        note("sent", o, step);
        return 1;
    }
    static int tick(void *data) {
        (void)data;
        if (!client || !device) return 0;
        wl_display_flush_clients(display);
        while (next < total && !awaited && unread() == 0) {
            int sent = perform(steps[next++]);
            wl_display_flush_clients(display);
            if (sent) break;
        }
        if (next < total || awaited) wl_event_source_timer_update(timer, 1);
        return 0;
    }
    static void start(void) {
        if (!go || !device || timer) return;
        timer = wl_event_loop_add_timer(wl_display_get_event_loop(display), tick, NULL);
        wl_event_source_timer_update(timer, 1);
    }
    static int begin(int number, void *data) { (void)number; (void)data; go = 1; start(); return 0; }
    static void client_gone(struct wl_listener *l, void *data) { (void)l; (void)data; client = NULL; device = NULL; note("gone", NULL, ""); }
    static void get_device(struct wl_client *c, struct wl_resource *r, uint32_t id, struct wl_resource *seat) {
        (void)r; (void)seat;
        struct wl_resource *created = wl_resource_create(c, &ext_data_control_device_v1_interface, 1, id);
        wl_resource_set_implementation(created, &device_impl, NULL, device_gone);
        if (client) return;
        client = c; device = created;
        gone.notify = client_gone;
        wl_client_add_destroy_listener(c, &gone);
        start();
    }
    static void create_source(struct wl_client *c, struct wl_resource *r, uint32_t id) {
        (void)r;
        struct wl_resource *source = wl_resource_create(c, &ext_data_control_source_v1_interface, 1, id);
        wl_resource_set_implementation(source, &source_impl, NULL, NULL);
    }
    static const struct ext_data_control_manager_v1_interface manager_impl = {
        .create_data_source = create_source, .get_data_device = get_device, .destroy = destroy_resource };
    static void bind_manager(struct wl_client *c, void *d, uint32_t v, uint32_t id) {
        (void)d; (void)v;
        struct wl_resource *r = wl_resource_create(c, &ext_data_control_manager_v1_interface, 1, id);
        wl_resource_set_implementation(r, &manager_impl, NULL, NULL);
    }
    static void bind_seat(struct wl_client *c, void *d, uint32_t v, uint32_t id) { (void)d; (void)v; wl_resource_create(c, &wl_seat_interface, 1, id); }
    int main(int argc, char **argv) {
        if (argc < 2 || !(out = fopen(argv[1], "a"))) return 2;
        steps = argv + 2;
        total = argc - 2;
        display = wl_display_create();
        if (!display) return 1;
        wl_event_loop_add_signal(wl_display_get_event_loop(display), SIGUSR1, begin, NULL);
        if (wl_display_add_socket(display, "scripted") < 0) return 1;
        wl_global_create(display, &wl_seat_interface, 1, NULL, bind_seat);
        wl_global_create(display, &ext_data_control_manager_v1_interface, 1, NULL, bind_manager);
        wl_display_run(display);
        wl_display_destroy(display);
        return 0;
    }
    """
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
            captured = try session.items().contains { listed in
                guard listed.kind == .image, listed.mime == "image/png" else { return false }
                return try session.item(listed.id).content == png
            }
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

/// The compositor may deliver data_offer, the MIME types and the selection in separate reads.
/// An offer the watcher has been introduced to must live until a selection names it. These run
/// everywhere: the scripted compositor is the test's own, so no nested KWin is needed.
final class ClipboardSplitDeliveryTests: XCTestCase {
    private func play(_ steps: [String], until text: String) throws -> (session: ClipboardSession, log: () -> String) {
        let session = try ClipboardSession()
        let (server, log) = try session.startScriptedDataControl(steps)
        let read = { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        try session.startAgent(expected: "active")
        kill(server.processIdentifier, SIGUSR1)
        XCTAssertTrue(try session.waitForCapture(text), "capture stopped or never saw the row; compositor log:\n" + read())
        return (session, read)
    }

    private func finish(_ session: ClipboardSession, _ log: () -> String) throws {
        let status = try ControlJSON.decoder.decode(AgentStatus.self, from: session.command(["status"]))
        XCTAssertEqual(status.clipboardCapture, "active")
        XCTAssertFalse(session.trace().contains("unknown object"))
        XCTAssertFalse(log().contains("EARLY"), log())
        session.stopAgent()
        // The watcher closed its connection on the way out.
        let end = Date().addingTimeInterval(10)
        while Date() < end && !log().contains("gone - ") { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(log().contains("gone - "), log())
    }

    func testOfferIntroducedBeforeItsSelectionIsKeptAndCaptureContinues() throws {
        let first = "split ordinary copy " + UUID().uuidString
        let last = "copy after the split ones " + UUID().uuidString
        let (session, log) = try play([
            "body:A:" + first, "offer:A", "type:A:text/plain;charset=utf-8", "type:A:text/plain", "select:A", "read:A",
            // A primary selection is not history: its offer is let go once it is named.
            "offer:P", "type:P:text/plain", "primary:P",
            "body:C:" + last, "offer:C", "type:C:text/plain;charset=utf-8", "select:C", "read:C", "end",
        ], until: last)
        XCTAssertEqual(try session.items().map(\.text), [last, first])
        let lines = log().split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("receive A ") }.count, 1)
        XCTAssertEqual(lines.filter { $0.hasPrefix("receive C ") }.count, 1)
        XCTAssertFalse(lines.contains { $0.hasPrefix("receive P ") })
        // Retired only when replaced or discarded, and before the next read.
        let receiveC = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("receive C ") })
        XCTAssertNotNil(lines[..<receiveC].firstIndex(of: "destroy A replaced"), log())
        XCTAssertNotNil(lines[..<receiveC].firstIndex(of: "destroy P primary"), log())
        try finish(session, log)
    }

    func testMarkerArrivingLastKeepsTheOfferUnread() throws {
        let marked = "marked split copy " + UUID().uuidString
        let last = "ordinary copy after the marked one " + UUID().uuidString
        let (session, log) = try play([
            "body:B:" + marked, "offer:B", "type:B:text/plain;charset=utf-8", "type:B:x-kde-passwordManagerHint", "select:B",
            "body:C:" + last, "offer:C", "type:C:text/plain;charset=utf-8", "select:C", "read:C", "end",
        ], until: last)
        // The following ordinary copy is the barrier: the watcher handles one selection at a time.
        XCTAssertEqual(try session.items().map(\.text), [last])
        let lines = log().split(separator: "\n")
        XCTAssertFalse(lines.contains { $0.hasPrefix("receive B ") }, log())
        XCTAssertEqual(lines.filter { $0.hasPrefix("receive C ") }.count, 1)
        let receiveC = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("receive C ") })
        XCTAssertNotNil(lines[..<receiveC].firstIndex(of: "destroy B replaced"), log())
        try finish(session, log)
    }
}
