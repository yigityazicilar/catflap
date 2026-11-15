@testable import CatflapLinux
import XCTest

final class WlrootsShortcutTests: XCTestCase {
    func testSendShortcutFallbackAndBoundRecovery() {
        let shortcut = SendClipboardShortcut()
        for state in ["unavailable", "failed"] {
            shortcut.update(portalState: state, portalDetail: "Backend error")
            XCTAssertEqual(shortcut.state, "unavailable")
            XCTAssertTrue(shortcut.detail?.contains("catflap toggle") == true)
            XCTAssertTrue(shortcut.detail?.contains("catflap clip send --latest") == true)
            XCTAssertNil(shortcut.trigger)
        }
        shortcut.update(portalState: "declined", portalDetail: nil)
        XCTAssertEqual(shortcut.state, "declined")
        XCTAssertNil(shortcut.detail)
        shortcut.update(portalState: "bound", portalDetail: "Ctrl+Alt+Shift+Space")
        XCTAssertEqual(shortcut.trigger, "Ctrl+Alt+Shift+Space")
        XCTAssertNil(shortcut.detail)
    }

    func testMissingPortalHasExactBindHints() {
        let shortcut = GlobalShortcut()
        shortcut.update(portalState: "unavailable", portalDetail: "No interface")
        XCTAssertEqual(shortcut.state, "unavailable")
        XCTAssertTrue(shortcut.detail?.contains("catflap toggle") == true)
        XCTAssertTrue(shortcut.detail?.contains("catflap clip send --latest") == true)
        XCTAssertNil(shortcut.trigger)
    }

    func testBackendErrorIsUnavailableNotPersonRefusal() {
        let shortcut = GlobalShortcut()
        shortcut.update(portalState: "failed", portalDetail: "Backend error")
        XCTAssertEqual(shortcut.state, "unavailable")
        XCTAssertTrue(shortcut.detail?.contains("catflap toggle") == true)
        XCTAssertTrue(shortcut.detail?.contains("catflap clip send --latest") == true)
        // The established portal cancellation state is deliberately preserved for KDE callers.
        shortcut.update(portalState: "declined", portalDetail: nil)
        XCTAssertEqual(shortcut.state, "declined")
        XCTAssertNil(shortcut.detail)
    }

    func testBoundTriggerClearsUnavailableHint() {
        let shortcut = GlobalShortcut()
        shortcut.update(portalState: "unavailable", portalDetail: nil)
        XCTAssertNotNil(shortcut.detail)
        shortcut.update(portalState: "bound", portalDetail: "Ctrl+Alt+Space")
        XCTAssertEqual(shortcut.state, "bound")
        XCTAssertEqual(shortcut.trigger, "Ctrl+Alt+Space")
        XCTAssertNil(shortcut.detail)
    }
}
