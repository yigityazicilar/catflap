#if os(macOS)
import CatflapCore
import Foundation
import ServiceManagement

/// Starting the agent at login: a launch agent inside the app bundle
/// (`Contents/Library/LaunchAgents`), which runs `catflap agent` and which the person can see
/// and switch off under General > Login Items. Only an app bundle has one.
@MainActor
enum LoginItem {
    static let plistName = "io.github.yigityazicilar.Catflap.agent.plist"

    static var plistURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/" + plistName)
    }

    static var isAvailable: Bool {
        Notifier.canDeliver && FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// `on`, `off`, `requires_approval` (the person has to allow it in System Settings), or
    /// `unavailable` outside an app bundle.
    static var state: String {
        guard isAvailable else { return "unavailable" }
        switch SMAppService.agent(plistName: plistName).status {
        case .enabled: return "on"
        // Before its first registration macOS reports the agent as not found; the plist is
        // there (checked above), so it is simply not registered.
        case .notRegistered, .notFound: return "off"
        case .requiresApproval: return "requires_approval"
        @unknown default: return "unknown"
        }
    }

    /// Returns the sentence to show when the change did not happen.
    static func set(_ on: Bool) -> String? {
        guard isAvailable else { return "Start at login is available when Catflap runs from Catflap.app." }
        let service = SMAppService.agent(plistName: plistName)
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            // Unregistering what is not registered is not a failure.
            if !on, [.notRegistered, .notFound].contains(service.status) { return nil }
            return "macOS did not change the login item: \(error.localizedDescription)"
        }
        return nil
    }
}

/// The settings the panel offers, each kept where it survives a restart: the agent's settings
/// table for the switches and the inbox, the preferences domain (through KeyboardShortcuts)
/// for the two shortcuts, and macOS's own login items for start at login.
struct MacSettings: Codable, Sendable, Equatable {
    var hoverBand = true
    var hoverFullScreen = false
    var receivedTextToClipboard = false
    /// Where received files go. Nil: the default, Downloads/Catflap in the home folder.
    var inbox: String?
    var startAtLogin = "unavailable"
    var panelShortcut = ""
    var sendShortcut = ""

    enum CodingKeys: String, CodingKey {
        case inbox
        case hoverBand = "hover_band", hoverFullScreen = "hover_full_screen"
        case receivedTextToClipboard = "received_text_to_clipboard", startAtLogin = "start_at_login"
        case panelShortcut = "panel_shortcut", sendShortcut = "send_shortcut"
    }

    /// The keys `ui invoke set` takes. `hover_band` and `hover_full_screen` are the keys the
    /// panel's hover band reads.
    enum Key: String, CaseIterable, Sendable {
        case hoverBand = "hover_band", hoverFullScreen = "hover_full_screen"
        case receivedTextToClipboard = "received_text_to_clipboard", inbox
        case startAtLogin = "start_at_login", panelShortcut = "panel_shortcut", sendShortcut = "send_shortcut"
    }

    static func on(_ value: String) -> Bool { ["on", "true", "1", "yes"].contains(value.lowercased()) }

    static func load(from store: Store) async -> MacSettings {
        var settings = MacSettings()
        settings.hoverBand = (try? await store.setting(Key.hoverBand.rawValue)) != "off"
        settings.hoverFullScreen = (try? await store.setting(Key.hoverFullScreen.rawValue)) == "on"
        settings.receivedTextToClipboard = (try? await store.setting(Key.receivedTextToClipboard.rawValue)) == "on"
        if let inbox = try? await store.setting(Key.inbox.rawValue), !inbox.isEmpty { settings.inbox = inbox }
        return settings
    }

    /// Checks and stores one of the settings kept in the agent's table. Returns the sentence
    /// to show when the value is refused.
    mutating func store(_ key: Key, _ value: String, in store: Store) async -> String? {
        do {
            switch key {
            case .hoverBand:
                hoverBand = Self.on(value)
                try await store.setSetting(key.rawValue, value: hoverBand ? "on" : "off")
            case .hoverFullScreen:
                hoverFullScreen = Self.on(value)
                try await store.setSetting(key.rawValue, value: hoverFullScreen ? "on" : "off")
            case .receivedTextToClipboard:
                receivedTextToClipboard = Self.on(value)
                try await store.setSetting(key.rawValue, value: receivedTextToClipboard ? "on" : "off")
            case .inbox:
                let path = (value as NSString).expandingTildeInPath
                guard path.hasPrefix("/") else { return "Choose a folder by its full path." }
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue {
                    return "That is a file, not a folder."
                }
                inbox = path
                try await store.setSetting(key.rawValue, value: path)
            case .startAtLogin, .panelShortcut, .sendShortcut:
                return "That setting is not kept in the agent's table."
            }
        } catch {
            return "Could not save the setting."
        }
        return nil
    }
}
#endif
