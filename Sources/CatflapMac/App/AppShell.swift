#if os(macOS)
import AppKit

/// The agent's AppKit side: an accessory application (no Dock or app-switcher entry) whose
/// event loop runs on the main thread beside the agent's own work.
///
/// The agent's `@main` is async, so the main thread already runs the main run loop and drains
/// the main queue. `NSApplication.run()` is started from a run-loop block rather than from a
/// main-queue job: a run loop nested inside a main-queue job does not drain the main queue, so
/// every later main-actor task would wait. Started this way it drains it, and main-actor work
/// (the clipboard watcher, the panel, control requests) goes on while AppKit runs.
@MainActor
final class AppShell: NSObject, NSApplicationDelegate {
    private(set) var running = false
    private var stopping = false

    func start() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                guard !self.stopping else { return }
                NSApplication.shared.run()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func applicationDidFinishLaunching(_ notification: Notification) { running = true }

    /// How often the system activated the app. The panel never asks for it, so this stays 0.
    /// (`NSApplication.isActive` is no measure: AppKit sets it while a non-activating panel is
    /// key, though the system's frontmost app does not change and no activation happens.)
    private(set) var activations = 0
    func applicationDidBecomeActive(_ notification: Notification) { activations += 1 }

    /// A quit from the system (log out, restart) goes through the agent's own shutdown, which
    /// stops the panel and the run loop, instead of AppKit ending the process at once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        kill(getpid(), SIGTERM)
        return .terminateLater
    }

    func stop() {
        stopping = true
        guard running else { return }
        running = false
        let app = NSApplication.shared
        app.stop(nil)
        // `stop` takes effect after the next event; post one so the loop returns now.
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            app.postEvent(wake, atStart: true)
        }
    }
}
#endif
