#if os(macOS)
import AppKit

/// Connects the panel's own controls to PanelActions.
///
/// The panel's view reports its buttons to an `actions` delegate and its window reports keys
/// to an `events` delegate; both point at the PanelController, which leaves Attach, Pair,
/// Settings, Retry and Reveal empty for this task. This sits between them: those five, and
/// ⌘V with files on the clipboard, come here; everything else goes on to the controller
/// unchanged.
@MainActor
final class PanelWiring: PanelViewActions, PanelWindowEvents {
    private unowned let actions: PanelActions
    private weak var view: PanelView?
    private weak var window: PanelWindow?

    init(actions: PanelActions) { self.actions = actions }

    private var controller: PanelController { actions.controller }

    /// What the panel's field holds.
    var fieldText: String { view?.field.stringValue ?? "" }

    /// Finds the panel's window and view. Returns false when the panel has none.
    func attach() -> Bool {
        for candidate in NSApplication.shared.windows {
            guard let panel = candidate as? PanelWindow, let container = panel.contentView as? FlapContainer,
                  let surface = container.surface as? PanelView else { continue }
            window = panel
            view = surface
            panel.events = self
            surface.actions = self
            return true
        }
        return false
    }

    func detach() {
        if let window, window.events === self { window.events = controller }
        if let view, view.actions === self { view.actions = controller }
    }

    // MARK: PanelWindowEvents

    func panelBecameKey() { controller.panelBecameKey() }
    func panelResignedKey() { controller.panelResignedKey() }
    func panelEscape() { controller.panelEscape() }
    func panelReturn() { controller.panelReturn() }

    func panelKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "v", actions.pasteFiles() { return true }
        if flags == .command, event.charactersIgnoringModifiers == "d" {
            actions.setDontKeep(!actions.dontKeep)
            return true
        }
        return controller.panelKeyEquivalent(event)
    }

    // MARK: PanelViewActions

    func viewFilterChanged(_ text: String) { actions.selectedRow = nil; controller.viewFilterChanged(text) }
    func viewMoveSelection(_ step: Int) { actions.selectedRow = nil; controller.viewMoveSelection(step) }
    func viewSelectRow(_ id: String?) { actions.selectedRow = id; controller.viewSelectRow(id) }
    func viewReturn() { controller.viewReturn() }
    func viewEscape() { actions.selectedRow = nil; controller.viewEscape() }
    func viewSelectList(_ list: PanelModel.List) { actions.selectedRow = nil; controller.viewSelectList(list) }

    func viewSelectDevice(_ id: String) {
        actions.chosenDevice = id
        controller.viewSelectDevice(id)
    }

    func viewSetDontKeep(_ on: Bool) {
        actions.dontKeep = on
        controller.viewSetDontKeep(on)
    }

    func viewTogglePause() { controller.viewTogglePause() }
    func viewRemoveAttachments() { controller.viewRemoveAttachments() }
    func viewSend() { controller.viewSend() }
    func viewDrag(inside: Bool) { controller.viewDrag(inside: inside) }
    func viewDrop(_ urls: [URL]) { controller.viewDrop(urls) }

    func viewAttach() { actions.openPicker() }
    func viewPair() { actions.showPairing() }
    func viewSettings() { actions.showSettings() }

    func viewRetry(_ rowID: String) {
        let (device, id) = PanelActions.split(rowID)
        Task { [actions] in
            if case .failure(let refusal) = await actions.retry(deviceID: device, id: id) {
                actions.notifier.problem(title: "Not sent", body: refusal.message)
            }
        }
    }

    func viewReveal(_ rowID: String) {
        Task { [actions] in
            if let refusal = await actions.reveal(rowID: rowID) { actions.notifier.problem(title: "Cannot show the file", body: refusal.message) }
        }
    }
}
#endif
