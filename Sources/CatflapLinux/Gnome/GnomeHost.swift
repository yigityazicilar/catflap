import CGtk
import CGtkShim
import CatflapCore
import Foundation

/// An ordinary GTK window placed by the authenticated Shell extension.
final class GnomeHost: PanelHost {
    let desktop = "gnome"
    let blurAvailable = false
    var onDrop: (([String]) -> Void)?
    private let bridge: GnomeBridge
    private let listener = UUID()
    private var mode: PanelMode = .hidden
    private var requested: String?
    private var window: OpaquePointer?
    private var sink: ((PanelMachine.Event) -> Void)?
    private var monitor: OpaquePointer?
    init(bridge: GnomeBridge) { self.bridge = bridge }
    func adopt(_ window: OpaquePointer) {
        self.window = window
        gtk_window_set_decorated(window.cast(), 0)
    }
    func present(_ window: OpaquePointer, mode: PanelMode, display: String?) {
        self.mode = mode; requested = display
        _ = bridge.push("panel", ["mode": mode.rawValue, "display": display ?? ""])
        // Present requests activation; a hover surface must map without it.
        gtk_widget_set_visible(window.cast(), 1)
    }
    func withdraw(_ window: OpaquePointer) {
        mode = .hidden
        gtk_widget_set_visible(window.cast(), 0)
        _ = bridge.push("panel", ["mode": "hidden"])
    }
    func display(of window: OpaquePointer) -> String? { requested ?? triggerDisplays.first }
    func startTriggers(_ sink: @escaping (PanelMachine.Event) -> Void) {
        self.sink = sink
        let bridge = self.bridge
        let file = g_file_new_for_path(bridge.directory.path)
        defer { g_object_unref(UnsafeMutableRawPointer(file)) }
        if let monitor = g_file_monitor_directory(file, GFileMonitorFlags(rawValue: 0), nil, nil) {
            self.monitor = OpaquePointer(monitor)
            GLib.connect(OpaquePointer(monitor), "changed", Int32(CF_SHAPE_FILE)) { [weak self] _ in
                guard let self else { return }
                Task { await bridge.updateFiles() }
            }
        }
        Task { await bridge.updateFiles() }
        bridge.listeners[listener] = { [weak self] action, arguments in
            guard let self else { return }
            let display = arguments["display"]
            switch action {
            case "band-enter": sink(.bandEntered(display: display))
            case "band-leave": sink(.bandLeft)
            case "drag-enter": sink(.dragEntered(display: display, onPanel: false))
            case "drag-leave": sink(.dragLeft(onPanel: false))
            case "missing": sink(.hide)
            case "connected": _ = bridge.push("panel", ["mode": mode.rawValue, "display": requested ?? ""])
            default: break
            }
        }
    }
    func stopTriggers() {
        bridge.listeners[listener] = nil; sink = nil
        if let monitor { g_file_monitor_cancel(monitor.cast()); g_object_unref(UnsafeMutableRawPointer(monitor)) }
        monitor = nil
    }
    var triggerDisplays: [String] {
        guard let display = gdk_display_get_default(), let monitors = gdk_display_get_monitors(display) else { return [] }
        return (0..<g_list_model_get_n_items(monitors)).compactMap { index in
            guard let item = g_list_model_get_item(monitors, index) else { return nil }
            defer { g_object_unref(item) }
            return gdk_monitor_get_connector(OpaquePointer(item)).map { String(cString: $0) }
        }
    }
    func placement(of window: OpaquePointer) -> PanelPlacement {
        PanelPlacement(layer: "shell", anchor: "top", exclusiveZone: 0,
                       keyboard: mode == .focused ? "on_demand" : "none", monitorRequested: requested)
    }
}

final class GnomeShortcut: ShortcutBackend {
    private let bridge: GnomeBridge
    private let action: String
    private let listener = UUID()
    init(bridge: GnomeBridge, action: String) { self.bridge = bridge; self.action = action }
    var state: String { bridge.isBound(action) ? "bound" : "unavailable" }
    var trigger: String? { action == "toggle" ? "Ctrl+Alt+Space" : "Ctrl+Alt+Shift+Space" }
    func start(onChange: @escaping () -> Void, onActivated: @escaping () -> Void) {
        bridge.listeners[listener] = { [weak self] event, _ in
            guard let self else { return }
            if event == action {
                FileHandle.standardError.write(Data("catflap shortcut activation \(action)\n".utf8))
                onActivated()
            }
            if event == "connected" || event == "missing" { onChange() }
        }
        onChange()
    }
    func configure() -> Bool { false }
    func stop() { bridge.listeners[listener] = nil }
}

final class GnomeClipboard: ClipboardBackend {
    let bridge: GnomeBridge
    init(bridge: GnomeBridge) { self.bridge = bridge }
    func set(text: String, secret: Bool) {
        put(Data(text.utf8), mime: "text/plain;charset=utf-8", secret: secret)
    }
    func set(files uris: [String]) { put(Data(uris.joined(separator: "\r\n").utf8), mime: "text/uri-list") }
    func set(_ item: ClipboardItem) {
        switch item.kind {
        case .text: set(text: item.text ?? "", secret: false)
        case .files: set(files: (item.text ?? "").split(whereSeparator: \.isNewline).map(String.init))
        case .url: put(item.content, mime: "text/uri-list")
        case .image: put(item.content, mime: item.mime ?? "image/png")
        }
    }
    private func put(_ data: Data, mime: String, secret: Bool = false) {
        _ = bridge.push("clipboard-set", ["mime": mime, "content": data.base64EncodedString(), "secret": secret ? "true" : "false"])
    }
}
