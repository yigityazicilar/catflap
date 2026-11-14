import CGtk
import Foundation

/// The tray icon: a StatusNotifierItem on the session bus, which Plasma's system tray shows.
/// A left click (`Activate`) and a right click (`ContextMenu`) both open the panel in the
/// lower right corner; the item has no menu of its own. Its icon has five states.
// Touched only on the GTK thread, like the panel itself.
final class StatusNotifierItem: @unchecked Sendable {
    enum Glyph: String { case idle, moving, arrived, paused, problem }

    static let interface = "org.kde.StatusNotifierItem"
    static let watcher = "org.kde.StatusNotifierWatcher"
    static let path = "/StatusNotifierItem"
    private static let xml = """
    <node>
      <interface name="org.kde.StatusNotifierItem">
        <property name="Category" type="s" access="read"/>
        <property name="Id" type="s" access="read"/>
        <property name="Title" type="s" access="read"/>
        <property name="Status" type="s" access="read"/>
        <property name="WindowId" type="i" access="read"/>
        <property name="IconName" type="s" access="read"/>
        <property name="IconThemePath" type="s" access="read"/>
        <property name="IconPixmap" type="a(iiay)" access="read"/>
        <property name="OverlayIconName" type="s" access="read"/>
        <property name="AttentionIconName" type="s" access="read"/>
        <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
        <property name="ItemIsMenu" type="b" access="read"/>
        <property name="Menu" type="o" access="read"/>
        <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
        <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
        <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
        <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
        <signal name="NewIcon"/>
        <signal name="NewToolTip"/>
        <signal name="NewStatus"><arg name="status" type="s"/></signal>
      </interface>
    </node>
    """

    private unowned let controller: PanelController
    private var registration: UInt32 = 0
    private var watch: UInt32 = 0
    private var service: String?
    private var base: Glyph = .idle
    private(set) var glyph: Glyph = .idle
    /// `registered` once a tray host took the item, `waiting` while no tray runs, `unavailable`
    /// without a session bus.
    private(set) var state = "unavailable"
    private var context: Unmanaged<StatusNotifierItem>?

    init(controller: PanelController) {
        self.controller = controller
        start()
    }

    var iconName: String { "io.github.yigityazicilar.Catflap-\(glyph.rawValue)-symbolic" }

    /// The installed icons, found beside the executable (prefix/lib/catflap/catflap →
    /// prefix/share/icons), so a tray that does not look in the prefix still finds them.
    var iconThemePath: String {
        let executable = URL(fileURLWithPath: Autostart.executable)
        let icons = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/icons")
        return FileManager.default.fileExists(atPath: icons.path) ? icons.path : ""
    }

    private var tooltip: String {
        switch glyph {
        case .idle: "Ready"
        case .moving: "Sending or receiving"
        case .arrived: "Something arrived"
        case .paused: "Clipboard history is paused"
        case .problem: "A send needs your attention"
        }
    }

