import CGtk
import CGtkLayerShell

/// Where the panel sits: the hotkey, the hover band and a drag open it at the top centre; the
/// tray item opens it in the lower right corner, above a panel along the bottom edge (the
/// panel keeps an exclusive zone of 0, so the compositor keeps it clear of reserved edges).
enum TrayPlacement {
    static func apply(_ origin: String, to window: OpaquePointer) {
        guard gtk_layer_is_layer_window(window.cast()) != 0 else { return }
        let tray = origin == "tray"
        gtk_layer_set_anchor(window.cast(), GTK_LAYER_SHELL_EDGE_TOP, tray ? 0 : 1)
        gtk_layer_set_anchor(window.cast(), GTK_LAYER_SHELL_EDGE_BOTTOM, tray ? 1 : 0)
        gtk_layer_set_anchor(window.cast(), GTK_LAYER_SHELL_EDGE_RIGHT, tray ? 1 : 0)
        gtk_layer_set_anchor(window.cast(), GTK_LAYER_SHELL_EDGE_LEFT, 0)
        gtk_layer_set_margin(window.cast(), GTK_LAYER_SHELL_EDGE_BOTTOM, tray ? 8 : 0)
        gtk_layer_set_margin(window.cast(), GTK_LAYER_SHELL_EDGE_RIGHT, tray ? 8 : 0)
    }

    static func anchor(of window: OpaquePointer) -> String {
        guard gtk_layer_is_layer_window(window.cast()) != 0 else { return "none" }
        var edges: [String] = []
        if gtk_layer_get_anchor(window.cast(), GTK_LAYER_SHELL_EDGE_TOP) != 0 { edges.append("top") }
        if gtk_layer_get_anchor(window.cast(), GTK_LAYER_SHELL_EDGE_BOTTOM) != 0 { edges.append("bottom") }
        if gtk_layer_get_anchor(window.cast(), GTK_LAYER_SHELL_EDGE_LEFT) != 0 { edges.append("left") }
        if gtk_layer_get_anchor(window.cast(), GTK_LAYER_SHELL_EDGE_RIGHT) != 0 { edges.append("right") }
        return edges.isEmpty ? "none" : edges.joined(separator: "-")
    }
}
