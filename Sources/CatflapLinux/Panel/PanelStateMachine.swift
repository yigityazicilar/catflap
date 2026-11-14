/// The panel's three states and the rules that open and close them (plan, "Panel states").
/// Pure logic: the GTK side feeds it pointer, keyboard, drag and timer events and carries out
/// the effects it returns, so the same rules hold for every `PanelHost`.
public enum PanelMode: String, Sendable, Codable {
    case hidden, hover, focused, drag
}

public struct PanelMachine: Sendable {
    public enum Timer: String, Sendable, Hashable, CaseIterable {
        /// The pointer resting on the band before a hover panel opens.
        case dwell
        /// The pointer away from the band and the panel before a hover panel closes.
        case hoverLeave
        /// A drag away from the band and the panel before a drag panel closes.
        case dragLeave

        public var milliseconds: Int {
            switch self {
            case .dwell: 200
            case .hoverLeave: 300
            case .dragLeave: 500
            }
        }
    }

    public enum Event: Sendable, Equatable {
        case bandEntered(display: String?)
        case bandLeft
        case panelEntered
        case panelLeft
        case timerFired(Timer)
        /// The hotkey or `catflap toggle`. `display` is where it should open if it is hidden.
        case hotkey(display: String?)
        case clickInside
        /// The focused panel lost keyboard focus, which on Wayland is how a click outside shows.
        case focusLost
        case escape(hasSelection: Bool)
        case dragEntered(display: String?, onPanel: Bool)
        case dragLeft(onPanel: Bool)
        case dropped
        case hide
    }

    public enum Effect: Sendable, Equatable {
        /// Show the panel in this mode, or change the mode of the panel already shown.
        case show(PanelMode, display: String?)
        case hide
        case start(Timer)
        case cancel(Timer)
        case clearSelection
    }

    public private(set) var mode: PanelMode = .hidden
    public private(set) var display: String?
    private var pointerInBand = false
    private var pointerInPanel = false
    private var dragInBand = false
    private var dragInPanel = false
    private var dwellDisplay: String?

    public init() {}

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .bandEntered(let target):
            pointerInBand = true
            switch mode {
            case .hidden:
                dwellDisplay = target
                return [.start(.dwell)]
            case .hover: return [.cancel(.hoverLeave)]
            case .focused, .drag: return []
            }
        case .bandLeft:
            pointerInBand = false
            switch mode {
            case .hidden: return [.cancel(.dwell)]
            case .hover: return pointerInPanel ? [] : [.start(.hoverLeave)]
            case .focused, .drag: return []
            }
        case .panelEntered:
            pointerInPanel = true
            // The panel covers the band, so a pointer on the panel is off the band, even if
            // the band's own leave was never delivered.
            pointerInBand = false
            return mode == .hover ? [.cancel(.hoverLeave)] : []
        case .panelLeft:
            pointerInPanel = false
            return mode == .hover && !pointerInBand ? [.start(.hoverLeave)] : []
        case .timerFired(.dwell):
            guard mode == .hidden, pointerInBand else { return [] }
            return open(.hover, on: dwellDisplay)
        case .timerFired(.hoverLeave):
            guard mode == .hover, !pointerInBand, !pointerInPanel else { return [] }
            return close()
        case .timerFired(.dragLeave):
            guard mode == .drag, !dragInBand, !dragInPanel else { return [] }
            return close()
        case .hotkey(let target):
            if mode == .focused { return close() }
            return open(.focused, on: mode == .hidden ? target : display)
        case .clickInside:
            return mode == .hover ? open(.focused, on: display) : []
        case .focusLost:
            return mode == .focused ? close() : []
        case .escape(let hasSelection):
            guard mode == .focused else { return [] }
            return hasSelection ? [.clearSelection] : close()
        case .dragEntered(let target, let onPanel):
            if onPanel { dragInPanel = true } else { dragInBand = true }
            switch mode {
            case .hidden: return open(.drag, on: target)
            case .hover: return open(.drag, on: display)
            case .drag: return [.cancel(.dragLeave)]
            case .focused: return []
            }
        case .dragLeft(let onPanel):
            if onPanel { dragInPanel = false } else { dragInBand = false }
            return mode == .drag && !dragInBand && !dragInPanel ? [.start(.dragLeave)] : []
        case .dropped:
            dragInBand = false
            dragInPanel = false
            return mode == .drag ? close() : []
        case .hide:
            return mode == .hidden ? [] : close()
        }
    }

    private mutating func open(_ next: PanelMode, on target: String?) -> [Effect] {
        mode = next
        display = target
        return Timer.allCases.map(Effect.cancel) + [.show(next, display: target)]
    }

    private mutating func close() -> [Effect] {
        mode = .hidden
        display = nil
        // The panel is gone, so the pointer and any drag are no longer over it. Whether the
        // pointer is over the band is the band's to say: it reports enter and leave itself.
        pointerInPanel = false
        dragInPanel = false
        dragInBand = false
        return Timer.allCases.map(Effect.cancel) + [.hide]
    }
}