    private func start() {
        guard let bus = DBus.session, let info = g_dbus_node_info_new_for_xml(Self.xml, nil) else { return }
        let vtable = UnsafeMutablePointer<GDBusInterfaceVTable>.allocate(capacity: 1)
        vtable.initialize(to: GDBusInterfaceVTable())
        vtable.pointee.method_call = { _, _, _, _, method, _, invocation, data in
            guard let data, let method else { return }
            let item = Unmanaged<StatusNotifierItem>.fromOpaque(data).takeUnretainedValue()
            item.called(String(cString: method))
            g_dbus_method_invocation_return_value(invocation, nil)
        }
        vtable.pointee.get_property = { _, _, _, _, property, _, data in
            guard let data, let property else { return nil }
            let item = Unmanaged<StatusNotifierItem>.fromOpaque(data).takeUnretainedValue()
            return item.property(String(cString: property))
        }
        let context = Unmanaged.passRetained(self)
        self.context = context
        registration = g_dbus_connection_register_object(bus, Self.path, info.pointee.interfaces[0], vtable,
                                                         context.toOpaque(), nil, nil)
        g_dbus_node_info_unref(info)
        guard registration != 0 else { context.release(); self.context = nil; return }
        state = "waiting"
        let name = "org.kde.StatusNotifierItem-\(getpid())-1"
        let loop = controller.loop
        Task { [weak self] in
            let owned = await DBus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                                        DBus.tuple([DBus.s(name), DBus.u(4)]))
            await loop.perform { [weak self] in
                guard let self, registration != 0 else { return }
                service = owned != nil ? name : nil
                watchForTray()
            }
        }
    }

    /// Registers with the tray now, and again whenever a tray starts (Plasma restarting).
    private func watchForTray() {
        guard let bus = DBus.session, let context else { return }
        watch = g_bus_watch_name_on_connection(bus, Self.watcher, GBusNameWatcherFlags(rawValue: 0), { _, _, _, data in
            guard let data else { return }
            Unmanaged<StatusNotifierItem>.fromOpaque(data).takeUnretainedValue().register()
        }, { _, _, data in
            guard let data else { return }
            Unmanaged<StatusNotifierItem>.fromOpaque(data).takeUnretainedValue().state = "waiting"
        }, context.toOpaque(), nil)
    }

    private func register() {
        guard let service, registration != 0 else { return }
        let loop = controller.loop
        Task { [weak self] in
            let reply = await DBus.call(Self.watcher, "/StatusNotifierWatcher", Self.watcher, "RegisterStatusNotifierItem",
                                        DBus.tuple([DBus.s(service)]))
            await loop.perform { [weak self] in self?.state = reply != nil ? "registered" : "waiting" }
        }
    }

    func stop() {
        if watch != 0 { g_bus_unwatch_name(watch); watch = 0 }
        if let bus = DBus.session, registration != 0 { g_dbus_connection_unregister_object(bus, registration) }
        registration = 0
        context?.release()
        context = nil
        state = "unavailable"
    }

    private func called(_ method: String) {
        switch method {
        case "Activate", "ContextMenu", "SecondaryActivate":
            // Opens the panel focused in the corner; a second click closes it.
            if controller.machine.mode == .hidden { controller.open(from: "tray") }
            controller.handle(.hotkey(display: nil))
        default:
            break
        }
    }

    private func property(_ name: String) -> OpaquePointer? {
        let value: OpaquePointer
        switch name {
        case "Category": value = DBus.s("ApplicationStatus")
        case "Id": value = DBus.s("catflap")
        case "Title": value = DBus.s("Catflap")
        case "Status": value = DBus.s(glyph == .problem || glyph == .arrived ? "NeedsAttention" : "Active")
        case "WindowId": value = DBus.i(0)
        case "IconName": value = DBus.s(iconName)
        case "AttentionIconName": value = DBus.s(iconName)
        case "IconThemePath": value = DBus.s(iconThemePath)
        case "OverlayIconName": value = DBus.s("")
        case "IconPixmap": value = DBus.array("a(iiay)", [])
        case "ToolTip": value = DBus.tuple([DBus.s(iconName), DBus.array("a(iiay)", []), DBus.s("Catflap"), DBus.s(tooltip)])
        case "ItemIsMenu": value = DBus.b(false)
        case "Menu": value = DBus.o("/NO_DBUSMENU")
        default: return nil
        }
        return g_variant_ref_sink(value)
    }

    // MARK: Icon state, on the GTK thread

    func set(_ next: Glyph) {
        guard next != glyph else { return }
        glyph = next
        emit()
    }

    func update(paused: Bool) {
        base = paused ? .paused : .idle
        if glyph == .idle || glyph == .paused { set(base) }
    }

    /// Opening the panel shows what arrived or went wrong, so the icon goes back to rest.
    func panelOpened() {
        if glyph != .moving { set(base) }
    }

    private func emit() {
        guard let bus = DBus.session, registration != 0 else { return }
        for signal in ["NewIcon", "NewToolTip"] {
            g_dbus_connection_emit_signal(bus, nil, Self.path, Self.interface, signal, nil, nil)
        }
        let status = glyph == .problem || glyph == .arrived ? "NeedsAttention" : "Active"
        g_dbus_connection_emit_signal(bus, nil, Self.path, Self.interface, "NewStatus", DBus.tuple([DBus.s(status)]), nil)
    }
}
