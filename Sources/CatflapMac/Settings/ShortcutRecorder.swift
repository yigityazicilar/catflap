#if os(macOS)
import AppKit
import KeyboardShortcuts

/// A button that shows a shortcut and records a new one: click it, then press the
/// combination. Esc stops without a change, Delete removes the binding. While it listens,
/// Catflap's own shortcuts do not fire.
@MainActor
final class ShortcutRecorder: NSButton {
    let binding: ShortcutBinding
    /// Every binding to keep quiet while recording, this one included.
    var quiet: [ShortcutBinding] = []
    /// Called after a change with nil, or with the sentence to show when it was refused.
    var onChange: ((String?) -> Void)?
    private var monitor: Any?
    private(set) var recording = false

    init(binding: ShortcutBinding, label: String) {
        self.binding = binding
        super.init(frame: .zero)
        bezelStyle = .push
        target = self
        action = #selector(clicked)
        setAccessibilityLabel(label)
        setAccessibilityHelp("Press to record a new shortcut. Esc cancels, Delete removes it.")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func refresh() {
        if recording { title = "Type the shortcut\u{2026}" }
        else { title = binding.keys.isEmpty ? "Record Shortcut" : binding.keys }
    }

    @objc private func clicked() {
        if recording { finish() } else { begin() }
    }

    private func begin() {
        recording = true
        for other in quiet { KeyboardShortcuts.disable([other.name]) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let shortcut = KeyboardShortcuts.Shortcut(event: event)
            let code = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let consumed = MainActor.assumeIsolated { self?.record(shortcut, code: code, flags: flags) ?? false }
            return consumed ? nil : event
        }
        refresh()
    }

    private func finish() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for other in quiet { KeyboardShortcuts.enable([other.name]) }
        refresh()
    }

    /// Returns true when the key press belonged to the recorder.
    private func record(_ shortcut: KeyboardShortcuts.Shortcut?, code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard recording else { return false }
        // Esc (53) stops; Delete (51) and Forward Delete (117) remove the binding.
        if code == 53 && flags.subtracting(.function).isEmpty { finish(); return true }
        if (code == 51 || code == 117) && flags.subtracting(.function).isEmpty {
            _ = binding.rebind(nil)
            finish()
            onChange?(nil)
            return true
        }
        let modifiers = flags.intersection([.control, .option, .command, .shift])
        // A global shortcut needs Control, Option or Command; Shift alone would take a letter.
        guard let shortcut, !modifiers.intersection([.control, .option, .command]).isEmpty else {
            NSSound.beep()
            return true
        }
        // KeyboardShortcuts is quiet for this binding while recording; let it register again.
        KeyboardShortcuts.enable([binding.name])
        let taken = binding.rebind(shortcut)
        finish()
        onChange?(taken ? nil : "macOS or another app already uses \(ShortcutBinding.describe(shortcut)). Choose another.")
        return true
    }

    func stop() { if recording { finish() } }
}
#endif
