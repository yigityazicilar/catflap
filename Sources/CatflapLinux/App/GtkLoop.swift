import CAdwaita
import CGtk
import CGtkShim
import Foundation

/// Runs GTK on a thread of its own. The agent's main thread belongs to Swift concurrency, and
/// GTK wants one thread that owns the GLib default main context; every GTK call in this module
/// happens on that thread, inside `perform` or inside a signal or timer callback.
final class GtkLoop: @unchecked Sendable {
    private let ended = DispatchSemaphore(value: 0)
    private var loop: OpaquePointer?
    private var thread: pthread_t?

    /// Starts GTK on its own thread. Nil if no Wayland display can be opened.
    static func start() async -> GtkLoop? {
        let loop = GtkLoop()
        let started = await withCheckedContinuation { (ready: CheckedContinuation<Bool, Never>) in
            let thread = Thread { loop.run(ready) }
            thread.name = "catflap-gtk"
            thread.start()
        }
        return started ? loop : nil
    }

    private func run(_ ready: CheckedContinuation<Bool, Never>) {
        // Only Wayland: an X11 fallback would bypass layer-shell and could reach a display the
        // agent was not given.
        gdk_set_allowed_backends("wayland")
        // The names screen readers and the compositor show for the agent's windows.
        g_set_prgname("catflap")
        g_set_application_name("Catflap")
        guard gtk_init_check() != 0 else {
            ready.resume(returning: false)
            ended.signal()
            return
        }
        adw_init()
        thread = pthread_self()
        loop = g_main_loop_new(nil, 0)
        ready.resume(returning: true)
        g_main_loop_run(loop)
        g_main_loop_unref(loop)
        loop = nil
        ended.signal()
    }

    var isCurrent: Bool { thread.map { pthread_equal($0, pthread_self()) != 0 } ?? false }

    /// Runs `body` on the GTK thread and returns its result.
    func perform<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            GLib.idle { continuation.resume(returning: body()) }
        }
    }

    /// Quits the loop and waits for the thread to finish, at most `limit`.
    func stop(limit: Duration = .seconds(3)) async {
        await perform { [self] in if let loop { g_main_loop_quit(loop) } }
        let ended = self.ended
        let seconds = Double(limit.components.seconds)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = ended.wait(timeout: .now() + seconds)
                done.resume()
            }
        }
    }
}

/// Swift closures behind the C trampolines in CGtkShim.
final class Callback: @unchecked Sendable {
    let body: (UnsafeMutablePointer<cf_event>) -> Void
    init(_ body: @escaping (UnsafeMutablePointer<cf_event>) -> Void) { self.body = body }
}

private let dispatchCallback: cf_handler = { context, event in
    guard let context, let event else { return }
    Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue().body(event)
}
private let releaseCallback: cf_release = { context in
    guard let context else { return }
    Unmanaged<Callback>.fromOpaque(context).release()
}

enum GLib {
    static func retained(_ body: @escaping (UnsafeMutablePointer<cf_event>) -> Void) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(Callback(body)).toOpaque()
    }

    @discardableResult
    static func connect(_ instance: OpaquePointer, _ signal: String, _ shape: Int32,
                        _ body: @escaping (UnsafeMutablePointer<cf_event>) -> Void) -> UInt {
        UInt(cf_connect(UnsafeMutableRawPointer(instance), signal, shape, dispatchCallback, retained(body), releaseCallback))
    }

    static func idle(_ body: @escaping () -> Void) {
        cf_idle(dispatchCallback, retained { _ in body() }, releaseCallback)
    }

    /// A one-shot timer on the GTK thread; returns its source id.
    static func timeout(milliseconds: Int, _ body: @escaping () -> Void) -> UInt32 {
        cf_timeout(UInt32(milliseconds), dispatchCallback, retained { _ in body() }, releaseCallback)
    }

    static func cancel(_ source: UInt32) { cf_source_remove(source) }

    static var handler: cf_handler { dispatchCallback }
    static var release: cf_release { releaseCallback }
}

/// GTK pointers travel as `OpaquePointer`; `cast()` turns one into the typed pointer a
/// function wants where the C type is a complete struct.
extension OpaquePointer {
    func cast<T>() -> UnsafeMutablePointer<T> { UnsafeMutablePointer<T>(self) }
}

func opaque<T>(_ pointer: UnsafeMutablePointer<T>?) -> OpaquePointer {
    OpaquePointer(pointer!)
}

func opaque(_ pointer: OpaquePointer?) -> OpaquePointer { pointer! }
