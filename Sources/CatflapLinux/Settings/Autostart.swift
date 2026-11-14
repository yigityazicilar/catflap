import Foundation

/// Start at login: the XDG autostart entry, which Plasma and GNOME both run at login. The file
/// is the setting; nothing else records it.
enum Autostart {
    static let fileName = "io.github.yigityazicilar.Catflap.desktop"

    static var directory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let config = environment["XDG_CONFIG_HOME"], config.hasPrefix("/") {
            return URL(fileURLWithPath: config).appendingPathComponent("autostart")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/autostart")
    }

    static var file: URL { directory.appendingPathComponent(fileName) }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// The running executable, with links resolved, so the entry starts this build.
    static var executable: String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? CommandLine.arguments[0]
    }

    static func set(_ enabled: Bool) throws {
        guard enabled else {
            if isEnabled { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = """
        [Desktop Entry]
        Type=Application
        Name=Catflap
        Comment=Send text and files between your own machines
        Exec=\(DesktopEntry.quote(executable)) agent
        Icon=io.github.yigityazicilar.Catflap
        Terminal=false
        NoDisplay=true
        X-GNOME-Autostart-enabled=true
        X-KDE-autostart-phase=2

        """
        try entry.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// Writing values into desktop entry files.
enum DesktopEntry {
    /// An Exec argument, quoted as the Desktop Entry specification asks.
    static func quote(_ argument: String) -> String {
        let safe = argument.allSatisfy { $0.isLetter || $0.isNumber || "/-_.+".contains($0) }
        if safe { return argument }
        var quoted = "\""
        for character in argument {
            if "\"`$\\".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return quoted + "\""
    }

    /// A Name value: one line, no control characters, no field codes, at most 64 characters.
    static func name(_ text: String) -> String {
        let cleaned = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var value = String(String.UnicodeScalarView(cleaned)).replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        if value.count > 64 { value = String(value.prefix(64)) + "…" }
        return value.isEmpty ? "Unnamed device" : value
    }
}
