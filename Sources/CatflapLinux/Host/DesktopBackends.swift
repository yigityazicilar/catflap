import CatflapCore

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

    /// The backends for this session, chosen once at start on the GTK thread: layer-shell when
    /// the compositor offers it, else none, and the agent goes on without a panel. Another
    /// desktop adds its backend here.
    static func select() -> DesktopBackends? {
        LayerShellHost.isSupported ? layerShell() : nil
    }
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
