#if os(macOS)
import AppKit
import Carbon

/// A key combination as Carbon names it: a virtual key code and Carbon's modifier bits.
/// The preferences hold it as the JSON text `{"carbonKeyCode":49,"carbonModifiers":6400}`, the
/// form the KeyboardShortcuts package wrote before Catflap registered its shortcuts itself, so
/// a binding made with an earlier version still applies.
struct Shortcut: Hashable, Codable, Sendable {
    let carbonKeyCode: Int
    let carbonModifiers: Int

    /// The modifiers a shortcut is told apart by. What macOS stores for its own shortcuts can
    /// carry more bits (Fn, the numeric keypad).
    static let modifierMask = cmdKey | shiftKey | optionKey | controlKey

    enum CodingKeys: String, CodingKey { case carbonKeyCode, carbonModifiers }

    init(carbonKeyCode: Int, carbonModifiers: Int) {
        self.carbonKeyCode = carbonKeyCode
        self.carbonModifiers = carbonModifiers & Self.modifierMask
    }

    init(key: Int, modifiers: NSEvent.ModifierFlags) {
        var bits = 0
        if modifiers.contains(.command) { bits |= cmdKey }
        if modifiers.contains(.shift) { bits |= shiftKey }
        if modifiers.contains(.option) { bits |= optionKey }
        if modifiers.contains(.control) { bits |= controlKey }
        self.init(carbonKeyCode: key, carbonModifiers: bits)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(carbonKeyCode: try container.decode(Int.self, forKey: .carbonKeyCode),
                  carbonModifiers: try container.decode(Int.self, forKey: .carbonModifiers))
    }
}

/// Why a shortcut is not registered. Either way it is a conflict: reported, never fatal.
enum ShortcutRefusal: Error, Equatable, Sendable {
    /// macOS has an enabled shortcut of its own on the combination (System Settings, Keyboard,
    /// Keyboard Shortcuts), which takes the keys before any app sees them.
    case system
    /// RegisterEventHotKey refused it: eventHotKeyExistsErr (-9878) while another
    /// registration holds the combination.
    case refused(OSStatus)
}

/// Catflap's global shortcuts, registered with Carbon directly. Every registration keeps its
/// handle until it is released, and a refusal is an answer to the caller: nothing here prints
/// or formats a shortcut.
@MainActor
final class HotKeyRegistrar {
    static let shared = HotKeyRegistrar()
    /// "CFLP": the signature of every hotkey id Catflap registers.
    nonisolated static let signature: OSType = 0x4346_4C50

    struct Registration: Equatable {
        let id: UInt32
        let reference: EventHotKeyRef
    }

    private var handler: EventHandlerRef?
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var lastID: UInt32 = 0

    /// Registers `shortcut` with `action`, or says why not.
    func register(_ shortcut: Shortcut, action: @escaping @MainActor () -> Void) -> Result<Registration, ShortcutRefusal> {
        if Self.systemUses(shortcut) { return .failure(.system) }
        installHandler()
        lastID &+= 1
        let id = lastID
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.carbonKeyCode), UInt32(shortcut.carbonModifiers),
                                         EventHotKeyID(signature: Self.signature, id: id), GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else { return .failure(.refused(status == noErr ? OSStatus(paramErr) : status)) }
        actions[id] = action
        return .success(Registration(id: id, reference: reference))
    }

    func unregister(_ registration: Registration) {
        actions[registration.id] = nil
        UnregisterEventHotKey(registration.reference)
    }

    /// Runs the action of the registration `id`; false when it has none.
    fileprivate func fire(_ id: UInt32) -> Bool {
        guard let action = actions[id] else { return false }
        action()
        return true
    }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var installed: EventHandlerRef?
        if InstallEventHandler(GetEventDispatcherTarget(), catflapHotKeyPressed, 1, &pressed, nil, &installed) == noErr {
            handler = installed
        }
    }

    /// Whether macOS has an enabled shortcut of its own on `shortcut`.
    static func systemUses(_ shortcut: Shortcut) -> Bool { systemShortcuts().contains(shortcut) }

    /// The enabled shortcuts of macOS itself, as CopySymbolicHotKeys lists them.
    nonisolated static func systemShortcuts() -> [Shortcut] {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers] as? Int else { return nil }
            return Shortcut(carbonKeyCode: code, carbonModifiers: modifiers)
        }
    }
}

/// The Carbon handler for a pressed hotkey. Carbon calls it on the main thread, from the event
/// loop; a hotkey that is not one of Catflap's goes on to the next handler.
private func catflapHotKeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKey = EventHotKeyID()
    let status = GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
    guard status == noErr, hotKey.signature == HotKeyRegistrar.signature else { return OSStatus(eventNotHandledErr) }
    let id = hotKey.id
    let handled = MainActor.assumeIsolated { HotKeyRegistrar.shared.fire(id) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
#endif
