#if os(macOS)
import AppKit
import Carbon
import KeyboardShortcuts

/// One rebindable global shortcut, through KeyboardShortcuts. Catflap has two: the panel's
/// (`togglePanel`, registered by the panel itself) and the send-clipboard one
/// (`sendClipboard`, Ctrl+Option+Shift+Space, registered here).
@MainActor
final class ShortcutBinding {
    static let panelName = "togglePanel"
    static let panelDefault = KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .option])
    static let sendClipboardName = "sendClipboard"
    static let sendClipboardDefault = KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .option, .shift])

    let name: KeyboardShortcuts.Name
    let defaultValue: KeyboardShortcuts.Shortcut
    private var handled = false
    /// The system's answer the last time this binding was offered to it; 0 means accepted.
    private var refusal: OSStatus = 0

    /// A binding whose handler someone else registers (the panel's).
    init(existing value: String, default shortcut: KeyboardShortcuts.Shortcut) {
        name = KeyboardShortcuts.Name(value)
        defaultValue = shortcut
    }

    /// A binding with a default and a handler of its own.
    init(name value: String, default shortcut: KeyboardShortcuts.Shortcut, onPress: @escaping @MainActor () -> Void) {
        defaultValue = shortcut
        // The default goes into the registration domain, which lives only in memory, so only a
        // deliberate rebinding is ever written to the person's preferences.
        if let data = try? JSONEncoder().encode(shortcut), let encoded = String(data: data, encoding: .utf8) {
            UserDefaults.standard.register(defaults: ["KeyboardShortcuts_" + value: encoded])
        }
        name = KeyboardShortcuts.Name(value, default: shortcut)
        // Asked before KeyboardShortcuts registers it, so a combination another app holds is
        // reported instead of silently not firing.
        if let current = KeyboardShortcuts.getShortcut(for: name) { refusal = Self.probe(current) }
        KeyboardShortcuts.onKeyDown(for: name) { MainActor.assumeIsolated { onPress() } }
        handled = true
    }

    var shortcut: KeyboardShortcuts.Shortcut? { KeyboardShortcuts.getShortcut(for: name) }

    /// `bound`, `unbound` (removed by the person) or `conflict` (refused by the system).
    var state: String {
        guard shortcut != nil else { return "unbound" }
        return refusal == 0 ? "bound" : "conflict"
    }

    var keys: String { shortcut.map(Self.describe) ?? "" }

    /// Binds `value`; nil removes the binding. A combination the system refuses is not taken,
    /// and the answer is false.
    func rebind(_ value: KeyboardShortcuts.Shortcut?) -> Bool {
        guard let value else {
            KeyboardShortcuts.setShortcut(nil, for: name)
            refusal = 0
            return true
        }
        if value == shortcut { return true }
        // Unregister the current one first, so the probe does not meet Catflap's own binding.
        let hadOne = shortcut != nil
        if hadOne { KeyboardShortcuts.disable([name]) }
        let answer = Self.probe(value)
        guard answer == 0 else {
            if hadOne { KeyboardShortcuts.enable([name]) }
            return false
        }
        KeyboardShortcuts.setShortcut(value, for: name)
        refusal = 0
        return true
    }

    func stop() {
        if handled { KeyboardShortcuts.removeHandler(for: name) }
    }

    /// The shortcut as macOS writes it, for example ⌃⌥Space. KeyboardShortcuts takes its word
    /// for the space bar from its resource bundle, which SwiftPM looks for next to the app
    /// bundle rather than inside it, so an installed Catflap cannot use that text.
    static func describe(_ shortcut: KeyboardShortcuts.Shortcut) -> String {
        let modifiers = shortcut.modifiers
        var text = ""
        if modifiers.contains(.control) { text += "\u{2303}" }
        if modifiers.contains(.option) { text += "\u{2325}" }
        if modifiers.contains(.shift) { text += "\u{21E7}" }
        if modifiers.contains(.command) { text += "\u{2318}" }
        if shortcut.key == .space { return text + "Space" }
        if let letter = letters.first(where: { $0.value == shortcut.key })?.key { return text + letter.uppercased() }
        return text + "Key \(shortcut.carbonKeyCode)"
    }

    /// Reads `ctrl+option+shift+space`, `cmd+shift+k` and the like; `default` is the default.
    func parse(_ text: String) -> KeyboardShortcuts.Shortcut? {
        if text.lowercased() == "default" { return defaultValue }
        var modifiers: NSEvent.ModifierFlags = []
        var key: KeyboardShortcuts.Key?
        for part in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": modifiers.insert(.control)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd", "command": modifiers.insert(.command)
            case "space": key = .space
            default:
                guard key == nil, let letter = Self.letters[part] else { return nil }
                key = letter
            }
        }
        guard let key, !modifiers.isEmpty else { return nil }
        return KeyboardShortcuts.Shortcut(key, modifiers: modifiers)
    }

    private static let letters: [String: KeyboardShortcuts.Key] = [
        "a": .a, "b": .b, "c": .c, "d": .d, "e": .e, "f": .f, "g": .g, "h": .h, "i": .i, "j": .j, "k": .k, "l": .l, "m": .m,
        "n": .n, "o": .o, "p": .p, "q": .q, "r": .r, "s": .s, "t": .t, "u": .u, "v": .v, "w": .w, "x": .x, "y": .y, "z": .z,
    ]

    static func probe(_ shortcut: KeyboardShortcuts.Shortcut) -> OSStatus {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.carbonKeyCode), UInt32(shortcut.carbonModifiers),
                                         EventHotKeyID(signature: 0x4346_5053, id: 2), GetEventDispatcherTarget(), 0, &reference)
        if let reference { UnregisterEventHotKey(reference) }
        return status
    }
}
#endif
