import CatflapCore
import Foundation
import XCTest

/// Clipboard capture on an X11 desktop, with the panel off: the watcher works on its own.
final class X11ClipboardE2E: XCTestCase {
    private func start(_ session: X11Session) throws {
        try session.startDesktop(windowManager: false)
        try session.startAgent(extra: ["CATFLAP_PANEL": "off"])
        session.expectStatus("the agent does not watch the X clipboard") { $0.clipboardCapture == "active" }
    }

    private func copy(_ session: X11Session, _ text: String) throws {
        let input = session.root.appendingPathComponent("copy-" + UUID().uuidString)
        try Data(text.utf8).write(to: input)
        try session.launch("/usr/bin/xclip", ["-quiet", "-selection", "clipboard", "-target", "UTF8_STRING"], input: input)
    }

    private func captured(_ session: X11Session, _ text: String) throws -> Bool {
        try session.eventually { try session.items().contains { $0.text == text } }
    }

    /// A copy made in another application while Catflap has no window at all is recorded.
    func testCopyIsCaptured() throws {
        let session = try X11Session()
        try start(session)
        try copy(session, "an ordinary x11 copy")
        XCTAssertTrue(try captured(session, "an ordinary x11 copy"), "the copy was not recorded")
        try copy(session, "a second x11 copy")
        XCTAssertTrue(try captured(session, "a second x11 copy"), "a later copy was not recorded")
    }

    /// A copy offered beside the password-manager marker is never read: the owner is asked
    /// for its list of targets and nothing else, and nothing is recorded. A later ordinary
    /// copy is, so the watcher went past the marked one rather than stopping.
    func testMarkedCopyIsNotRead() throws {
        let session = try X11Session()
        try start(session)
        let log = session.root.appendingPathComponent("owner-log")
        try session.launch(try session.helperPath(),
                           ["owner", log.path, "marked x11 secret", "UTF8_STRING", "text/plain;charset=utf-8", "x-kde-passwordManagerHint"],
                           log: "owner")
        XCTAssertTrue(session.eventually {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).contains("TARGETS")
        }, "the watcher never asked the marked copy's owner for its targets")

        try copy(session, "after the marked copy")
        XCTAssertTrue(try captured(session, "after the marked copy"), "capture stopped after the marked copy")
        let requests = try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(requests.filter { $0 != "owner" && $0 != "cleared" }, ["TARGETS"],
                       "the marked copy's owner was asked for more than its targets")
        XCTAssertFalse(try session.items().contains { $0.text == "marked x11 secret" }, "the marked copy was recorded")
    }
}
