import CatflapCore
import Foundation

/// Only this owned subfolder is rewritten; existing Nautilus scripts are never removed.
actor GnomeFiles {
    private var previous: [String] = []
    private let folder: URL
    init() {
        let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        folder = data.appendingPathComponent("nautilus/scripts/Catflap")
    }
    func update(_ devices: [DeviceSummary]) throws {
        let signature = devices.map { $0.id + "\u{0}" + $0.name }
        guard signature != previous || !FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifest = folder.appendingPathComponent(".catflap-files.json")
        let old = (try? ControlJSON.decoder.decode([String].self, from: Data(contentsOf: manifest))) ?? []
        var files: [String: String] = [:]
        let exe = Self.quote(Autostart.executable)
        files["Choose in Catflap…"] = """
        #!/bin/sh
        set --
        while IFS= read -r file; do
          [ -n "$file" ] && set -- "$@" --file "$file"
        done <<EOF
        $NAUTILUS_SCRIPT_SELECTED_FILE_PATHS
        EOF
        exec \(exe) ui invoke attach "$@"
        """ + "\n"
        for device in devices {
            let name = String(device.name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" }.prefix(80))
            // The id suffix prevents two equal names from overwriting one another.
            let filename = "Send to " + (name.isEmpty ? "device" : name) + " (" + String(device.id.filter { $0.isLetter || $0.isNumber }.prefix(8)) + ") with Catflap"
            files[filename] = """
            #!/bin/sh
            while IFS= read -r file; do
              [ -n "$file" ] || continue
              \(exe) send --to \(Self.quote(device.id)) --file "$file"
            done <<EOF
            $NAUTILUS_SCRIPT_SELECTED_FILE_PATHS
            EOF
            """ + "\n"
        }
        for name in old where files[name] == nil && !name.contains("/") && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        for (name, script) in files {
            let path = folder.appendingPathComponent(name)
            try Data(script.utf8).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        try ControlJSON.encoder.encode(files.keys.sorted()).write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        previous = signature
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
