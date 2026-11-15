import CX11

/// A global shortcut on X11: a key grab on the root window, which is how X desktops bind
/// application hotkeys. While the panel has the keyboard the grab sits on the panel's own
/// window instead (`move(to:)`): a grab that activates on the root window counts, for the
/// X server, as the keyboard moving to the root window, and GTK reports that as the panel
/// losing it, which closes the panel. A grab on the window that has the keyboard moves
/// nothing. The grab covers every combination of Caps Lock, Num Lock and Scroll
/// Lock, since X reports them as modifiers too, and is made again when the keyboard mapping
/// changes. If another program already holds the combination the X server refuses the grab;
/// the shortcut then reports `conflict` and holds none of the variants. There is no system
/// dialog for changing it.
///
/// Called on the GTK thread, like every `ShortcutBackend`.
final class X11Shortcut: ShortcutBackend {
    /// `pending`, `bound`, `conflict` (another program holds the combination) or `failed`
    /// (the key is not on this keyboard, or the X server refused for another reason).
    private(set) var state = "pending"
    /// The combination, once grabbed, in the words the settings page shows.
    private(set) var trigger: String?
    let label: String
    private let keysym: KeySym
    private let modifiers: UInt32
    private let connection: X11Connection
    private var listener: Int?
    private var keycode: KeyCode = 0
    /// The window the grab is asked for, 0 for the root window, and the one it is held on.
    private var window: Window = 0
    private var grabbed: Window = 0
    private var variants: [UInt32] = []
    private var held = false
    /// The timer that looks at the keyboard for a held press whose release will not come.
    private var releaseWatch: UInt32 = 0
    private var onChange: (() -> Void)?
    private var onActivated: (() -> Void)?
    /// The modifiers a combination is told apart by; lock keys and the rest are ignored.
    private static let significant = UInt32(ShiftMask | ControlMask | Mod1Mask | Mod4Mask)

    init(connection: X11Connection, keysym: Int32, modifiers: Int32, label: String) {
        self.connection = connection
        self.keysym = KeySym(keysym)
        self.modifiers = UInt32(modifiers)
        self.label = label
    }

    /// The panel's hotkey, Ctrl+Alt+Space, as on KDE.
    static func panel(_ connection: X11Connection) -> X11Shortcut {
        X11Shortcut(connection: connection, keysym: XK_space, modifiers: ControlMask | Mod1Mask, label: "Ctrl+Alt+Space")
    }

    /// The send-clipboard shortcut, Ctrl+Alt+Shift+Space.
    static func send(_ connection: X11Connection) -> X11Shortcut {
        X11Shortcut(connection: connection, keysym: XK_space, modifiers: ControlMask | Mod1Mask | ShiftMask, label: "Ctrl+Alt+Shift+Space")
    }

    func start(onChange: @escaping () -> Void, onActivated: @escaping () -> Void) {
        self.onChange = onChange
        self.onActivated = onActivated
        listener = connection.listen { [weak self] event in self?.handle(event) }
        grab()
        // Reported after start returns, as the portal's answer is.
        GLib.idle { [weak self] in self?.onChange?() }
    }

    func configure() -> Bool { false }

    /// Moves the grab onto `window`, or back to the root window for 0. A shortcut that holds
    /// no grab only notes where the next one goes.
    func move(to window: Window) {
        guard window != self.window else { return }
        self.window = window
        guard state == "bound" else { return }
        ungrab()
        grab()
        // A press held through the move was grabbed on the old window, and that grab ended
        // with the move (or with the panel's window going away), so its release goes to the
        // window that has the keyboard. Until the keys are up, a press is still that one.
        if held { watchRelease() }
    }

    /// Ends the hold once the keyboard shows the key up.
    private func watchRelease() {
        guard releaseWatch == 0 else { return }
        releaseWatch = GLib.timeout(milliseconds: 30) { [weak self] in
            guard let self else { return }
            releaseWatch = 0
            guard held, !connection.closed else { return }
            if keyIsDown() { watchRelease() } else { held = false }
        }
    }

