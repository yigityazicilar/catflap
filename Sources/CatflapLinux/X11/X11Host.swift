import CGtk
import CGtkShim
import CX11

/// Places the panel on an X11 desktop (Xfce, MATE, Cinnamon, i3, Openbox): an undecorated
/// GTK window of the utility type, which tiling window managers float instead of tiling, kept
/// above other windows and out of the taskbar and the pager through the window manager's
/// EWMH state, at the top centre of the monitor below a top panel. GTK 4 has no API for
/// either, so Xlib does it on Catflap's own connection.
///
/// Focus follows the panel's mode. Focused, it asks for the keyboard with the timestamp of
/// the key press that opened it, which window managers with focus-stealing prevention
/// (xfwm4) accept; opened without a key press (`catflap toggle`, a second launch) it uses the
/// server's current time. Hover and drag map it with a user time of 0, which tells the
/// window manager not to give it the keyboard.
final class X11Host: PanelHost {
    let desktop = "x11"
    let blurAvailable = false
    var onDrop: (([String]) -> Void)?
    private let connection: X11Connection
    private let bands: X11Bands
    private var window: OpaquePointer?
    private var xid: Window = 0
    private var listener: Int?
    private var requested: String?
    private var mode = PanelMode.hidden
    /// The monitor the shown panel belongs on, applied once the window manager has mapped it.
    private var target: X11Monitors.Monitor?
    /// The shortcuts, whose grabs sit on the panel's window while it has the keyboard.
    var shortcuts: [X11Shortcut] = []

    static var isSupported: Bool { X11Connection.gdkIsX11 }

    init(connection: X11Connection) {
        self.connection = connection
        bands = X11Bands(connection: connection)
    }

    func adopt(_ window: OpaquePointer) {
        self.window = window
        gtk_window_set_decorated(window.cast(), 0)
        gtk_widget_realize(window.cast())
        guard let surface = Self.surface(of: window), !connection.closed else { return }
        xid = gdk_x11_surface_get_xid(surface)
        GLib.connect(window, "notify::is-active", Int32(CF_SHAPE_NOTIFY)) { [weak self] _ in self?.keyboardChanged() }
        gdk_x11_surface_set_skip_taskbar_hint(surface, 1)
        gdk_x11_surface_set_skip_pager_hint(surface, 1)
        let display = connection.display
        var type = connection.atom("_NET_WM_WINDOW_TYPE_UTILITY")
        withUnsafeBytes(of: &type) { bytes in
            _ = XChangeProperty(display, xid, connection.atom("_NET_WM_WINDOW_TYPE"), Atom(XA_ATOM), 32, PropModeReplace,
                                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 1)
        }
        // The window manager maps the window once it has framed it; only then do a move and a
        // state request reach a managed window.
        XSelectInput(display, xid, StructureNotifyMask)
        listener = connection.listen { [weak self] event in
            guard let self, event.pointee.type == MapNotify, event.pointee.xmap.window == xid else { return }
            mapped()
        }
        connection.flush()
    }

    func present(_ window: OpaquePointer, mode next: PanelMode, display name: String?) {
        guard let surface = Self.surface(of: window) else { return }
        let visible = gtk_widget_get_visible(window.cast()) != 0
        let monitors = X11Monitors.all()
        let monitor = name.flatMap { wanted in monitors.first { $0.connector == wanted } } ?? pointerMonitor(monitors) ?? monitors.first
        let moved = visible && monitor?.connector != target?.connector
        requested = name
        target = monitor
        mode = next
        bands.panelVisible = true
        if next == .focused {
            let time = connection.activationTime ?? gdk_x11_get_server_time(surface)
            gdk_x11_surface_set_user_time(surface, time)
            gtk_window_present_with_time(window.cast(), time)
        } else if !visible {
            gdk_x11_surface_set_user_time(surface, 0)
            gtk_widget_set_visible(window.cast(), 1)
        }
        if moved { place() }
        // GDK's map request must reach the server before the window manager is asked about it.
        if let gdk = gdk_display_get_default() { XFlush(gdk_x11_display_get_xdisplay(gdk)) }
    }

    func withdraw(_ window: OpaquePointer) {
        gtk_widget_set_visible(window.cast(), 0)
        for shortcut in shortcuts { shortcut.move(to: 0) }
        mode = .hidden
        target = nil
        bands.panelVisible = false
    }

    func display(of window: OpaquePointer) -> String? {
        guard gtk_widget_get_visible(window.cast()) != 0, let surface = Self.surface(of: window),
              let gdk = gdk_display_get_default(), let monitor = gdk_display_get_monitor_at_surface(gdk, surface),
              let connector = gdk_monitor_get_connector(monitor) else { return target?.connector }
        return String(cString: connector)
    }

    func startTriggers(_ sink: @escaping (PanelMachine.Event) -> Void) { bands.start(sink: sink) }

    /// The agent is stopping: the bands go and the connection with them.
    func stopTriggers() {
        bands.stop()
        if let listener { connection.unlisten(listener) }
        listener = nil
        connection.close()
    }

    var triggerDisplays: [String] { bands.displays }

    /// `layer` is what the window manager reports: `above` once it keeps the panel above.
    func placement(of window: OpaquePointer) -> PanelPlacement {
        let visible = gtk_widget_get_visible(window.cast()) != 0
        let states = visible && !connection.closed ? connection.longs(xid, "_NET_WM_STATE", type: Atom(XA_ATOM)) : []
        return PanelPlacement(layer: states.contains(UInt(connection.atom("_NET_WM_STATE_ABOVE"))) ? "above" : "normal",
                              anchor: "top", exclusiveZone: 0, keyboard: mode == .focused ? "on_demand" : "none",
                              monitorRequested: requested)
    }

    /// The shortcuts' grabs follow the keyboard: on the panel's window while the panel has it,
    /// on the root window otherwise (see `X11Shortcut`).
    private func keyboardChanged() {
        guard let window else { return }
        let active = gtk_widget_get_visible(window.cast()) != 0 && gtk_window_is_active(window.cast()) != 0
        for shortcut in shortcuts { shortcut.move(to: active ? xid : 0) }
    }

    // MARK: Placing

    private func mapped() {
        guard mode != .hidden else { return }
        place()
        connection.addState(xid, ["_NET_WM_STATE_ABOVE", "_NET_WM_STATE_SKIP_TASKBAR", "_NET_WM_STATE_SKIP_PAGER"])
    }

    /// Top centre of the target monitor, below a panel that reserves the top edge.
    private func place() {
        guard let target, xid != 0, !connection.closed else { return }
        var attributes = XWindowAttributes()
        guard XGetWindowAttributes(connection.display, xid, &attributes) != 0 else { return }
        let frame = target.frame
        XMoveWindow(connection.display, xid, Int32(frame.x + (frame.width - Int(attributes.width)) / 2),
                    Int32(connection.usableTop(of: frame)))
        connection.flush()
    }

    private func pointerMonitor(_ monitors: [X11Monitors.Monitor]) -> X11Monitors.Monitor? {
        guard let point = connection.pointer() else { return nil }
        return monitors.first { $0.frame.contains(point.x, point.y) }
    }

    private static func surface(of window: OpaquePointer) -> OpaquePointer? {
        guard let native = gtk_widget_get_native(window.cast()) else { return nil }
        return gtk_native_get_surface(native)
    }
}
