#if os(macOS)
import AppKit

/// Attach: the system's open panel, for files (several at once) or, for the inbox setting,
/// one folder. Catflap has no Dock entry, so it becomes the active app while the panel is up.
@MainActor
final class FilePicker {
    private var panel: NSOpenPanel?
    var isOpen: Bool { panel != nil }

    func pickFiles(_ done: @escaping @MainActor @Sendable ([URL]) -> Void) {
        open(directories: false, prompt: "Attach", message: "Choose files to send with Catflap", done)
    }

    func pickFolder(_ done: @escaping @MainActor @Sendable ([URL]) -> Void) {
        open(directories: true, prompt: "Choose", message: "Choose the folder for files Catflap receives", done)
    }

    func cancel() { panel?.cancel(nil) }

    private func open(directories: Bool, prompt: String, message: String, _ done: @escaping @MainActor @Sendable ([URL]) -> Void) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let picker = NSOpenPanel()
        picker.canChooseFiles = !directories
        picker.canChooseDirectories = directories
        picker.canCreateDirectories = directories
        picker.allowsMultipleSelection = !directories
        picker.resolvesAliases = true
        picker.prompt = prompt
        picker.message = message
        panel = picker
        NSApplication.shared.activate()
        picker.begin { [weak self] response in
            MainActor.assumeIsolated {
                let urls = response == .OK ? picker.urls : []
                self?.panel = nil
                done(urls)
            }
        }
    }
}

/// The Services menu item "Send with Catflap" for files selected in Finder (declared in the
/// app's Info.plist). macOS delivers the selection here; the panel opens with the files
/// attached and the most recently used device selected, and Return sends them.
@MainActor
final class ServiceProvider: NSObject {
    var receive: (([URL]) -> Void)?

    @objc(sendWithCatflap:userData:error:)
    func sendWithCatflap(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = PasteboardWriter.files(on: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = "Catflap can send files only." as NSString
            return
        }
        receive?(urls)
    }
}
#endif