    private func keyIsDown() -> Bool {
        var keys = [CChar](repeating: 0, count: 32)
        XQueryKeymap(connection.display, &keys)
        return UInt8(bitPattern: keys[Int(keycode) / 8]) & (1 << (keycode % 8)) != 0
    }

    func stop() {
        if releaseWatch != 0 { GLib.cancel(releaseWatch) }
        releaseWatch = 0
        ungrab()
        if let listener { connection.unlisten(listener) }
        listener = nil
        onChange = nil
        onActivated = nil
    }

    private func grab() {
        guard !connection.closed else { return }
        let display = connection.display
        keycode = XKeysymToKeycode(display, keysym)
        guard keycode != 0 else { report("failed"); return }
        let masks = Self.lockVariants(display)
        let target = window == 0 ? connection.root : window
        let code = X11Errors.trap(display) {
            for mask in masks {
                XGrabKey(display, Int32(keycode), modifiers | mask, target, 0, GrabModeAsync, GrabModeAsync)
            }
        }
        grabbed = target
        if code == 0 {
            variants = masks
            report("bound")
        } else {
            // A refused variant leaves the others in place; let go of all of them, so the
            // combination does not half work.
            variants = masks
            ungrab()
            report(code == BadAccess ? "conflict" : "failed")
        }
        connection.dispatch()
    }

    private func ungrab() {
        guard !connection.closed, keycode != 0 else { variants = []; return }
        let display = connection.display
        _ = X11Errors.trap(display) {
            for mask in variants { XUngrabKey(display, Int32(keycode), modifiers | mask, grabbed) }
        }
        variants = []
    }

    private func report(_ next: String) {
        state = next
        trigger = next == "bound" ? label : nil
    }

    private func handle(_ event: UnsafeMutablePointer<XEvent>) {
        switch event.pointee.type {
        case KeyPress:
            let key = event.pointee.xkey
            guard state == "bound", key.keycode == UInt32(keycode), key.state & Self.significant == modifiers else { return }
            // Holding the keys repeats the press; one press is one toggle.
            guard !held else { return }
            held = true
            connection.activationTime = UInt32(truncatingIfNeeded: key.time)
            onActivated?()
            connection.activationTime = nil
        case KeyRelease:
            if event.pointee.xkey.keycode == UInt32(keycode) { held = false }
        case MappingNotify:
            XRefreshKeyboardMapping(&event.pointee.xmapping)
            guard event.pointee.xmapping.request != MappingPointer, state == "bound" || state == "conflict" else { return }
            // A key moved or a lock key changed modifier: grab again with the new codes.
            if state == "bound" { ungrab() }
            grab()
            onChange?()
        default:
            break
        }
    }

    /// Every combination of the lock modifiers this keyboard has: Caps Lock is always Lock;
    /// Num Lock and Scroll Lock sit on whichever modifier the mapping gives them.
    static func lockVariants(_ display: OpaquePointer) -> [UInt32] {
        var locks: [UInt32] = [UInt32(LockMask)]
        if let map = XGetModifierMapping(display) {
            let width = Int(map.pointee.max_keypermod)
            for modifier in 0..<8 {
                for index in 0..<width {
                    let code = map.pointee.modifiermap[modifier * width + index]
                    guard code != 0 else { continue }
                    let sym = XkbKeycodeToKeysym(display, code, 0, 0)
                    if sym == KeySym(XK_Num_Lock) || sym == KeySym(XK_Scroll_Lock) {
                        let mask = UInt32(1) << UInt32(modifier)
                        if !locks.contains(mask) { locks.append(mask) }
                    }
                }
            }
            XFreeModifiermap(map)
        }
        var variants: [UInt32] = [0]
        for lock in locks { variants += variants.map { $0 | lock } }
        return Array(Set(variants)).sorted()
    }
}
