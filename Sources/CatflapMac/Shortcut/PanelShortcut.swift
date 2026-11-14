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
    // Scratch review only: hold a Carbon registration inside this agent process.
    private static var reviewReservation: EventHotKeyRef?

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
        if ProcessInfo.processInfo.environment["CATFLAP_REVIEW_IN_PROCESS_CONFLICT"] == "1",
           let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            let reserved = RegisterEventHotKey(UInt32(shortcut.carbonKeyCode), UInt32(shortcut.carbonModifiers),
                EventHotKeyID(signature: 0x52455657, id: 9), GetEventDispatcherTarget(), 0, &Self.reviewReservation)
            let refused = Self.probe(shortcut)
            FileHandle.standardError.write(Data("REVIEW in-agent Carbon reservation=\(reserved) secondProbe=\(refused)\n".utf8))
        }
        KeyboardShortcuts.onKeyDown(for: name) { MainActor.assumeIsolated { onPress() } }
    }

    /// `bound`, `unbound` (the person removed it) or `conflict` (the system refused it).
    var state: String {
        guard KeyboardShortcuts.getShortcut(for: name) != nil else { return "unbound" }
        if let refusal, refusal != 0 { return "conflict" }
        return "bound"
    }

    /// Written here, not by KeyboardShortcuts' `description`: that reads its resource bundle,
    /// which an installed Catflap.app cannot hold where SwiftPM looks, and stops the agent.
    var description: String { KeyboardShortcuts.getShortcut(for: name).map(ShortcutBinding.describe) ?? "" }

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
