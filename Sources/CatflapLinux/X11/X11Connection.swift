import CGtk
import CX11
import Foundation

/// X errors on Catflap's own X connections. Xlib reports every error of the process to one
/// handler. GDK installs its own when it opens its display and ignores errors on connections
/// it did not open, so a request of Catflap's that fails (a key another client has grabbed)
/// never ends the agent. Catflap installs its handler only around requests that may fail,
/// on the thread that runs them, and puts the previous handler back afterwards; an error on
/// a connection that is not Catflap's goes on to that previous handler.
enum X11Errors {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var codes: [UInt: UInt8] = [:]
    nonisolated(unsafe) private static var previous: XErrorHandler?

    private static let handler: XErrorHandler = { display, error in
        guard let display, let error else { return 0 }
        let key = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(display)))
        X11Errors.lock.lock()
        let ours = X11Errors.codes[key] != nil
        if ours { X11Errors.codes[key] = error.pointee.error_code }
        let next = X11Errors.previous
        X11Errors.lock.unlock()
        if !ours, let next { return next(display, error) }
        return 0
    }

    /// Runs `body`, waits until the server has answered every request it made, and returns
    /// the code of the last X error those requests caused, or 0 for none.
    static func trap(_ display: OpaquePointer, _ body: () -> Void) -> UInt8 {
        let key = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(display)))
        XSync(display, 0)
        lock.lock()
        codes[key] = 0
        lock.unlock()
        let replaced = XSetErrorHandler(handler)
        lock.lock()
        if !same(replaced, handler) { previous = replaced }
        lock.unlock()
        body()
        XSync(display, 0)
        XSetErrorHandler(replaced)
        lock.lock()
        let code = codes.removeValue(forKey: key) ?? 0
        lock.unlock()
        return code
    }

    /// Marks a connection whose errors are expected and ignored for as long as it is open: a
    /// clipboard owner that goes away while Catflap reads from it is not a fault.
    static func ignore(_ display: OpaquePointer) {
        let key = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(display)))
        lock.lock()
        codes[key] = 0
        lock.unlock()
        let replaced = XSetErrorHandler(handler)
        lock.lock()
        if !same(replaced, handler) { previous = replaced }
        lock.unlock()
    }

    static func forget(_ display: OpaquePointer) {
        let key = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(display)))
        lock.lock()
        codes[key] = nil
        lock.unlock()
    }

    private static func same(_ a: XErrorHandler?, _ b: XErrorHandler) -> Bool {
        guard let a else { return false }
        return unsafeBitCast(a, to: UnsafeRawPointer.self) == unsafeBitCast(b, to: UnsafeRawPointer.self)
    }
}

/// Catflap's own connection to the X server of GDK's display, for what GTK 4 has no API for:
/// keeping the panel above other windows and placing it, the hover bands, and the global
/// key grabs. Its events are read on the GTK thread, from the GLib main loop; every method
/// is called there too.
final class X11Connection {
    let display: OpaquePointer
    let root: Window
    private var source: UInt32 = 0
    private var listeners: [Int: (UnsafeMutablePointer<XEvent>) -> Void] = [:]
    private var nextListener = 0
    private var atoms: [String: Atom] = [:]
    private(set) var closed = false
    /// The time of the key press that is opening the panel right now, while its handler
    /// runs: the panel asks for the keyboard with the input's own timestamp.
    var activationTime: UInt32?

    private init(display: OpaquePointer) {
        self.display = display
        root = XDefaultRootWindow(display)
    }

    /// Whether GDK runs on an X server. Under Wayland GDK opens only the Wayland display,
    /// so an X display the session inherited is never taken for the desktop.
    static var gdkIsX11: Bool {
        guard let gdk = gdk_display_get_default() else { return false }
        return g_type_check_instance_is_a(UnsafeMutableRawPointer(gdk).assumingMemoryBound(to: GTypeInstance.self),
                                          gdk_x11_display_get_type()) != 0
    }

    /// Opens a connection to GDK's X server and reads it from the GLib main loop. Nil when
    /// GDK is not on X11 or the server refuses.
    static func open() -> X11Connection? {
        guard gdkIsX11, let gdk = gdk_display_get_default(), let display = XOpenDisplay(gdk_display_get_name(gdk)) else {
            return nil
        }
        let connection = X11Connection(display: display)
        // Held keys repeat as presses alone, without a release between, so a shortcut held
        // down toggles once.
        _ = XkbSetDetectableAutoRepeat(display, 1, nil)
        let context = Unmanaged.passUnretained(connection).toOpaque()
        connection.source = g_unix_fd_add_full(G_PRIORITY_DEFAULT, XConnectionNumber(display), G_IO_IN, { _, _, data in
            guard let data else { return 0 }
            Unmanaged<X11Connection>.fromOpaque(data).takeUnretainedValue().dispatch()
            return 1
        }, context, nil)
        return connection
    }

    func close() {
        guard !closed else { return }
        closed = true
        if source != 0 { g_source_remove(source) }
        source = 0
        listeners = [:]
        XCloseDisplay(display)
    }

    func atom(_ name: String) -> Atom {
        if let known = atoms[name] { return known }
        let value = XInternAtom(display, name, 0)
        atoms[name] = value
        return value
    }

    @discardableResult
    func listen(_ body: @escaping (UnsafeMutablePointer<XEvent>) -> Void) -> Int {
        nextListener += 1
        listeners[nextListener] = body
        return nextListener
    }

