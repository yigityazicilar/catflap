@testable import CatflapLinux
import XCTest

/// The plan's panel-state table, rule by rule, without a compositor.
final class PanelMachineTests: XCTestCase {
    private func shows(_ effects: [PanelMachine.Effect]) -> PanelMode? {
        for case .show(let mode, _) in effects { return mode }
        return nil
    }

    func testTimersHaveThePlannedDurations() {
        XCTAssertEqual(PanelMachine.Timer.dwell.milliseconds, 200)
        XCTAssertEqual(PanelMachine.Timer.hoverLeave.milliseconds, 300)
        XCTAssertEqual(PanelMachine.Timer.dragLeave.milliseconds, 500)
    }

    func testHoverOpensAfterTheDwellWithoutFocus() {
        var machine = PanelMachine()
        XCTAssertEqual(machine.handle(.bandEntered(display: "A")), [.start(.dwell)])
        XCTAssertEqual(machine.mode, .hidden)
        let effects = machine.handle(.timerFired(.dwell))
        XCTAssertEqual(shows(effects), .hover)
        XCTAssertTrue(effects.contains(.show(.hover, display: "A")))
        XCTAssertEqual(machine.display, "A")
    }

    func testPassingOverTheBandOpensNothing() {
        var machine = PanelMachine()
        _ = machine.handle(.bandEntered(display: "A"))
        XCTAssertEqual(machine.handle(.bandLeft), [.cancel(.dwell)])
        XCTAssertEqual(machine.handle(.timerFired(.dwell)), [])
        XCTAssertEqual(machine.mode, .hidden)
    }

    func testHoverClosesOnlyAfterLeavingBandAndPanel() {
        var machine = PanelMachine()
        _ = machine.handle(.bandEntered(display: "A"))
        _ = machine.handle(.timerFired(.dwell))
        // From the band into the panel: no close is scheduled while the pointer is on either.
        XCTAssertEqual(machine.handle(.panelEntered), [.cancel(.hoverLeave)])
        XCTAssertEqual(machine.handle(.bandLeft), [])
        XCTAssertEqual(machine.handle(.panelLeft), [.start(.hoverLeave)])
        // Back within 300 ms: stays.
        XCTAssertEqual(machine.handle(.panelEntered), [.cancel(.hoverLeave)])
        _ = machine.handle(.panelLeft)
        XCTAssertEqual(machine.handle(.timerFired(.hoverLeave)).last, .hide)
        XCTAssertEqual(machine.mode, .hidden)
    }

    func testClickInsideHoverFocuses() {
        var machine = PanelMachine()
        _ = machine.handle(.bandEntered(display: "B"))
        _ = machine.handle(.timerFired(.dwell))
        let effects = machine.handle(.clickInside)
        XCTAssertTrue(effects.contains(.show(.focused, display: "B")))
        XCTAssertEqual(machine.mode, .focused)
        // Leaving no longer closes it.
        XCTAssertEqual(machine.handle(.panelLeft), [])
        XCTAssertEqual(machine.handle(.bandLeft), [])
        XCTAssertEqual(machine.handle(.timerFired(.hoverLeave)), [])
        XCTAssertEqual(machine.mode, .focused)
    }

    func testFocusedClosesByEscapeHotkeyOrClickOutside() {
        for close in [PanelMachine.Event.escape(hasSelection: false), .hotkey(display: nil), .focusLost] {
            var machine = PanelMachine()
            XCTAssertEqual(shows(machine.handle(.hotkey(display: nil))), .focused)
            XCTAssertEqual(machine.handle(close).last, .hide, "\(close)")
            XCTAssertEqual(machine.mode, .hidden)
        }
    }

    func testEscapeClearsTheSelectionFirst() {
        var machine = PanelMachine()
        _ = machine.handle(.hotkey(display: nil))
        XCTAssertEqual(machine.handle(.escape(hasSelection: true)), [.clearSelection])
        XCTAssertEqual(machine.mode, .focused)
        XCTAssertEqual(machine.handle(.escape(hasSelection: false)).last, .hide)
    }

