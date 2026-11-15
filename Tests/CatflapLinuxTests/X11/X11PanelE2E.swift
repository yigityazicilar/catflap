import CatflapCore
import Foundation
import XCTest

/// The panel on an X11 desktop (Xvfb + xfwm4 with focus-stealing prevention), driven with
/// real input through XTEST: what H1's grid asks of the hotkey and the hover band.
final class X11PanelE2E: XCTestCase {
    private func start(_ session: X11Session, extra: [String: String] = [:]) throws {
        try session.startDesktop()
        try session.startAgent(extra: extra)
        session.expectStatus("the agent did not choose the X11 tier") { $0.desktop == "x11" }
        XCTAssertTrue(try session.eventually { try session.state().shortcut == "bound" },
                      "the hotkey grab did not settle: \(session.show { try session.state().shortcut })")
    }

    /// Ctrl+Alt+Space from another application opens the panel at the top centre with the
    /// keyboard, kept above other windows and out of the taskbar and pager; Esc closes it and
    /// the keyboard goes back to that application.
    func testHotkeyOpensFocusedAboveAndEscCloses() throws {
        let session = try X11Session()
        try start(session)
        let other = try session.otherWindow()

        try session.xdotool("key", "ctrl+alt+space")
        XCTAssertTrue(try session.eventually { let s = try session.state(); return s.visible && s.mode == "focused" && s.hasFocus },
                      "the hotkey did not open the panel focused: \(session.show { try session.state() })")
        let panel = try XCTUnwrap(try session.eventuallyWindow("Catflap"), "no visible panel window")
        XCTAssertTrue(try session.eventually { try session.activeWindow() == panel }, "the window manager did not activate the panel")
        XCTAssertTrue(try session.eventually {
            let state = try session.property(panel, "_NET_WM_STATE")
            return ["_NET_WM_STATE_ABOVE", "_NET_WM_STATE_SKIP_TASKBAR", "_NET_WM_STATE_SKIP_PAGER"].allSatisfy(state.contains)
        }, "the window manager does not keep the panel above and out of the taskbar: \(session.show { try session.property(panel, "_NET_WM_STATE") })")
        XCTAssertTrue(try session.eventually {
            let frame = try session.geometry(panel)
            return frame.y == 0 && abs(frame.x - (X11Session.width - frame.width) / 2) <= 1
        }, "the panel is not at the top centre: \(session.show { try session.geometry(panel) })")

        try session.xdotool("key", "Escape")
        XCTAssertTrue(try session.eventually { !(try session.state().visible) }, "Esc did not close the panel")
        XCTAssertTrue(try session.eventually { try session.activeWindow() == other },
                      "the keyboard did not go back to the application in front: \(session.show { try session.activeWindow() })")
    }

    /// The pointer resting at the top centre opens the panel without the keyboard; the
    /// application in front keeps it, and the panel closes when the pointer leaves.
    func testHoverBandOpensUnfocusedAndLeavingCloses() throws {
        let session = try X11Session()
        try start(session)
        let other = try session.otherWindow()

        try session.xdotool("mousemove", "640", "400")
        try session.xdotool("mousemove", "640", "1")
        XCTAssertTrue(try session.eventually { let s = try session.state(); return s.visible && s.mode == "hover" },
                      "resting on the band did not open the panel: \(session.show { try session.state() })")
        XCTAssertFalse(try session.state().hasFocus, "the hover panel took the keyboard")
        XCTAssertEqual(try session.activeWindow(), other, "the hover panel took focus from the application in front")
        let panel = try XCTUnwrap(try session.eventuallyWindow("Catflap"), "no visible panel window")
        XCTAssertTrue(try session.eventually { try session.property(panel, "_NET_WM_STATE").contains("_NET_WM_STATE_ABOVE") },
                      "the hover panel is not kept above")

        try session.xdotool("mousemove", "640", "700")
        XCTAssertTrue(try session.eventually { !(try session.state().visible) }, "the hover panel stayed after the pointer left")
        XCTAssertEqual(try session.activeWindow(), other)
    }

    /// Num Lock and Caps Lock change the modifier state X reports; the grab covers them.
    func testHotkeyWorksWithLockKeysOn() throws {
        let session = try X11Session()
        try start(session)
        try session.otherWindow()

        try session.xdotool("key", "Num_Lock")
        try session.xdotool("key", "ctrl+alt+space")
        XCTAssertTrue(try session.eventually { try session.state().mode == "focused" }, "the hotkey did nothing with Num Lock on")
        try session.xdotool("key", "Caps_Lock")
        try session.xdotool("key", "ctrl+alt+space")
        XCTAssertTrue(try session.eventually { !(try session.state().visible) }, "the hotkey did nothing with Num Lock and Caps Lock on")
        try session.xdotool("key", "Num_Lock")
        try session.xdotool("key", "ctrl+alt+space")
        XCTAssertTrue(try session.eventually { try session.state().mode == "focused" }, "the hotkey did nothing with Caps Lock on")
        try session.xdotool("key", "Caps_Lock")
    }

