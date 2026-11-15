import CatflapCore
import Foundation
import XCTest

/// The desktop tier comes from what the session offers: an X display alone gives the X11
/// tier, while a Wayland session that also offers an X display (XWayland) never uses it.
final class X11BackendChoiceE2E: XCTestCase {
    func testXDisplayAloneGivesTheX11Tier() throws {
        let session = try X11Session()
        try session.startDesktop()
        try session.startAgent()
        session.expectStatus("an X display alone did not give the X11 tier") { $0.desktop == "x11" && $0.clipboardCapture == "active" }
    }

    /// A Wayland display without layer-shell or data-control, and a working X display beside
    /// it: Catflap shows no panel, watches no clipboard and grabs no key on the X display.
    func testXDisplayInheritedUnderWaylandIsNotUsed() throws {
        let session = try X11Session()
        try session.startDesktop()
        let source = session.root.appendingPathComponent("wayland.c")
        let program = session.root.appendingPathComponent("wayland")
        try """
        #include <wayland-server-core.h>
        int main(void) {
            struct wl_display *d = wl_display_create();
            if (!d || wl_display_add_socket(d, "bare-wayland") < 0) return 1;
            wl_display_run(d);
            wl_display_destroy(d);
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        try session.run("/usr/bin/cc", [source.path, "-lwayland-server", "-o", program.path], seconds: 60)
        let server = try session.launch(program.path, [], log: "wayland")
        XCTAssertTrue(session.eventually { server.isRunning && FileManager.default.fileExists(atPath: session.root.appendingPathComponent("bare-wayland").path) })
        session.environment["WAYLAND_DISPLAY"] = "bare-wayland"

        try session.startAgent()
        // The clipboard watcher has reported before the agent answers its first status; the
        // panel's start runs beside it, so the X side is checked after a grab of its own.
        XCTAssertEqual(try session.status().clipboardCapture, "unsupported")
        let ready = session.root.appendingPathComponent("grabbed")
        let grab = try session.launch(try session.helperPath(), ["grab", ready.path], log: "grab")
        XCTAssertTrue(session.eventually { FileManager.default.fileExists(atPath: ready.path) || !grab.isRunning })
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "Catflap holds the hotkey on the inherited X display")
        XCTAssertNil(try session.window(named: "Catflap"), "a panel window appeared on the inherited X display")
        let status = try session.status()
        XCTAssertEqual(status.desktop, "unsupported")
        XCTAssertEqual(status.clipboardCapture, "unsupported")
    }
}
