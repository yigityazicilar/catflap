import CatflapCore
import Foundation

/// The settings the panel offers. The shortcuts belong to the desktop (the GlobalShortcuts
/// portal keeps them); start at login is the autostart entry itself; the rest are rows in the
/// agent's settings table, so all of them survive a restart.
struct PanelSettings: Codable, Sendable, Equatable {
    var hoverBand = true
    var startAtLogin = false
    var receivedTextToClipboard = false
    /// Where received files go. Nil: the default, Downloads/Catflap in the home folder.
    var inbox: String?
    /// A private relay's address for new connections. Nil: tailcat's public relays.
    var relay: String?

    enum CodingKeys: String, CodingKey {
        case inbox, relay
        case hoverBand = "hover_band", startAtLogin = "start_at_login", receivedTextToClipboard = "received_text_to_clipboard"
    }

    /// Store keys. `hover_band` is the key the macOS panel reads too.
    enum Key: String, CaseIterable {
        case hoverBand = "hover_band", receivedTextToClipboard = "received_text_to_clipboard"
        case inbox, relay, startAtLogin = "start_at_login"
    }

    static func load(from store: Store) async -> PanelSettings {
        var settings = PanelSettings()
        settings.hoverBand = (try? await store.setting(Key.hoverBand.rawValue)) != "off"
        settings.receivedTextToClipboard = (try? await store.setting(Key.receivedTextToClipboard.rawValue)) == "on"
        settings.inbox = (try? await store.setting(Key.inbox.rawValue)) ?? nil
        settings.relay = (try? await store.setting(Key.relay.rawValue)) ?? nil
        settings.startAtLogin = Autostart.isEnabled
        return settings
    }

    /// Checks and applies one setting. Returns the sentence to show when the value is refused.
    mutating func set(_ key: Key, _ value: String, store: Store) async -> String? {
        let on = ["on", "true", "1", "yes"].contains(value.lowercased())
        do {
            switch key {
            case .hoverBand:
                hoverBand = on
                try await store.setSetting(key.rawValue, value: on ? "on" : "off")
            case .receivedTextToClipboard:
                receivedTextToClipboard = on
                try await store.setSetting(key.rawValue, value: on ? "on" : "off")
            case .inbox:
                let path = (value as NSString).expandingTildeInPath
                guard path.hasPrefix("/") else { return "Choose a folder by its full path." }
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue {
                    return "That is a file, not a folder."
                }
                inbox = path
                try await store.setSetting(key.rawValue, value: path)
            case .relay:
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                relay = trimmed.isEmpty ? nil : trimmed
                try await store.setSetting(key.rawValue, value: trimmed)
            case .startAtLogin:
                try Autostart.set(on)
                startAtLogin = Autostart.isEnabled
            }
        } catch {
            return "Could not save the setting."
        }
        return nil
    }
}