    /// Another program holds Ctrl+Alt+Space: the shortcut says so instead of claiming to be
    /// set, and the send shortcut, a different combination, is still bound.
    func testGrabConflictIsReported() throws {
        let session = try X11Session()
        try session.startDesktop()
        let ready = session.root.appendingPathComponent("grabbed")
        try session.launch(try session.helperPath(), ["grab", ready.path], log: "grab")
        XCTAssertTrue(session.eventually { FileManager.default.fileExists(atPath: ready.path) }, "the helper could not grab the key")
        try session.startAgent()
        session.expectStatus("the agent did not choose the X11 tier") { $0.desktop == "x11" }
        XCTAssertTrue(try session.eventually { try session.state().shortcut == "conflict" },
                      "a key another program holds is not reported: \(session.show { try session.state().shortcut })")
        let describe = try JSONSerialization.jsonObject(with: session.catflap(["ui", "invoke", "describe"])) as? [String: Any]
        XCTAssertEqual(describe?["send_clipboard_shortcut"] as? String, "bound")
        XCTAssertNil(describe?["shortcut_trigger"] as? String, "a conflicting shortcut has a trigger")
    }

    /// A second launch's `panel.show` opens the panel focused on X11 too, and `ui state`
    /// names a list the panel could not read.
    func testPanelShowFocusesAndUnreadableListsAreReported() throws {
        let session = try X11Session()
        let fault = session.root.appendingPathComponent("lists-fault")
        try "devices\n".write(to: fault, atomically: true, encoding: .utf8)
        try start(session, extra: ["CATFLAP_TEST_LISTS_FAULT": fault.path])
        let other = try session.otherWindow()

        try session.run(session.executable.path, ["agent", "--show-if-running", "--data-dir", session.data.path])
        XCTAssertTrue(try session.eventually { let s = try session.state(); return s.visible && s.mode == "focused" && s.hasFocus },
                      "panel.show did not open the panel focused: \(session.show { try session.state() })")
        XCTAssertNotEqual(try session.activeWindow(), other)
        XCTAssertTrue(try session.eventually { try session.state().unreadable == ["devices"] },
                      "ui state does not name the unreadable list: \(session.show { try session.state().unreadable as Any })")
    }

    /// The send-clipboard shortcut pressed while the panel has the keyboard sends the newest
    /// copy and leaves the panel open with the keyboard: its key grab is not a click elsewhere.
    func testSendShortcutKeepsTheFocusedPanel() throws {
        let session = try X11Session()
        try session.startDesktop()
        try session.watchNotifications()
        try session.startAgent()
        session.expectStatus("the agent did not choose the X11 tier") { $0.desktop == "x11" }
        // Until both shortcuts are set up the panel ignores a focus loss; this needs it settled.
        XCTAssertTrue(try session.eventually { let d = try session.describe(); return d.shortcutSetup == "settled" && d.sendClipboardShortcut == "bound" },
                      "the shortcuts did not settle: \(session.show { try session.describe() })")
        try session.otherWindow()
        try session.xdotool("key", "ctrl+alt+space")
        XCTAssertTrue(try session.eventually { let s = try session.state(); return s.visible && s.mode == "focused" && s.hasFocus },
                      "the hotkey did not open the panel focused: \(session.show { try session.state() })")
        let panel = try XCTUnwrap(try session.eventuallyWindow("Catflap"), "no visible panel window")
        let focus = try session.watchFocus(panel)

        try session.xdotool("key", "ctrl+alt+shift+space")
        // What `ui state` showed, in order, while the chord went down and up and the send ran.
        var seen: [String] = []
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            let line = session.show { let s = try session.state(); return "visible \(s.visible) mode \(s.mode) has_focus \(s.hasFocus)" }
            if seen.last != line { seen.append(line) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let trace = "\nui state, in order:\n" + seen.joined(separator: "\n")
            + "\npanel window \(panel), focus events:\n" + ((try? String(contentsOf: focus, encoding: .utf8)) ?? "none")
        XCTAssertTrue(session.eventually(10) { session.notifyCalls().contains("Nothing sent") },
                      "the send shortcut did not try to send the newest copy" + trace)
        XCTAssertTrue(try session.eventually(5) { let s = try session.state(); return s.visible && s.mode == "focused" && s.hasFocus },
                      "the send shortcut closed the focused panel or took its keyboard: \(session.show { try session.state() })" + trace)
        XCTAssertFalse(seen.contains { $0.hasPrefix("visible false") }, "the panel closed for a moment" + trace)
        XCTAssertEqual(try session.activeWindow(), panel, "the panel is no longer the active window" + trace)
    }
}
