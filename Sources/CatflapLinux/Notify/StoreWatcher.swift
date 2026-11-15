import CGtk
import CGtkShim
import CatflapCore
import Foundation

/// Watches the agent's database for what happens without the panel: something arriving, a
/// send that ends (from the panel, the send-clipboard shortcut, the file manager's menu or
/// the command line), and devices paired, renamed or removed. File events, not a timer, so
/// an idle agent does no work.
// Touched only on the GTK thread, like the panel itself.
final class StoreWatcher: @unchecked Sendable {
    private unowned let controller: PanelController
    private var monitor: OpaquePointer?
    private var pending: UInt32 = 0
    private var seeded = false
    private var known: [String: String] = [:]
    private var devices: [DeviceSummary] = []
    /// Whether `devices` holds a list the agent answered with, not the empty one it starts as.
    private var devicesRead = false
    /// Sends the panel started and reports itself while it is shown.
    private var fromPanel: Set<String> = []
    private var reading = false
    private var again = false
    private var task: Task<Void, Never>?

    init(controller: PanelController) { self.controller = controller }

    func start() {
        let directory = g_file_new_for_path(controller.dataDirectory.path)
        defer { g_object_unref(UnsafeMutableRawPointer(directory)) }
        if let monitor = g_file_monitor_directory(directory, GFileMonitorFlags(rawValue: 0), nil, nil) {
            self.monitor = OpaquePointer(monitor)
            GLib.connect(OpaquePointer(monitor), "changed", Int32(CF_SHAPE_FILE)) { [weak self] event in
                guard let self, let name = event.pointee.text.map({ String(cString: $0) }), name.hasPrefix("store.sqlite") else { return }
                schedule()
            }
        }
        read()
    }

    func stop() {
        task?.cancel()
        if pending != 0 { GLib.cancel(pending); pending = 0 }
        if let monitor {
            g_file_monitor_cancel(monitor.cast())
            g_object_unref(UnsafeMutableRawPointer(monitor))
        }
        monitor = nil
    }

    func panelSent(deviceID: String, id: String) { fromPanel.insert(deviceID + "/" + id) }

    func devicesMayHaveChanged() { schedule() }

    private func schedule() {
        guard pending == 0 else { return }
        pending = GLib.timeout(milliseconds: 150) { [weak self] in
            self?.pending = 0
            self?.read()
        }
    }

    private func read() {
        guard !controller.stopped else { return }
        if reading { again = true; return }
        reading = true
        let runtime = controller.runtime, loop = controller.loop
        let snapshot = known
        task = Task { [weak self] in
            async let history = PanelController.read([TransferRecord].self, list: "history", "history", runtime)
            async let paired = PanelController.read([DeviceSummary].self, list: "devices", "devices", runtime)
            let rows = await history, list = await paired
            var reasons: [String: String] = [:]
            // The sentence a failed send ended with is held in memory, not stored.
            for row in rows ?? [] where row.direction == "sent" && row.canRetry && snapshot[row.deviceID + "/" + row.id] != row.status {
                if let status = await PanelController.request(TransferRecord.self, "send.status", runtime,
                                                              ["device_id": row.deviceID, "id": row.id]), let error = status.error {
                    reasons[row.deviceID + "/" + row.id] = error
                }
            }
            let found = reasons
            await loop.perform { [weak self] in
                guard let self, !controller.stopped else { return }
                apply(rows, list, found)
                reading = false
                if again { again = false; read() }
            }
        }
    }

    /// Nil for a list that could not be read: it is left as it was, and compared again at the
    /// next read that works.
    private func apply(_ rows: [TransferRecord]?, _ list: [DeviceSummary]?, _ reasons: [String: String]) {
        let visible = controller.machine.mode != .hidden
        // Only the agent's answer rewrites the file manager's menu and the settings rows, so a
        // failed read never takes the devices out of them.
        if let list, list.map({ $0.id + "\u{0}" + $0.name }) != devices.map({ $0.id + "\u{0}" + $0.name }) || !devicesRead {
            devices = list
            devicesRead = true
            ServiceMenu.write(devices: list, executable: Autostart.executable)
            controller.settingsPage?.update(devices: list.map { PanelDevice(id: $0.id, name: $0.name) })
        }
        var sending = false
        for row in rows ?? [] {
            let key = row.deviceID + "/" + row.id
            let before = known[key]
            known[key] = row.status
            if row.status == "sending" { sending = true }
            guard seeded, before != row.status else { continue }
            let name = devices.first { $0.id == row.deviceID }?.name ?? "the other device"
            if row.direction == "received", row.status == "ok" {
                controller.tray.set(.arrived)
                controller.notifier.arrived(row, from: name)
                if row.kind == "text" && controller.settings.receivedTextToClipboard { controller.sender.copy(row) }
            } else if row.direction == "sent", row.status == "ok", before == "sending" {
                if !visible { controller.tray.set(.arrived) }
            } else if row.direction == "sent", row.canRetry {
                controller.tray.set(.problem)
                // The panel says this itself while it is shown.
                if fromPanel.contains(key) && visible { continue }
                let reason = reasons[key] ?? (row.status == "unconfirmed" ? "\(name) may not have it." : "Not sent.")
                let removed = reason.hasPrefix("Cannot reach") ? " If \(name) removed this device, remove it in Catflap's settings." : ""
                controller.notifier.problem(title: "Not sent to \(name)", body: reason + removed, retry: (row.deviceID, row.id))
            }
        }
        if sending { controller.tray.set(.moving) }
        if rows != nil { seeded = true }
        if visible { controller.refresh() }
    }
}
