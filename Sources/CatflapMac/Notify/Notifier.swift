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

        /// What the notification carries, so its button works however long it stays in
        /// Notification Center, across restarts of the agent too.
        var userInfo: [String: String] {
            switch self {
            case .copy(let deviceID, let id), .retry(let deviceID, let id): ["action": key, "device_id": deviceID, "id": id]
            case .reveal(let path): ["action": key, "path": path]
            }
        }

        init?(userInfo info: [String: String]) {
            switch info["action"] {
            case "copy", "retry":
                guard let deviceID = info["device_id"], let id = info["id"] else { return nil }
                self = info["action"] == "copy" ? .copy(deviceID: deviceID, id: id) : .retry(deviceID: deviceID, id: id)
            case "reveal":
                guard let path = info["path"] else { return nil }
                self = .reveal(path)
            default:
                return nil
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
    /// With test hooks on only: the userInfo of each notification posted with an action, as
    /// posted, newest last. `ui invoke notification-press` presses a button with it.
    private(set) var postedUserInfo: [[String: String]] = []
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
        let userInfo = action?.userInfo ?? [:]
        if MacTestHooks.on, action != nil {
            postedUserInfo.append(userInfo)
            if postedUserInfo.count > 20 { postedUserInfo.removeFirst() }
        }
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.userInfo = userInfo
        if let action { content.categoryIdentifier = action.key }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
    }

    func clearRecords() { shown.removeAll() }

    /// What a press on a notification does, given the userInfo it was posted with and the
    /// action identifier of what was pressed.
    func respond(userInfo: [String: String], action button: String) {
        guard let stored = Action(userInfo: userInfo) else { return }
        // A click on the notification itself does what its button does.
        if button == stored.key || button == UNNotificationDefaultActionIdentifier { perform?(stored) }
    }

    static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 120 ? String(line.prefix(120)) + "\u{2026}" : line
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String, let text = entry.value as? String { result[key] = text }
        }
        let button = response.actionIdentifier
        completionHandler()
        Task { @MainActor in self.respond(userInfo: userInfo, action: button) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Catflap is never the app in front, but when it is, still show the banner.
        completionHandler([.banner, .list])
    }
}
#endif
