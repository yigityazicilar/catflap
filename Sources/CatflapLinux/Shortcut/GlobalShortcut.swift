import CGtkShim

/// The hotkey through the desktop's GlobalShortcuts portal. The system owns the binding: it
/// may ask the person to confirm it, and they can change the trigger in the system's shortcut
/// settings or through `configure()`; the new trigger arrives as a change.
final class GlobalShortcut {
    static let applicationID = "io.github.yigityazicilar.Catflap"
    static let shortcutID = "toggle-panel"
    static let preferredTrigger = "CTRL+ALT+space"
    static let bindHint = "This session cannot register global shortcuts. Bind catflap toggle to show or hide the panel, and catflap clip send --latest to send the newest copy, in your compositor's shortcut settings."

    /// `pending`, `bound`, `unbound`, `declined` (person refused) or `unavailable`.
    private(set) var state = "pending"
    /// The trigger as the system describes it, once bound.
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
        client = cf_shortcuts_new(Self.applicationID, Self.shortcutID, "Show or hide Catflap", Self.preferredTrigger,
                                  GLib.handler, context, GLib.release)
    }

    // Kept separate from delivery so terminal portal responses can be exercised without GTK.
    func update(portalState: String, portalDetail: String?) {
        // A backend error is not the person's refusal. Keep the portal's established
        // cancellation spelling (declined) for existing callers, including KDE.
        state = portalState == "failed" ? "unavailable" : portalState
        if state == "bound" {
            trigger = portalDetail
            detail = nil
        } else if state == "unavailable" {
            detail = Self.bindHint
        } else {
            detail = portalDetail
        }
        if state != "bound" && state != "pending" { trigger = nil }
        WlrootsFocus.shortcutState(Self.shortcutID, state)
    }

    /// Opens the system's dialog for changing the trigger. False if the portal has none.
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
