import CGtkShim

/// The send-clipboard shortcut, Ctrl+Alt+Shift+Space, through the desktop's GlobalShortcuts
/// portal like the panel's hotkey, in a portal session of its own. The system owns the
/// binding: it may ask the person to confirm it, and they can change it there.
final class SendClipboardShortcut {
    static let shortcutID = "send-clipboard"
    static let preferredTrigger = "CTRL+ALT+SHIFT+space"

    /// `pending`, `bound`, `unbound`, `declined` (person refused) or `unavailable`.
    private(set) var state = "pending"
    private(set) var trigger: String?
    private(set) var detail: String?
    private var client: OpaquePointer?

    func start(onChange: @escaping () -> Void, onActivated: @escaping () -> Void) {
        WlrootsFocus.shortcutState(Self.shortcutID, "pending")
        let context = GLib.retained { [weak self] event in
            guard let self else { return }
            if event.pointee.n == Int32(CF_SHORTCUT_ACTIVATED) {
                onActivated()
                return
            }
            update(portalState: event.pointee.text.map { String(cString: $0) } ?? "failed",
                   portalDetail: event.pointee.detail.map { String(cString: $0) })
            onChange()
        }
        client = cf_shortcuts_new(GlobalShortcut.applicationID, Self.shortcutID, "Send the newest copy with Catflap",
                                  Self.preferredTrigger, GLib.handler, context, GLib.release)
    }

    func update(portalState: String, portalDetail: String?) {
        state = portalState == "failed" ? "unavailable" : portalState
        trigger = state == "bound" ? portalDetail : nil
        detail = state == "unavailable" ? GlobalShortcut.bindHint : state == "bound" ? nil : portalDetail
        WlrootsFocus.shortcutState(Self.shortcutID, state)
    }

    func configure() -> Bool {
        guard let client else { return false }
        return cf_shortcuts_configure(client) != 0
    }

    func stop() {
        WlrootsFocus.shortcutState(Self.shortcutID, "stopped")
        if let client { cf_shortcuts_free(client) }
        client = nil
    }
}
