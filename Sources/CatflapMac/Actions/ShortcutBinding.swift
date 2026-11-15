#if os(macOS)
import AppKit
import Carbon

/// One rebindable global shortcut. Catflap has two: the panel's (`togglePanel`) and the
/// send-clipboard one (`sendClipboard`). Each is kept in the preferences under
/// `KeyboardShortcuts_<name>`, as the JSON text of its combination, or `false` once the person
/// removed it: the keys and the form the KeyboardShortcuts package used, so earlier settings
/// apply. The default lives only in the registration domain, so only a deliberate rebinding is
/// written. A combination macOS keeps for itself, or one RegisterEventHotKey refuses, is a
/// conflict: reported in settings and `ui state`, never fatal, never claimed bound.
@MainActor
final class ShortcutBinding {
    static let panelName = "togglePanel"
    static let panelDefault = Shortcut(key: kVK_Space, modifiers: [.control, .option, .command])
    static let sendClipboardName = "sendClipboard"
    static let sendClipboardDefault = Shortcut(key: kVK_Space, modifiers: [.control, .option, .shift, .command])
    static let preferencePrefix = "KeyboardShortcuts_"

    let name: String
    let defaultValue: Shortcut
    private var onPress: (@MainActor () -> Void)?
    private var registration: HotKeyRegistrar.Registration?
    /// Why the current combination is not registered; nil when it is, or when there is none.
    private(set) var refusal: ShortcutRefusal?
    /// Set while the settings window records a shortcut, so its keys reach the recorder.
    private var suspended = false

    init(name: String, default shortcut: Shortcut) {
        self.name = name
        defaultValue = shortcut
        if let encoded = Self.encode(shortcut) {
            UserDefaults.standard.register(defaults: [Self.preferencePrefix + name: encoded])
        }
    }

    private var key: String { Self.preferencePrefix + name }

    /// Starts listening: the current combination is registered, with `action` as what it does.
    func activate(_ action: @escaping @MainActor () -> Void) {
        onPress = action
        register()
    }

    var shortcut: Shortcut? {
        guard let text = UserDefaults.standard.object(forKey: key) as? String, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    /// `bound`, `unbound` (the person removed it), `conflict` (macOS or another registration
    /// has the combination) or `unavailable` (not listening).
    var state: String {
        guard onPress != nil else { return "unavailable" }
        guard shortcut != nil else { return "unbound" }
        return refusal == nil ? "bound" : "conflict"
    }

    var keys: String { shortcut.map(Self.describe) ?? "" }

    /// Registers the stored combination. A refusal is the conflict state.
    private func register() {
        release()
        guard let onPress, !suspended else { return }
        guard let current = shortcut else { refusal = nil; return }
        switch HotKeyRegistrar.shared.register(current, action: onPress) {
        case .success(let made): registration = made; refusal = nil
        case .failure(let why): refusal = why
        }
    }

    private func release() {
        if let registration { HotKeyRegistrar.shared.unregister(registration) }
        registration = nil
    }

    /// While the settings window records a shortcut: registered no more, until `resume`.
    func suspend() {
        suspended = true
        release()
    }

    /// Registered again after `suspend`. A combination taken meanwhile is a conflict.
    func resume() {
        guard suspended else { return }
        suspended = false
        register()
    }

    /// Binds `value`; nil removes the binding. A combination macOS or another registration
    /// holds is not taken: the binding keeps the combination it had, and the answer is why.
    func rebind(_ value: Shortcut?) -> ShortcutRefusal? {
        guard let value else {
            release()
            UserDefaults.standard.set(false, forKey: key)
            refusal = nil
            return nil
        }
        if value == shortcut, registration != nil { return nil }
        guard let onPress, !suspended else {
            // Not listening: the choice is kept, and registered when listening starts.
            if HotKeyRegistrar.systemUses(value) { return .system }
            UserDefaults.standard.set(Self.encode(value), forKey: key)
            return nil
        }
        release()
        switch HotKeyRegistrar.shared.register(value, action: onPress) {
        case .success(let made):
            registration = made
            refusal = nil
            UserDefaults.standard.set(Self.encode(value), forKey: key)
            return nil
        case .failure(let why):
            // The combination it had, again; refused now, it is a conflict.
            register()
            return why
        }
    }

    func stop() {
        release()
        onPress = nil
    }

    /// The sentence for a combination that was not taken.
    static func sentence(_ refusal: ShortcutRefusal, _ shortcut: Shortcut) -> String {
        switch refusal {
        case .system:
            "macOS uses \(describe(shortcut)) for one of its own shortcuts. Choose another, or switch that one off in System Settings, Keyboard, Keyboard Shortcuts."
        case .refused:
            "macOS or another app already uses \(describe(shortcut)). Choose another."
        }
    }

    private static func encode(_ shortcut: Shortcut) -> String? {
        (try? JSONEncoder().encode(shortcut)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The shortcut as macOS writes it, for example ⌃⌥⌘Space. Written here, with no localized
    /// key names, so it never needs a resource bundle.
    static func describe(_ shortcut: Shortcut) -> String {
        let bits = shortcut.carbonModifiers
        var text = ""
        if bits & controlKey != 0 { text += "\u{2303}" }
        if bits & optionKey != 0 { text += "\u{2325}" }
        if bits & shiftKey != 0 { text += "\u{21E7}" }
        if bits & cmdKey != 0 { text += "\u{2318}" }
        if shortcut.carbonKeyCode == kVK_Space { return text + "Space" }
        if let letter = letters.first(where: { $0.value == shortcut.carbonKeyCode })?.key { return text + letter.uppercased() }
        return text + "Key \(shortcut.carbonKeyCode)"
    }

    /// Reads `ctrl+option+cmd+space`, `cmd+shift+k` and the like; `default` is the default.
    func parse(_ text: String) -> Shortcut? {
        if text.lowercased() == "default" { return defaultValue }
        var modifiers: NSEvent.ModifierFlags = []
        var key: Int?
        for part in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": modifiers.insert(.control)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd", "command": modifiers.insert(.command)
            case "space": key = kVK_Space
            default:
                guard key == nil, let letter = Self.letters[part] else { return nil }
                key = letter
            }
        }
        guard let key, !modifiers.isEmpty else { return nil }
        return Shortcut(key: key, modifiers: modifiers)
    }

    private static let letters: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
    ]
}
#endif
