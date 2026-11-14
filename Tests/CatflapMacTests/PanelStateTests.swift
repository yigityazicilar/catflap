#if os(macOS)
@testable import CatflapMac
import Foundation
import Testing

/// The panel table's open, focus and close rules, and the Design brief's keyboard rules,
/// checked with explicit time instead of waiting.
struct PanelStateTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func testHoverOpensWithoutFocusAndClosesOnlyAfterThePointerStaysOut() {
        var machine = PanelStateMachine()
        machine.handle(.bandDwell, now: at(0))
        #expect(machine.mode == .hover)
        #expect(!machine.hasKeyboardFocus)
        machine.handle(.pointerInside(false), now: at(1))
        machine.handle(.tick, now: at(1.299))
        #expect(machine.mode == .hover, "the pointer has 300 ms to come back")
        machine.handle(.pointerInside(true), now: at(1.2))
        machine.handle(.tick, now: at(1.6))
        #expect(machine.mode == .hover, "coming back cancels the close")
        machine.handle(.pointerInside(false), now: at(2))
        machine.handle(.pointerInside(false), now: at(2.2))
        machine.handle(.tick, now: at(2.3))
        #expect(machine.mode == .hidden, "300 ms after the pointer first left")
    }

    @Test func testHoverPanelBecomesFocusedByClickOrHotkeyAndIgnoresEscape() {
        var machine = PanelStateMachine()
        machine.handle(.bandDwell, now: at(0))
        machine.handle(.escape(selection: false), now: at(0.1))
        #expect(machine.mode == .hover, "Esc goes to the app in front")
        machine.handle(.clickInside, now: at(0.2))
        #expect(machine.mode == .focused)
        #expect(machine.hasKeyboardFocus)

        var second = PanelStateMachine()
        second.handle(.bandDwell, now: at(0))
        second.handle(.hotkey, now: at(0.1))
        #expect(second.mode == .focused)

        var third = PanelStateMachine()
        third.handle(.bandDwell, now: at(0))
        third.handle(.clickOutside, now: at(0.1))
        #expect(third.mode == .hidden)
    }

    @Test func testFocusedPanelClosesByEscapeHotkeyAndClickOutsideOnly() {
        var machine = PanelStateMachine()
        machine.handle(.hotkey, now: at(0))
        #expect(machine.mode == .focused)
        machine.handle(.pointerInside(false), now: at(0.1))
        machine.handle(.tick, now: at(5))
        #expect(machine.mode == .focused, "a focused panel stays when the pointer leaves")
        machine.handle(.escape(selection: true), now: at(5.1))
        #expect(machine.mode == .focused, "the first Esc only clears the selection")
        machine.handle(.escape(selection: false), now: at(5.2))
        #expect(machine.mode == .hidden)

        for closing in [PanelEvent.hotkey, .clickOutside, .resignedKey] {
            var panel = PanelStateMachine()
            panel.handle(.hotkey, now: at(0))
            panel.handle(closing, now: at(0.1))
            #expect(panel.mode == .hidden, "\(closing) closes a focused panel")
        }
    }

    @Test func testDragOpensWithoutFocusClosesAfterLeavingAndDropKeepsTheFile() {
        var machine = PanelStateMachine()
        machine.handle(.dragEnteredBand, now: at(0))
        #expect(machine.mode == .drag)
        #expect(!machine.hasKeyboardFocus)
        machine.handle(.dragInside(false), now: at(1))
        machine.handle(.tick, now: at(1.49))
        #expect(machine.mode == .drag, "the drag has 500 ms to come back")
        machine.handle(.dragInside(true), now: at(1.3))
        machine.handle(.tick, now: at(2))
        #expect(machine.mode == .drag)
        machine.handle(.dragInside(false), now: at(3))
        machine.handle(.tick, now: at(3.5))
        #expect(machine.mode == .hidden)

        var dropped = PanelStateMachine()
        dropped.handle(.dragEnteredBand, now: at(0))
        dropped.handle(.drop, now: at(0.4))
        #expect(dropped.mode == .focused, "the drop ends the drag; the file is sent from a focused panel")
    }

    @Test func testHiddenPanelOpensOnlyByItsTriggers() {
        for (event, mode) in [(PanelEvent.bandDwell, PanelMode.hover), (.hotkey, .focused), (.dragEnteredBand, .drag), (.statusItem, .focused)] {
            var machine = PanelStateMachine()
            machine.handle(event, now: at(0))
            #expect(machine.mode == mode)
        }
        for event in [PanelEvent.pointerInside(true), .clickInside, .clickOutside, .escape(selection: false), .resignedKey, .drop, .tick] {
            var machine = PanelStateMachine()
            machine.handle(event, now: at(0))
            #expect(machine.mode == .hidden)
        }
    }

    private func sampleModel() -> PanelModel {
        var model = PanelModel()
        let rows = ["meeting notes for Thursday", "grocery list", "meeting room link"].enumerated().map { index, text in
            PanelRow(id: "c\(index)", kind: .text, title: text, detail: nil, timestamp: start, status: nil,
                     payloadName: text, canRetry: false, canReveal: false)
        }
        model.update(devices: [PanelDevice(id: "d1", name: "studio-mac", reach: .unknown),
                               PanelDevice(id: "d2", name: "linux-desk", reach: .unknown)],
                     clipboard: rows, history: [], paused: false)
        return model
    }

    @Test func testTypingFiltersAndNeverSelectsArrowsSelect() {
        var model = sampleModel()
        model.moveSelection(by: 1)
        #expect(model.selectedRow?.id == "c0")
        model.setFilter("meeting")
        #expect(model.selectedRow == nil, "typing never selects a row")
        #expect(model.rows.map(\.id) == ["c0", "c2"])
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        #expect(model.selectedRow?.id == "c2")
        model.moveSelection(by: 5)
        #expect(model.selectedRow?.id == "c2")
        model.moveSelection(by: -2)
        #expect(model.selectedRow == nil, "up from the first row returns to the field")
    }

    @Test func testReturnSendsTheSelectedRowElseTheFieldText() {
        var model = sampleModel()
        #expect(model.payload == nil)
        #expect(model.sendLabel() == "Type something to send")
        model.setFilter("grocery")
        #expect(model.payload == .text("grocery"))
        model.moveSelection(by: 1)
        #expect(model.payload == .row(model.rows[0]))
        #expect(model.sendLabel() == "Send \u{201C}grocery list\u{201D} to studio-mac")
        model.selectTarget("d2")
        #expect(model.sendLabel() == "Send \u{201C}grocery list\u{201D} to linux-desk")
    }

    @Test func testEscapeClearsTheSelectionBeforeClosing() {
        var model = sampleModel()
        model.moveSelection(by: 1)
        let firstCloses = model.escape()
        #expect(!firstCloses)
        #expect(model.selectedRow == nil)
        let secondCloses = model.escape()
        #expect(secondCloses)
    }

    @Test func testSendLabelShortensThePayloadInTheMiddleAndNeverTheDevice() {
        var model = sampleModel()
        model.setFilter(String(repeating: "a", count: 40) + "middle" + String(repeating: "z", count: 40))
        let label = model.sendLabel { $0.count <= 50 }
        #expect(label.count <= 50)
        #expect(label.hasSuffix("\u{201D} to studio-mac"))
        #expect(label.hasPrefix("Send \u{201C}aaa"))
        #expect(label.contains("\u{2026}"))
        #expect(label.contains("zzz\u{201D}"))
        var nothing = PanelModel()
        nothing.setFilter("hello")
        #expect(nothing.sendLabel() == "Pair a device to send")
        #expect(!nothing.canSend)
    }
}
#endif
