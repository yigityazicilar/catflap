@testable import CatflapLinux
import XCTest

/// Which display the panel may use, from the environment the agent was given.
final class X11DesktopSessionTests: XCTestCase {
    func testWaylandDisplayGivesAPanelDisplayAndNeverX11() {
        let environment = ["WAYLAND_DISPLAY": "wayland-1", "DISPLAY": ":0"]
        XCTAssertTrue(DesktopSession.hasPanelDisplay(environment))
        XCTAssertEqual(DesktopSession.of(environment), .wayland)
        XCTAssertEqual(DesktopSession.of(environment).gdkBackends, "wayland")
    }

    func testXDisplayAloneGivesAPanelDisplayOnX11() {
        let environment = ["DISPLAY": ":0"]
        XCTAssertTrue(DesktopSession.hasPanelDisplay(environment))
        XCTAssertEqual(DesktopSession.of(environment), .x11)
        XCTAssertEqual(DesktopSession.of(environment).gdkBackends, "x11")
    }

    func testNeitherDisplayGivesNoPanelDisplay() {
        XCTAssertFalse(DesktopSession.hasPanelDisplay([:]))
        XCTAssertFalse(DesktopSession.hasPanelDisplay(["WAYLAND_DISPLAY": "", "DISPLAY": ""]))
        XCTAssertEqual(DesktopSession.of([:]), .none)
    }

    /// A Wayland socket handed over without a display name is still a Wayland session, so the
    /// X display beside it is not used, and the panel, which needs a named display, stays off
    /// as before.
    func testWaylandSocketAloneKeepsX11Out() {
        let environment = ["WAYLAND_SOCKET": "3", "DISPLAY": ":0"]
        XCTAssertEqual(DesktopSession.of(environment), .wayland)
        XCTAssertFalse(DesktopSession.hasPanelDisplay(environment))
    }
}