    func testHoverHasNoKeyboardSoEscapeAndFocusLossDoNothing() {
        var machine = PanelMachine()
        _ = machine.handle(.bandEntered(display: nil))
        _ = machine.handle(.timerFired(.dwell))
        XCTAssertEqual(machine.handle(.escape(hasSelection: false)), [])
        XCTAssertEqual(machine.handle(.focusLost), [])
        XCTAssertEqual(machine.mode, .hover)
    }

    func testHotkeyOverHoverFocusesOnTheSameDisplay() {
        var machine = PanelMachine()
        _ = machine.handle(.bandEntered(display: "B"))
        _ = machine.handle(.timerFired(.dwell))
        XCTAssertTrue(machine.handle(.hotkey(display: "A")).contains(.show(.focused, display: "B")))
    }

    func testDragOpensAtOnceAndClosesOnDropOrAfterLeaving() {
        var machine = PanelMachine()
        let effects = machine.handle(.dragEntered(display: "A", onPanel: false))
        XCTAssertTrue(effects.contains(.show(.drag, display: "A")))
        XCTAssertEqual(machine.mode, .drag)
        // From the band onto the panel and off the band: still open.
        XCTAssertEqual(machine.handle(.dragEntered(display: "A", onPanel: true)), [.cancel(.dragLeave)])
        XCTAssertEqual(machine.handle(.dragLeft(onPanel: false)), [])
        XCTAssertEqual(machine.handle(.dragLeft(onPanel: true)), [.start(.dragLeave)])
        XCTAssertEqual(machine.handle(.dragEntered(display: "A", onPanel: true)), [.cancel(.dragLeave)])
        XCTAssertEqual(machine.handle(.dropped).last, .hide)

        var leaving = PanelMachine()
        _ = leaving.handle(.dragEntered(display: nil, onPanel: false))
        _ = leaving.handle(.dragLeft(onPanel: false))
        XCTAssertEqual(leaving.handle(.timerFired(.dragLeave)).last, .hide)
    }

    func testDragOntoAFocusedPanelKeepsItFocused() {
        var machine = PanelMachine()
        _ = machine.handle(.hotkey(display: nil))
        XCTAssertEqual(machine.handle(.dragEntered(display: nil, onPanel: true)), [])
        XCTAssertEqual(machine.handle(.dropped), [])
        XCTAssertEqual(machine.mode, .focused)
    }

    func testAStaleTimerChangesNothing() {
        var machine = PanelMachine()
        _ = machine.handle(.hotkey(display: nil))
        XCTAssertEqual(machine.handle(.timerFired(.dwell)), [])
        XCTAssertEqual(machine.handle(.timerFired(.dragLeave)), [])
        XCTAssertEqual(machine.mode, .focused)
    }
}

/// What Return sends and what the send button says (design brief, review U2).
final class PanelTextTests: XCTestCase {
    private let row = PanelRow(id: "1", source: .clipboard, title: "meeting notes for Thursday", subtitle: "Text, 26 bytes")
    private let device = PanelDevice(id: "d", name: "the Mac")

    func testReturnSendsTheSelectedRowOtherwiseTheText() {
        XCTAssertEqual(PanelText.returnPayload(selected: row, text: "typed"), .row(row))
        XCTAssertEqual(PanelText.returnPayload(selected: nil, text: "typed"), .text("typed"))
        XCTAssertNil(PanelText.returnPayload(selected: nil, text: "  \n"))
    }

    func testSendButtonNamesPayloadAndDevice() {
        XCTAssertEqual(PanelText.sendLabel(.text("meeting notes"), device: device), "Send \"meeting notes\" to the Mac")
        XCTAssertEqual(PanelText.sendLabel(.row(row), device: device), "Send \"meeting notes for Th…\" to the Mac")
        XCTAssertEqual(PanelText.sendLabel(.files(["a.pdf", "b.pdf"]), device: device), "Send 2 files to the Mac")
        XCTAssertEqual(PanelText.sendLabel(nil, device: device), "Send to the Mac")
        XCTAssertEqual(PanelText.sendLabel(.text("x"), device: nil), "Pair a device to send")
    }

    func testFilteringMatchesWithoutSelecting() {
        let other = PanelRow(id: "2", source: .clipboard, title: "shopping list", subtitle: "Text, 13 bytes")
        XCTAssertEqual(PanelText.filter([row, other], by: "NOTES"), [row])
        XCTAssertEqual(PanelText.filter([row, other], by: " "), [row, other])
    }
}