    func unlisten(_ id: Int) { listeners[id] = nil }

    /// Hands every event Xlib holds to the listeners. Requests that wait for a reply can
    /// read events into Xlib's queue without the socket becoming readable again, so code
    /// that makes such requests calls this afterwards.
    func dispatch() {
        guard !closed else { return }
        while !closed && XPending(display) > 0 {
            var event = XEvent()
            XNextEvent(display, &event)
            for listener in listeners.values { listener(&event) }
        }
    }

    /// Sends what is buffered and handles any events that arrived meanwhile.
    func flush() {
        guard !closed else { return }
        XFlush(display)
        GLib.idle { [weak self] in self?.dispatch() }
    }

    // MARK: Properties

    /// A property of 32-bit items (atoms, cardinals, windows), as Xlib returns them: one C
    /// long per item.
    func longs(_ window: Window, _ property: String, type: Atom = Atom(AnyPropertyType)) -> [UInt] {
        var actual: Atom = 0
        var format: Int32 = 0
        var count: UInt = 0
        var after: UInt = 0
        var data: UnsafeMutablePointer<UInt8>?
        var result: [UInt] = []
        let code = X11Errors.trap(display) {
            guard XGetWindowProperty(display, window, atom(property), 0, 4096, 0, type, &actual, &format, &count, &after, &data) == Success,
                  let data, format == 32 else { return }
            let items = UnsafeRawPointer(data).assumingMemoryBound(to: UInt.self)
            result = (0..<Int(count)).map { items[$0] }
        }
        if let data { XFree(data) }
        dispatch()
        return code == 0 ? result : []
    }

    /// Asks the window manager to add `states` to a mapped toplevel's _NET_WM_STATE.
    func addState(_ window: Window, _ states: [String]) {
        var index = 0
        while index < states.count {
            var event = XEvent()
            event.xclient.type = ClientMessage
            event.xclient.serial = 0
            event.xclient.send_event = 1
            event.xclient.display = display
            event.xclient.window = window
            event.xclient.message_type = atom("_NET_WM_STATE")
            event.xclient.format = 32
            event.xclient.data.l.0 = 1 // _NET_WM_STATE_ADD
            event.xclient.data.l.1 = Int(bitPattern: atom(states[index]))
            event.xclient.data.l.2 = index + 1 < states.count ? Int(bitPattern: atom(states[index + 1])) : 0
            event.xclient.data.l.3 = 1 // a normal application asks
            XSendEvent(display, root, 0, SubstructureRedirectMask | SubstructureNotifyMask, &event)
            index += 2
        }
        flush()
    }

    // MARK: Screen

    struct Rect: Equatable {
        var x: Int, y: Int, width: Int, height: Int
        func contains(_ px: Int, _ py: Int) -> Bool { px >= x && px < x + width && py >= y && py < y + height }
    }

    /// The top of the area windows may use on `monitor`, below a panel that reserves the top
    /// edge (the work area the window manager publishes); the monitor's own top otherwise.
    func usableTop(of monitor: Rect) -> Int {
        let area = longs(root, "_NET_WORKAREA", type: Atom(XA_CARDINAL))
        let desktop = longs(root, "_NET_CURRENT_DESKTOP", type: Atom(XA_CARDINAL)).first.map { Int($0) } ?? 0
        guard area.count >= (desktop + 1) * 4 else { return monitor.y }
        let top = Int(area[desktop * 4 + 1])
        return top > monitor.y && top < monitor.y + monitor.height ? top : monitor.y
    }

    /// Where the pointer is, in root coordinates.
    func pointer() -> (x: Int, y: Int)? {
        var rootReturn: Window = 0, child: Window = 0
        var rootX: Int32 = 0, rootY: Int32 = 0, winX: Int32 = 0, winY: Int32 = 0
        var mask: UInt32 = 0
        guard XQueryPointer(display, root, &rootReturn, &child, &rootX, &rootY, &winX, &winY, &mask) != 0 else { return nil }
        dispatch()
        return (Int(rootX), Int(rootY))
    }

    /// Whether the active window covers its monitor (a film, a game, a presentation).
    func activeWindowIsFullscreen() -> Bool {
        guard let active = longs(root, "_NET_ACTIVE_WINDOW", type: Atom(XA_WINDOW)).first, active != 0 else { return false }
        return longs(Window(active), "_NET_WM_STATE", type: Atom(XA_ATOM)).contains(UInt(atom("_NET_WM_STATE_FULLSCREEN")))
    }
}

/// GDK's monitors, in X coordinates.
enum X11Monitors {
    struct Monitor {
        let connector: String?
        let frame: X11Connection.Rect
    }

    static func all() -> [Monitor] {
        guard let display = gdk_display_get_default(), let list = gdk_display_get_monitors(display) else { return [] }
        var result: [Monitor] = []
        for index in 0..<g_list_model_get_n_items(list) {
            guard let item = g_list_model_get_item(list, index) else { continue }
            let monitor = OpaquePointer(item)
            var area = GdkRectangle()
            gdk_monitor_get_geometry(monitor, &area)
            let scale = Int(max(1, gdk_monitor_get_scale_factor(monitor)))
            result.append(Monitor(connector: gdk_monitor_get_connector(monitor).map { String(cString: $0) },
                                  frame: .init(x: Int(area.x) * scale, y: Int(area.y) * scale,
                                               width: Int(area.width) * scale, height: Int(area.height) * scale)))
            g_object_unref(item)
        }
        return result
    }
}
