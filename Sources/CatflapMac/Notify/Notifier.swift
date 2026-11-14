#if os(macOS)
import AppKit
import UserNotifications

/// Notifications for what happens while the panel is out of the way: something arrived, or a
/// send did not reach the other device. Arrivals are quiet (no sound) and offer one action,
/// Copy for text or Reveal for a file; a failed send says why and offers Retry where the agent
/// can retry it.
///
/// Notification Center serves app bundles only. A bare `catflap agent` (tests, a development
/// build) records what it would have shown and posts nothing.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Action: Sendable, Equatable {
        case copy(deviceID: String, id: String)
        case reveal(String)
        case retry(deviceID: String, id: String)
        var key: String {
            switch self {
            case .copy: "copy"
            case .reveal: "reveal"
            case .retry: "retry"
            }
        }
    }

    /// What was shown, newest last: title, body, the action offered, and whether it went to
    /// Notification Center.
    struct Record: Codable, Sendable, Equatable {
        var title: String
        var body: String
        var action: String?
        var delivered: Bool
    }

    private(set) var shown: [Record] = []
    var perform: ((Action) -> Void)?
    private var actions: [String: Action] = [:]
    private let center: UNUserNotificationCenter?

    static var canDeliver: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    override init() {
        center = Self.canDeliver ? UNUserNotificationCenter.current() : nil
        super.init()
        guard let center else { return }
        center.delegate = self
        let copy = UNNotificationAction(identifier: "copy", title: "Copy", options: [])
        let reveal = UNNotificationAction(identifier: "reveal", title: "Reveal", options: [])
        let retry = UNNotificationAction(identifier: "retry", title: "Retry", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "copy", actions: [copy], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "reveal", actions: [reveal], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "retry", actions: [retry], intentIdentifiers: [], options: []),
        ])
        // Asked once; macOS shows its prompt the first time only, and remembers the answer.
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// Text or a file arrived from `device`.
    func arrived(kind: String, text: String?, fileName: String?, path: String?, deviceID: String, id: String, from device: String) {
        if kind == "text" {
            let body = text.map(Self.preview) ?? "Not kept. Copy it within ten minutes."
            post(title: "Text from \(device)", body: body, action: .copy(deviceID: deviceID, id: id))
        } else {
            let name = fileName ?? "A file"
            post(title: "File from \(device)", body: name + ", in your Catflap inbox", action: path.map(Action.reveal))
        }
    }

    /// A send that did not reach the other device, or that was refused before it began.
    func problem(title: String, body: String, retry: (deviceID: String, id: String)? = nil) {
        post(title: title, body: body, action: retry.map { Action.retry(deviceID: $0.deviceID, id: $0.id) })
    }

    private func post(title: String, body: String, action: Action?) {
        shown.append(Record(title: title, body: body, action: action?.key, delivered: center != nil))
        if shown.count > 20 { shown.removeFirst() }
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        if let action { content.categoryIdentifier = action.key }
        let identifier = UUID().uuidString
        if let action { actions[identifier] = action }
        if actions.count > 50, let oldest = actions.keys.first { actions[oldest] = nil }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { _ in }
    }

    func clearRecords() { shown.removeAll() }

    private func respond(identifier: String, action: String) {
        guard let stored = actions[identifier] else { return }
        // A click on the notification itself does what its button does.
        if action == stored.key || action == UNNotificationDefaultActionIdentifier { perform?(stored) }
    }

    static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 120 ? String(line.prefix(120)) + "\u{2026}" : line
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        completionHandler()
        Task { @MainActor in self.respond(identifier: identifier, action: action) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Catflap is never the app in front, but when it is, still show the banner.
        completionHandler([.banner, .list])
    }
}
#endif
