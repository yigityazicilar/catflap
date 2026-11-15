import CatflapCore
import Foundation

/// The display server the agent was given, from its environment: what the session offers,
/// never which desktop it calls itself. A Wayland session that also offers an X display
/// (XWayland) is Wayland: the X display is never used for it.
enum DesktopSession: Equatable {
    case wayland, x11, none

    static func of(_ environment: [String: String]) -> DesktopSession {
        if environment["WAYLAND_DISPLAY"].map({ !$0.isEmpty }) == true || environment["WAYLAND_SOCKET"].map({ !$0.isEmpty }) == true {
            return .wayland
        }
        return environment["DISPLAY"].map { !$0.isEmpty } == true ? .x11 : .none
    }

    static var current: DesktopSession { of(ProcessInfo.processInfo.environment) }

    /// The one GDK backend GTK may open for this session.
    var gdkBackends: String { self == .x11 ? "x11" : "wayland" }

    /// Whether the panel has a display to show on: a named Wayland display, or an X display
    /// in a session without Wayland.
    static func hasPanelDisplay(_ environment: [String: String]) -> Bool {
        switch of(environment) {
        case .wayland: environment["WAYLAND_DISPLAY"].map { !$0.isEmpty } == true
        case .x11: true
        case .none: false
        }
    }
}

/// Desktop services are selected once. The shared panel owns no compositor-specific API.
struct DesktopBackends: @unchecked Sendable {
    let host: any PanelHost
    let shortcut: any ShortcutBackend
    let sendShortcut: any ShortcutBackend
    let clipboard: any ClipboardBackend

    static func layerShell() -> DesktopBackends {
        DesktopBackends(host: LayerShellHost(), shortcut: GlobalShortcut(),
                        sendShortcut: SendClipboardShortcut(), clipboard: ClipboardWriter())
    }

    /// The X11 tier: a GTK window placed through Xlib, key grabs on the root window, and GDK's
    /// own clipboard for Copy, which works on X11 as on Wayland.
    static func x11() -> DesktopBackends? {
        guard X11Host.isSupported, let connection = X11Connection.open() else { return nil }
        let host = X11Host(connection: connection), hotkey = X11Shortcut.panel(connection), send = X11Shortcut.send(connection)
        host.shortcuts = [hotkey, send]
        return DesktopBackends(host: host, shortcut: hotkey, sendShortcut: send, clipboard: ClipboardWriter())
    }

    /// The backends for this session, chosen once at start on the GTK thread from the display
    /// GDK opened: layer-shell when the Wayland compositor offers it, else X11 when GDK runs on
    /// an X server, else none, and the agent goes on without a panel. GDK opens only the
    /// session's own display (`DesktopSession.gdkBackends`), so under Wayland X11 is never
    /// chosen. Another desktop adds its backend here.
    static func select() -> DesktopBackends? {
        // gtk4-layer-shell asks for a Wayland display and complains on any other, so an X11
        // display goes straight to the X11 tier.
        if !X11Connection.gdkIsX11 && LayerShellHost.isSupported { return layerShell() }
        return x11()
    }

    /// What watches the clipboard: XFixes in an X11 session, Wayland data-control otherwise
    /// (which reports `unsupported` without a Wayland display).
    static func clipboardWatcher(history: ClipboardHistory, runtime: AgentRuntime) -> any ClipboardWatcher {
        DesktopSession.current == .x11 ? X11ClipboardWatcher(history: history, runtime: runtime)
            : DataControlWatcher(history: history, runtime: runtime)
    }
}

/// Watches the desktop's clipboard and records copies in the history. `start` returns once
/// the watcher has reported its state; `stop` ends its thread and connection.
protocol ClipboardWatcher: AnyObject, Sendable {
    func start() async
    func stop() async
}

/// Called on the GTK thread, like the panel and its host.
protocol ShortcutBackend: AnyObject {
    var state: String { get }
    var trigger: String? { get }
    func start(onChange: @escaping () -> Void, onActivated: @escaping () -> Void)
    func configure() -> Bool
    func stop()
}

protocol ClipboardBackend: AnyObject {
    func set(text: String, secret: Bool)
    func set(files: [String])
    func set(_ item: ClipboardItem)
}

extension ClipboardBackend {
    func set(text: String) { set(text: text, secret: false) }
    func set(secret text: String) { set(text: text, secret: true) }
}

extension GlobalShortcut: ShortcutBackend {}
extension SendClipboardShortcut: ShortcutBackend {}
extension ClipboardWriter: ClipboardBackend {}
extension DataControlWatcher: ClipboardWatcher {}
extension X11ClipboardWatcher: ClipboardWatcher {}
