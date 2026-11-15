import CAdwaita
import CGtk
import CGtkShim
import CX11

/// The hover band on X11: one input-only window per monitor at the top centre, below a panel
/// that reserves the top edge, which the pointer entering and leaving is reported for. An
/// input-only, override-redirect window draws nothing and no window manager frames, lists or
/// moves it. Other windows raised above it would hide it from the pointer, so it is raised
/// again whenever a managed window is mapped or restacked, but never above the panel itself.
///
/// It reports no file drags (X's drag protocol is not spoken here); the panel itself takes
/// dropped files once it is open.
final class X11Bands {
    private struct Band {
        let window: Window
        let display: String?
    }

    private let connection: X11Connection
    private var bands: [Band] = []
    private var sink: ((PanelMachine.Event) -> Void)?
    private var listener: Int?
    private var monitors: OpaquePointer?
    private var monitorsChanged: UInt = 0
    private var raisePending = false
    /// While the panel is shown the bands stay below it.
    var panelVisible = false {
        didSet { if !panelVisible { raise() } }
    }

    init(connection: X11Connection) { self.connection = connection }

    var displays: [String] { bands.compactMap(\.display) }

    func start(sink: @escaping (PanelMachine.Event) -> Void) {
        guard !connection.closed else { return }
        self.sink = sink
        let display = connection.display
        // Restacking and the work area, on the root window. Several clients may select these.
        XSelectInput(display, connection.root, SubstructureNotifyMask | PropertyChangeMask)
        listener = connection.listen { [weak self] event in self?.handle(event) }
        if let gdk = gdk_display_get_default(), let list = gdk_display_get_monitors(gdk) {
            monitors = list
            monitorsChanged = GLib.connect(list, "items-changed", Int32(CF_SHAPE_ITEMS)) { [weak self] _ in self?.rebuild() }
        }
        rebuild()
    }

    func stop() {
        if let monitors, monitorsChanged != 0 {
            g_signal_handler_disconnect(UnsafeMutableRawPointer(monitors), gulong(monitorsChanged))
        }
        monitorsChanged = 0
        monitors = nil
        if let listener { connection.unlisten(listener) }
        listener = nil
        destroyBands()
        sink = nil
    }

    private func destroyBands() {
        guard !connection.closed else { bands = []; return }
        for band in bands { XDestroyWindow(connection.display, band.window) }
        bands = []
        connection.flush()
    }

    private func rebuild() {
        destroyBands()
        guard !connection.closed else { return }
        let display = connection.display
        let width = Int(HoverBands.width), height = Int(HoverBands.height)
        for monitor in X11Monitors.all() {
            let frame = monitor.frame
            var attributes = XSetWindowAttributes()
            attributes.override_redirect = 1
            attributes.event_mask = EnterWindowMask | LeaveWindowMask
            let window = XCreateWindow(display, connection.root, Int32(frame.x + (frame.width - width) / 2),
                                       Int32(connection.usableTop(of: frame)), UInt32(width), UInt32(height), 0, 0,
                                       UInt32(InputOnly), nil, UInt(CWOverrideRedirect | CWEventMask), &attributes)
            var name = Array("catflap-band".utf8CString)
            name.withUnsafeMutableBufferPointer { _ = XStoreName(display, window, $0.baseAddress) }
            XMapRaised(display, window)
            bands.append(Band(window: window, display: monitor.connector))
        }
        connection.flush()
    }

    private func raise() {
        guard !connection.closed, !panelVisible else { return }
        for band in bands { XRaiseWindow(connection.display, band.window) }
        connection.flush()
    }

    /// Restacks come in bursts (a window being dragged); one raise per main-loop turn.
    private func raiseSoon() {
        guard !raisePending, !panelVisible else { return }
        raisePending = true
        GLib.idle { [weak self] in
            guard let self else { return }
            raisePending = false
            raise()
        }
    }

    private func handle(_ event: UnsafeMutablePointer<XEvent>) {
        switch event.pointee.type {
        case EnterNotify:
            let crossing = event.pointee.xcrossing
            guard crossing.mode == NotifyNormal, let band = bands.first(where: { $0.window == crossing.window }) else { return }
            // Over a full-screen window (a film, a game) the band is off, as the layer-shell
            // band sits below full-screen windows.
            guard !connection.activeWindowIsFullscreen() else { return }
            sink?(.bandEntered(display: band.display))
        case LeaveNotify:
            let crossing = event.pointee.xcrossing
            guard crossing.mode == NotifyNormal, bands.contains(where: { $0.window == crossing.window }) else { return }
            sink?(.bandLeft)
        case MapNotify:
            let map = event.pointee.xmap
            if map.event == connection.root, map.override_redirect == 0, !bands.contains(where: { $0.window == map.window }) { raiseSoon() }
        case ConfigureNotify:
            let configure = event.pointee.xconfigure
            if configure.event == connection.root, configure.override_redirect == 0,
               !bands.contains(where: { $0.window == configure.window }) { raiseSoon() }
        case PropertyNotify:
            let property = event.pointee.xproperty
            if property.window == connection.root, property.atom == connection.atom("_NET_WORKAREA") { rebuild() }
        default:
            break
        }
    }
}
