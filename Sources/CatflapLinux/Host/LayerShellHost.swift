import CGtk
import CGtkLayerShell
import CGtkShim

/// Places the panel as a layer-shell surface: top centre, below any panel that reserves the
/// top edge, above full-screen windows, on the display it was asked for. KDE Plasma and other
/// wlroots-style compositors offer the protocol.
final class LayerShellHost: PanelHost {
    let desktop = "layer-shell"
    private let bands = HoverBands()
    private var requested: String?
    private var keyboard = GTK_LAYER_SHELL_KEYBOARD_MODE_NONE
    private var handover: UInt32 = 0
    private(set) var blurAvailable = false
    var onDrop: (([String]) -> Void)?

    static var isSupported: Bool { gtk_layer_is_supported() != 0 }

    func adopt(_ window: OpaquePointer) {
        gtk_layer_init_for_window(window.cast())
        gtk_layer_set_namespace(window.cast(), "catflap-panel")
        // The overlay layer: the hotkey works over full-screen windows too.
        gtk_layer_set_layer(window.cast(), GTK_LAYER_SHELL_LAYER_OVERLAY)
        gtk_layer_set_anchor(window.cast(), GTK_LAYER_SHELL_EDGE_TOP, 1)
        // Zero keeps the panel clear of space other surfaces reserve, so it sits below a top
        // panel, and reserves none itself.
        gtk_layer_set_exclusive_zone(window.cast(), 0)
        gtk_layer_set_keyboard_mode(window.cast(), keyboard)
        blurAvailable = cf_blur_supported(window.cast()) != 0
    }

    func present(_ window: OpaquePointer, mode: PanelMode, display: String?) {
        let wanted = mode == .focused ? GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND : GTK_LAYER_SHELL_KEYBOARD_MODE_NONE
        let visible = gtk_widget_get_visible(window.cast()) != 0
        if requested != display || !visible {
            requested = display
            gtk_layer_set_monitor(window.cast(), display.flatMap(Self.monitor(named:)))
        }
        if wanted != keyboard {
            keyboard = wanted
            if visible && wanted == GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND {
                // A surface already shown does not get the keyboard when it becomes
                // on-demand. Exclusive hands it over at once; on-demand then keeps it until
                // the person clicks elsewhere, which is how a click outside is seen.
                gtk_layer_set_keyboard_mode(window.cast(), GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE)
                // Layer-shell state applies on the next commit, and GTK makes none while nothing changes on screen.
                _ = cf_surface_commit(window.cast())
                handover = GLib.timeout(milliseconds: 150) { [weak self] in
                    guard let self else { return }
                    handover = 0
                    if keyboard == GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND {
                        gtk_layer_set_keyboard_mode(window.cast(), GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND)
                        _ = cf_surface_commit(window.cast())
                    }
                }
            } else {
                gtk_layer_set_keyboard_mode(window.cast(), wanted)
                if visible { _ = cf_surface_commit(window.cast()) }
            }
        }
        gtk_window_present(window.cast())
    }

    func withdraw(_ window: OpaquePointer) {
        if handover != 0 { GLib.cancel(handover); handover = 0 }
        gtk_widget_set_visible(window.cast(), 0)
        keyboard = GTK_LAYER_SHELL_KEYBOARD_MODE_NONE
        gtk_layer_set_keyboard_mode(window.cast(), keyboard)
    }

    func display(of window: OpaquePointer) -> String? {
        guard gtk_widget_get_visible(window.cast()) != 0,
              let native = gtk_widget_get_native(window.cast()), let surface = gtk_native_get_surface(native),
              let gdk = gdk_display_get_default(), let monitor = gdk_display_get_monitor_at_surface(gdk, surface),
              let connector = gdk_monitor_get_connector(monitor) else { return nil }
        return String(cString: connector)
    }

    func startTriggers(_ sink: @escaping (PanelMachine.Event) -> Void) {
        bands.start(sink: sink) { [weak self] files in self?.onDrop?(files) }
    }

    func stopTriggers() { bands.stop() }

    var triggerDisplays: [String] { bands.displays }

    func placement(of window: OpaquePointer) -> PanelPlacement {
        PanelPlacement(
            layer: gtk_layer_get_layer(window.cast()) == GTK_LAYER_SHELL_LAYER_OVERLAY ? "overlay" : "other",
            anchor: gtk_layer_get_anchor(window.cast(), GTK_LAYER_SHELL_EDGE_TOP) != 0 ? "top" : "none",
            exclusiveZone: Int(gtk_layer_get_exclusive_zone(window.cast())),
            keyboard: Self.name(of: gtk_layer_get_keyboard_mode(window.cast())),
            monitorRequested: requested)
    }

    private static func name(of mode: GtkLayerShellKeyboardMode) -> String {
        switch mode {
        case GTK_LAYER_SHELL_KEYBOARD_MODE_NONE: "none"
        case GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND: "on_demand"
        case GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE: "exclusive"
        default: "other"
        }
    }

    private static func monitor(named connector: String) -> OpaquePointer? {
        guard let display = gdk_display_get_default(), let list = gdk_display_get_monitors(display) else { return nil }
        for index in 0..<g_list_model_get_n_items(list) {
            guard let item = g_list_model_get_item(list, index) else { continue }
            defer { g_object_unref(item) }
            let monitor = OpaquePointer(item)
            if let name = gdk_monitor_get_connector(monitor), String(cString: name) == connector { return monitor }
        }
        return nil
    }
}
