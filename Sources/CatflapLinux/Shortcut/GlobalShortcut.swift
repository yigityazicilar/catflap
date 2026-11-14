import CGtkShim

/// The hotkey through the desktop's GlobalShortcuts portal. The system owns the binding: it
/// may ask the person to confirm it, and they can change the trigger in the system's shortcut
/// settings or through `configure()`; the new trigger arrives as a change.
final class GlobalShortcut {
    static let applicationID = "io.github.yigityazicilar.Catflap"
    static let shortcutID = "toggle-panel"
    static let preferredTrigger = "CTRL+ALT+space"

    /// `pending`, `bound`, `unbound`, `declined`, `unavailable` or `failed`.
    private(set) var state = "pending"
    /// The trigger as the system describes it, once bound.
    private(set) var trigger: String?
    private(set) var detail: String?
    private var client: OpaquePointer?

    func start(onChange: @escaping () -> Void, onActivated: @escaping () -> Void) {
        let context = GLib.retained { [weak self] event in
            guard let self else { return }
            if event.pointee.n == Int32(CF_SHORTCUT_ACTIVATED) {
                onActivated()
                return
            }
            state = event.pointee.text.map { String(cString: $0) } ?? "failed"
            let text = event.pointee.detail.map { String(cString: $0) }
            if state == "bound" { trigger = text; detail = nil } else { detail = text }
            if state != "bound" && state != "pending" { trigger = nil }
            onChange()
        }
        client = cf_shortcuts_new(Self.applicationID, Self.shortcutID, "Show or hide Catflap", Self.preferredTrigger,
                                  GLib.handler, context, GLib.release)
    }

    /// Opens the system's dialog for changing the trigger. False if the portal has none.
    func configure() -> Bool {
        guard let client else { return false }
        return cf_shortcuts_configure(client) != 0
    }

    func stop() {
        if let client { cf_shortcuts_free(client) }
        client = nil
    }
}
