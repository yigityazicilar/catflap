#if os(macOS)
import Foundation

/// The panel's states, as the plan's table names them, plus hidden.
enum PanelMode: String, Sendable {
    case hidden, hover, focused, drag
}

/// What can happen to the panel. The triggers (hover band, hotkey, menu bar item, the window
/// itself) turn what they see into these events; the rules live only here.
enum PanelEvent: Sendable, Equatable {
    /// The pointer rested on the top-edge band for the dwell time.
    case bandDwell
    /// The pointer is (or is not) inside the band, the panel or the strip between them.
    case pointerInside(Bool)
    case clickInside
    case clickOutside
    case hotkey
    /// Esc reached the panel. `selection` says whether a list row was selected.
    case escape(selection: Bool)
    /// The panel stopped being the key window (another app or window took the keyboard).
    case resignedKey
    /// A file drag reached the band.
    case dragEnteredBand
    /// A file drag is (or is not) over the band, the panel or the strip between them.
    case dragInside(Bool)
    case drop
    /// A click on the menu bar item, or a file dropped on it.
    case statusItem
    /// Close regardless of state (agent stopping, `ui invoke hide`).
    case hide
    /// A deadline set earlier may have passed.
    case tick
}

/// The open, focus and close rules of the plan's panel table:
///
/// | State   | Opens by                                    | Keyboard focus | Closes by |
/// | Hover   | pointer resting 200 ms on the top-edge band | none           | pointer outside band, panel and strip for 300 ms |
/// | Focused | the hotkey, or a click inside a hover panel | the field      | Esc, the hotkey again, a click outside |
/// | Drag    | dragging a file onto the band               | none           | the drop, or the drag leaving for 500 ms |
///
/// Time is passed in, so the rules can be checked without waiting.
struct PanelStateMachine: Sendable {
    static let dwell: Duration = .milliseconds(200)
    static let hoverGrace: TimeInterval = 0.3
    static let dragGrace: TimeInterval = 0.5

    private(set) var mode: PanelMode = .hidden
    /// When set, the panel closes at this time unless the pointer or drag comes back first.
    private(set) var closeAt: Date?

    var hasKeyboardFocus: Bool { mode == .focused }

    mutating func handle(_ event: PanelEvent, now: Date) {
        switch (mode, event) {
        case (_, .hide):
            close()

        case (.hidden, .bandDwell): open(.hover)
        case (.hidden, .hotkey), (.hidden, .statusItem): open(.focused)
        case (.hidden, .dragEnteredBand): open(.drag)
        case (.hidden, _): break

        case (.hover, .pointerInside(let inside)):
            if inside { closeAt = nil } else if closeAt == nil { closeAt = now.addingTimeInterval(Self.hoverGrace) }
        case (.hover, .clickInside), (.hover, .hotkey): open(.focused)
        case (.hover, .clickOutside), (.hover, .statusItem): close()
        case (.hover, .dragEnteredBand), (.hover, .dragInside(true)): open(.drag)
        case (.hover, .tick): closeIfDue(now)
        // Esc never reaches a panel without focus; the app in front receives it.
        case (.hover, _): break

        case (.focused, .hotkey), (.focused, .clickOutside), (.focused, .resignedKey), (.focused, .statusItem):
            close()
        case (.focused, .escape(let selection)):
            // The first Esc clears a selection; the panel closes on the next one.
            if !selection { close() }
        case (.focused, _): break

        case (.drag, .dragInside(let inside)):
            if inside { closeAt = nil } else if closeAt == nil { closeAt = now.addingTimeInterval(Self.dragGrace) }
        // The drop ends the drag. The dropped files stay attached in a focused panel, so
        // they can be sent with Return or the send button.
        case (.drag, .drop), (.drag, .hotkey), (.drag, .statusItem): open(.focused)
        case (.drag, .tick): closeIfDue(now)
        case (.drag, _): break
        }
    }

    private mutating func open(_ next: PanelMode) { mode = next; closeAt = nil }
    private mutating func close() { mode = .hidden; closeAt = nil }
    private mutating func closeIfDue(_ now: Date) {
        if let closeAt, now >= closeAt { close() }
    }
}
#endif
