import CGtk
import Foundation

/// Small helpers over GDBus for notifications, the file manager and the tray item. GVariant's
/// variadic constructors cannot be called from Swift, so values are built piece by piece.
/// Values are GVariant pointers; a new one is floating until a call or a container takes it.
enum DBus {
    /// The session bus the agent was started with; nil without one.
    nonisolated(unsafe) static let session: OpaquePointer? = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil)

    static func s(_ value: String) -> OpaquePointer { g_variant_new_string(value) }
    static func u(_ value: UInt32) -> OpaquePointer { g_variant_new_uint32(value) }
    static func i(_ value: Int32) -> OpaquePointer { g_variant_new_int32(value) }
    static func b(_ value: Bool) -> OpaquePointer { g_variant_new_boolean(value ? 1 : 0) }
    static func byte(_ value: UInt8) -> OpaquePointer { g_variant_new_byte(value) }
    static func o(_ value: String) -> OpaquePointer { g_variant_new_object_path(value) }
    static func v(_ value: OpaquePointer) -> OpaquePointer { g_variant_new_variant(value) }

    static func strings(_ values: [String]) -> OpaquePointer {
        array("as", values.map(s))
    }

    /// `a{sv}` from values already wrapped in their GVariant types.
    static func dictionary(_ entries: [(String, OpaquePointer)]) -> OpaquePointer {
        array("a{sv}", entries.map { g_variant_new_dict_entry(s($0.0), v($0.1)) })
    }

    /// An array of a type such as `as` or `a(iiay)`, from built elements.
    static func array(_ type: String, _ elements: [OpaquePointer]) -> OpaquePointer {
        let builder = g_variant_builder_new(g_variant_type_checked_(type))
        defer { g_variant_builder_unref(builder) }
        for element in elements { g_variant_builder_add_value(builder, element) }
        return g_variant_builder_end(builder)
    }

    static func tuple(_ children: [OpaquePointer]) -> OpaquePointer {
        var list: [OpaquePointer?] = children
        return list.withUnsafeMutableBufferPointer { g_variant_new_tuple($0.baseAddress, gsize($0.count)) }
    }

    /// Child `index` of a container. The caller owns the result.
    static func child(_ variant: OpaquePointer, _ index: Int) -> OpaquePointer {
        g_variant_get_child_value(variant, gsize(index))
    }

    static func string(_ variant: OpaquePointer) -> String {
        String(cString: g_variant_get_string(variant, nil))
    }

    static func uint32(_ variant: OpaquePointer, _ index: Int) -> UInt32 {
        let value = child(variant, index)
        defer { g_variant_unref(value) }
        return g_variant_get_uint32(value)
    }

    static func string(_ variant: OpaquePointer, _ index: Int) -> String {
        let value = child(variant, index)
        defer { g_variant_unref(value) }
        return string(value)
    }

    /// A method call that waits for the reply, on a thread of its own so neither the GTK
    /// thread nor Swift's pool waits on the bus. Nil when the call fails.
    static func call(_ name: String, _ path: String, _ interface: String, _ method: String, _ parameters: OpaquePointer?,
                     timeout: Int32 = 10_000) async -> Reply? {
        let held = parameters.map { g_variant_ref_sink($0)! }
        guard let bus = session else {
            if let held { g_variant_unref(held) }
            return nil
        }
        let message = Request(bus: bus, name: name, path: path, interface: interface, method: method, parameters: held, timeout: timeout)
        return await withCheckedContinuation { (result: CheckedContinuation<Reply?, Never>) in
            Thread.detachNewThread {
                let reply = g_dbus_connection_call_sync(message.bus, message.name, message.path, message.interface, message.method,
                                                        message.parameters, nil, GDBusCallFlags(rawValue: 0), message.timeout, nil, nil)
                if let parameters = message.parameters { g_variant_unref(parameters) }
                result.resume(returning: reply.map(Reply.init))
            }
        }
    }

    private struct Request: @unchecked Sendable {
        let bus: OpaquePointer
        let name: String, path: String, interface: String, method: String
        let parameters: OpaquePointer?
        let timeout: Int32
    }

    /// A reply's value, released when it goes.
    final class Reply: @unchecked Sendable {
        let value: OpaquePointer
        init(_ value: OpaquePointer) { self.value = value }
        deinit { g_variant_unref(value) }
        func uint32(_ index: Int) -> UInt32 { DBus.uint32(value, index) }
    }

    /// Delivers a signal on the GTK thread (the thread that subscribes owns the default main
    /// context). `body` gets the parameters tuple.
    static func subscribe(sender: String?, interface: String, member: String?, path: String?,
                          _ body: @escaping (OpaquePointer) -> Void) -> UInt32 {
        guard let bus = session else { return 0 }
        let box = Unmanaged.passRetained(SignalCallback(body)).toOpaque()
        return g_dbus_connection_signal_subscribe(bus, sender, interface, member, path, nil, GDBusSignalFlags(rawValue: 0), {
            _, _, _, _, _, parameters, data in
            guard let data, let parameters else { return }
            Unmanaged<SignalCallback>.fromOpaque(data).takeUnretainedValue().body(parameters)
        }, box, { data in
            guard let data else { return }
            Unmanaged<SignalCallback>.fromOpaque(data).release()
        })
    }

    static func unsubscribe(_ id: UInt32) {
        guard let bus = session, id != 0 else { return }
        g_dbus_connection_signal_unsubscribe(bus, id)
    }
}

final class SignalCallback {
    let body: (OpaquePointer) -> Void
    init(_ body: @escaping (OpaquePointer) -> Void) { self.body = body }
}
