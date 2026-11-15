#if os(macOS)
import AppKit

/// A button that shows a shortcut and records a new one: click it, then press the
/// combination. Esc stops without a change, Delete removes the binding. While it listens,
/// Catflap's own shortcuts are unregistered, so the keys reach it.
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
        if recording { finish(); onChange?(nil) } else { begin() }
    }

    private func begin() {
        recording = true
        for other in quiet { other.suspend() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let code = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let consumed = MainActor.assumeIsolated { self?.record(code: code, flags: flags) ?? false }
            return consumed ? nil : event
        }
        refresh()
    }

    /// Stops listening. The bindings register again; one whose combination was taken meanwhile
    /// is a conflict, which the settings show.
    private func finish() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for other in quiet { other.resume() }
        refresh()
    }

    /// Returns true when the key press belonged to the recorder.
    private func record(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard recording else { return false }
        // Esc (53) stops; Delete (51) and Forward Delete (117) remove the binding.
        if code == 53 && flags.subtracting(.function).isEmpty { finish(); onChange?(nil); return true }
        if (code == 51 || code == 117) && flags.subtracting(.function).isEmpty {
            _ = binding.rebind(nil)
            finish()
            onChange?(nil)
            return true
        }
        let modifiers = flags.intersection([.control, .option, .command, .shift])
        // A global shortcut needs Control, Option or Command; Shift alone would take a letter.
        guard !modifiers.intersection([.control, .option, .command]).isEmpty else {
            NSSound.beep()
            return true
        }
        let shortcut = Shortcut(key: Int(code), modifiers: modifiers)
        // The other binding is quiet while recording, so the system would not refuse its keys.
        if quiet.contains(where: { $0 !== binding && $0.shortcut == shortcut }) {
            finish()
            onChange?("Catflap's other shortcut is \(ShortcutBinding.describe(shortcut)). Choose another.")
            return true
        }
        binding.resume()
        let refusal = binding.rebind(shortcut)
        finish()
        onChange?(refusal.map { ShortcutBinding.sentence($0, shortcut) })
        return true
    }

    func stop() { if recording { finish() } }
}
#endif
