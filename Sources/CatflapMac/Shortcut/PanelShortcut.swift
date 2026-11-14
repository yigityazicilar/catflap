#if os(macOS)
import AppKit
import Carbon
import KeyboardShortcuts

/// The panel's global shortcut, Ctrl+Option+Space by default, through KeyboardShortcuts so the
/// person can rebind it (the Recorder for it belongs in Settings).
@MainActor
final class PanelShortcut {
    static let defaultShortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .option])
    static let nameValue = "togglePanel"

    let name: KeyboardShortcuts.Name
    /// The system's answer when the shortcut was offered at start; 0 means accepted.
    private var refusal: OSStatus?

    init(onPress: @escaping @MainActor () -> Void) {
        // The default goes into the registration domain, which lives only in memory.
        // KeyboardShortcuts writes a default it does not find into the person's preferences;
        // with it registered here, only a deliberate rebinding is written.
        if let data = try? JSONEncoder().encode(Self.defaultShortcut), let encoded = String(data: data, encoding: .utf8) {
            UserDefaults.standard.register(defaults: ["KeyboardShortcuts_" + Self.nameValue: encoded])
        }
        name = KeyboardShortcuts.Name(Self.nameValue, default: Self.defaultShortcut)
        // Ask the system first, so a combination another app holds exclusively is reported.
        // KeyboardShortcuts registers the same way but does not say when it fails.
        if let shortcut = KeyboardShortcuts.getShortcut(for: name) { refusal = Self.probe(shortcut) }
        KeyboardShortcuts.onKeyDown(for: name) { MainActor.assumeIsolated { onPress() } }
    }

    /// `bound`, `unbound` (the person removed it) or `conflict` (the system refused it).
    var state: String {
        guard KeyboardShortcuts.getShortcut(for: name) != nil else { return "unbound" }
        if let refusal, refusal != 0 { return "conflict" }
        return "bound"
    }

    var description: String { KeyboardShortcuts.getShortcut(for: name)?.description ?? "" }

    func stop() {
        KeyboardShortcuts.removeHandler(for: name)
    }

    private static func probe(_ shortcut: KeyboardShortcuts.Shortcut) -> OSStatus {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.carbonKeyCode), UInt32(shortcut.carbonModifiers),
                                         EventHotKeyID(signature: 0x4346_5052, id: 1), GetEventDispatcherTarget(), 0, &reference)
        if let reference { UnregisterEventHotKey(reference) }
        return status
    }
}
#endif
