#if os(macOS)
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A key combination as the tests name it: Carbon's key code and modifier bits, the form
/// Catflap keeps in its preferences.
struct TestShortcut: Sendable, Equatable, CustomStringConvertible {
    let code: Int
    let modifiers: Int

    static let mask = cmdKey | shiftKey | optionKey | controlKey
    static let space = kVK_Space
    static let letterJ = kVK_ANSI_J
    static let letterK = kVK_ANSI_K
    static let letterL = kVK_ANSI_L

    init(code: Int, modifiers: Int) {
        self.code = code
        self.modifiers = modifiers & Self.mask
    }

    /// `code` with Control, Option and Command, and Shift when `shift` is set.
    static func controlOptionCommand(_ code: Int, shift: Bool = false) -> TestShortcut {
        TestShortcut(code: code, modifiers: controlKey | optionKey | cmdKey | (shift ? shiftKey : 0))
    }

    static func controlOption(_ code: Int) -> TestShortcut { TestShortcut(code: code, modifiers: controlKey | optionKey) }

    /// The preference value as KeyboardShortcuts wrote it, which Catflap still reads.
    var preference: String { "{\"carbonKeyCode\":\(code),\"carbonModifiers\":\(modifiers)}" }

    var description: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "\u{2303}" }
        if modifiers & optionKey != 0 { text += "\u{2325}" }
        if modifiers & shiftKey != 0 { text += "\u{21E7}" }
        if modifiers & cmdKey != 0 { text += "\u{2318}" }
        switch code {
        case Self.space: return text + "Space"
        case Self.letterJ: return text + "J"
        case Self.letterK: return text + "K"
        case Self.letterL: return text + "L"
        default: return text + "Key \(code)"
        }
    }
}

enum SystemKeys {
    /// macOS's own enabled shortcuts on this Mac (System Settings, Keyboard, Keyboard
    /// Shortcuts), as CopySymbolicHotKeys lists them. Entries without a key code are left out.
    static func systemShortcuts() -> [TestShortcut] {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode] as? Int, code < 0x80,
                  let modifiers = entry[kHISymbolicHotKeyModifiers] as? Int else { return nil }
            return TestShortcut(code: code, modifiers: modifiers)
        }
    }

    /// Whether macOS lets this process post keyboard events. It never asks here: an answer of
    /// no stays no.
    static var canPost: Bool { CGPreflightPostEventAccess() }

    /// Presses and releases `shortcut` through the window server, as the keyboard would, so a
    /// global shortcut registered for it fires. False when an event could not be made.
    static func press(_ shortcut: TestShortcut) -> Bool {
        var flags: CGEventFlags = []
        if shortcut.modifiers & cmdKey != 0 { flags.insert(.maskCommand) }
        if shortcut.modifiers & shiftKey != 0 { flags.insert(.maskShift) }
        if shortcut.modifiers & optionKey != 0 { flags.insert(.maskAlternate) }
        if shortcut.modifiers & controlKey != 0 { flags.insert(.maskControl) }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.code), keyDown: down) else { return false }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}
#endif
