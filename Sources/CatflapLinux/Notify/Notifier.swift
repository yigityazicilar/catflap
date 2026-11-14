import CGtk
import CatflapCore
import Foundation

/// Desktop notifications through org.freedesktop.Notifications, which KDE Plasma and GNOME
/// both serve. Arrivals are quiet: low urgency, no sound, one action (Copy for text, Show in
/// folder for a file). A failed send says why, with Retry where the agent can retry.
// Touched only on the GTK thread, like the panel itself.
final class Notifier: @unchecked Sendable {
    static let name = "org.freedesktop.Notifications"
    static let path = "/org/freedesktop/Notifications"

    enum Action: Sendable {
        case copy(TransferRecord)
        case reveal(String)
        case retry(deviceID: String, id: String)
    }

    private unowned let controller: PanelController
    private var actions: [UInt32: Action] = [:]
    private var subscription: UInt32 = 0
    private var closed: UInt32 = 0
    /// What was shown, newest last, for `ui invoke describe` and tests: title and actions only.
    private(set) var shown: [String] = []

    init(controller: PanelController) {
        self.controller = controller
        subscription = DBus.subscribe(sender: Self.name, interface: Self.name, member: "ActionInvoked", path: Self.path) { [weak self] parameters in
            let id = DBus.uint32(parameters, 0)
            let action = DBus.string(parameters, 1)
            self?.invoked(id, action)
        }
        closed = DBus.subscribe(sender: Self.name, interface: Self.name, member: "NotificationClosed", path: Self.path) { [weak self] parameters in
            let id = DBus.uint32(parameters, 0)
            self?.actions[id] = nil
        }
    }

    func stop() {
        DBus.unsubscribe(subscription)
        DBus.unsubscribe(closed)
        subscription = 0
        closed = 0
    }

    /// Something arrived from `device`.
    func arrived(_ record: TransferRecord, from device: String) {
        let title = record.kind == "text" ? "Text from \(device)" : "File from \(device)"
        let body: String
        let action: (String, String, Action)?
        if record.kind == "text" {
            body = record.text.map(PanelText.preview(line:)) ?? "Not kept. Copy it within ten minutes."
            action = ("copy", "Copy", .copy(record))
        } else {
            let name = record.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? record.targetName ?? "A file"
            body = name + ", in your Catflap inbox"
            action = record.path.map { ("reveal", "Show in folder", .reveal($0)) }
        }
        post(title: title, body: body, action: action, urgency: 0)
    }

    /// A send that did not reach the other device, or a send that was refused before it began.
    func problem(title: String, body: String, retry: (deviceID: String, id: String)? = nil) {
        post(title: title, body: body, action: retry.map { ("retry", "Retry", .retry(deviceID: $0.deviceID, id: $0.id)) }, urgency: 1)
    }

    private func post(title: String, body: String, action: (key: String, label: String, value: Action)?, urgency: UInt8) {
        shown.append(title + (action.map { " [\($0.key)]" } ?? ""))
        if shown.count > 20 { shown.removeFirst() }
        let hints = DBus.dictionary([
            ("urgency", DBus.byte(urgency)),
            ("suppress-sound", DBus.b(true)),
            ("desktop-entry", DBus.s(GlobalShortcut.applicationID)),
            ("category", DBus.s(urgency == 0 ? "transfer.complete" : "transfer.error")),
        ])
        let parameters = DBus.tuple([
            DBus.s("Catflap"), DBus.u(0), DBus.s(GlobalShortcut.applicationID), DBus.s(title), DBus.s(body),
            DBus.strings(action.map { [$0.key, $0.label] } ?? []), hints, DBus.i(-1),
        ])
        let loop = controller.loop
        let value = action?.value
        Task { [weak self] in
            guard let reply = await DBus.call(Self.name, Self.path, Self.name, "Notify", parameters) else { return }
            let id = reply.uint32(0)
            guard let value else { return }
            await loop.perform { [weak self] in self?.actions[id] = value }
        }
    }

    private func invoked(_ id: UInt32, _ key: String) {
        guard let action = actions[id] else { return }
        switch action {
        case .copy(let record) where key == "copy":
            controller.sender.copy(record)
        case .reveal(let path) where key == "reveal" || key == "default":
            reveal(path)
        case .retry(let device, let transfer) where key == "retry":
            controller.sender.retry(deviceID: device, id: transfer)
        default:
            break
        }
    }

    /// Shows a file selected in the file manager, or opens its folder where no file manager
    /// answers the FileManager1 interface.
    func reveal(_ path: String) {
        let uri = URL(fileURLWithPath: path).absoluteString
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().absoluteString
        let loop = controller.loop
        Task {
            let shown = await DBus.call("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1",
                                        "ShowItems", DBus.tuple([DBus.strings([uri]), DBus.s("")]))
            if shown == nil { await loop.perform { _ = g_app_info_launch_default_for_uri(folder, nil, nil) } }
        }
    }
}
