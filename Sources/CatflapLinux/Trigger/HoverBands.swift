import CGtk
import CGtkLayerShell
import CGtkShim

/// One invisible strip per display at the top centre, below any top panel, that reports the
/// pointer resting on it and files dragged onto it. A layer-shell surface in the top layer,
/// which compositors keep under full-screen windows, so the band is off over those.
final class HoverBands {
    static let width: Int32 = 420
    static let height: Int32 = 3

    private struct Band {
        let window: OpaquePointer
        let display: String?
    }

    private var bands: [Band] = []
    private var sink: ((PanelMachine.Event) -> Void)?
    private var onDrop: (([String]) -> Void)?
    private var monitorsChanged: UInt = 0
    private var monitors: OpaquePointer?

    var displays: [String] { bands.compactMap(\.display) }

    func start(sink: @escaping (PanelMachine.Event) -> Void, onDrop: @escaping ([String]) -> Void) {
        self.sink = sink
        self.onDrop = onDrop
        guard let display = gdk_display_get_default(), let list = gdk_display_get_monitors(display) else { return }
        monitors = list
        monitorsChanged = GLib.connect(list, "items-changed", Int32(CF_SHAPE_ITEMS)) { [weak self] _ in self?.rebuild() }
        rebuild()
    }

    func stop() {
        if let monitors, monitorsChanged != 0 {
            g_signal_handler_disconnect(UnsafeMutableRawPointer(monitors), gulong(monitorsChanged))
        }
        monitorsChanged = 0
        monitors = nil
        for band in bands { gtk_window_destroy(band.window.cast()) }
        bands = []
        sink = nil
        onDrop = nil
    }

    private func rebuild() {
        for band in bands { gtk_window_destroy(band.window.cast()) }
        bands = []
        guard let monitors else { return }
        for index in 0..<g_list_model_get_n_items(monitors) {
            guard let item = g_list_model_get_item(monitors, index) else { continue }
            let monitor = OpaquePointer(item)
            bands.append(makeBand(on: monitor))
            g_object_unref(item)
        }
    }

    private func makeBand(on monitor: OpaquePointer) -> Band {
        let window = opaque(gtk_window_new())
        let connector = gdk_monitor_get_connector(monitor).map { String(cString: $0) }
        gtk_layer_init_for_window(window.cast())
        gtk_layer_set_namespace(window.cast(), "catflap-band")
        gtk_layer_set_layer(window.cast(), GTK_LAYER_SHELL_LAYER_TOP)
        gtk_layer_set_monitor(window.cast(), monitor)
        gtk_layer_set_anchor(window.cast(), GTK_LAYER_SHELL_EDGE_TOP, 1)
        // Zero: placed below panels that reserve space, and reserves none itself.
        gtk_layer_set_exclusive_zone(window.cast(), 0)
        gtk_layer_set_keyboard_mode(window.cast(), GTK_LAYER_SHELL_KEYBOARD_MODE_NONE)
        gtk_window_set_default_size(window.cast(), Self.width, Self.height)
        gtk_widget_add_css_class(window.cast(), "catflap-band")
        let strip = opaque(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0))
        gtk_widget_set_size_request(strip.cast(), Self.width, Self.height)
        gtk_window_set_child(window.cast(), strip.cast())
        cf_accessible_label(window.cast(), "Catflap hover area")

        let motion = opaque(gtk_event_controller_motion_new())
        GLib.connect(motion, "enter", Int32(CF_SHAPE_POINT)) { [weak self] _ in self?.sink?(.bandEntered(display: connector)) }
        GLib.connect(motion, "leave", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.sink?(.bandLeft) }
        gtk_widget_add_controller(window.cast(), motion)

        let drop = opaque(gtk_drop_target_new(gdk_file_list_get_type(), GDK_ACTION_COPY))
        GLib.connect(drop, "enter", Int32(CF_SHAPE_DROP_POINT)) { [weak self] event in
            self?.sink?(.dragEntered(display: connector, onPanel: false))
            event.pointee.result = Int32(GDK_ACTION_COPY.rawValue)
        }
        GLib.connect(drop, "leave", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.sink?(.dragLeft(onPanel: false)) }
        GLib.connect(drop, "drop", Int32(CF_SHAPE_DROP)) { [weak self] event in
            let uris = event.pointee.text.map { String(cString: $0) } ?? ""
            self?.onDrop?(uris.split(separator: "\n").map(String.init))
            event.pointee.result = 1
        }
        gtk_widget_add_controller(window.cast(), drop)
        gtk_window_present(window.cast())
        return Band(window: window, display: connector)
    }
}
