#if os(macOS)
import AppKit
import CatflapCore

@MainActor
protocol SettingsWindowActions: AnyObject {
    /// A switch or field changed one setting.
    func settingsSet(_ key: MacSettings.Key, _ value: String)
    func settingsChooseInbox()
    func settingsRemove(deviceID: String, name: String)
    func settingsPair()
}

/// Catflap's settings, in a small window of its own: the two shortcuts, the hover band, what
/// happens to received text and files, start at login, and the paired devices with Remove.
/// System controls only.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    weak var actions: SettingsWindowActions?
    let window: NSWindow
    let panelRecorder: ShortcutRecorder
    let sendRecorder: ShortcutRecorder
    private let hoverBand = NSSwitch()
    private let hoverFullScreen = NSSwitch()
    private let receivedText = NSSwitch()
    private let login = NSSwitch()
    private let loginNote = NSTextField(wrappingLabelWithString: "")
    private let panelShortcutNote = NSTextField(wrappingLabelWithString: "")
    private let sendShortcutNote = NSTextField(wrappingLabelWithString: "")
    private let inboxPath = NSTextField(labelWithString: "")
    private let devices = NSStackView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var shownDevices: [String] = []

    var isOpen: Bool { window.isVisible }

    init(panel: ShortcutBinding, send: ShortcutBinding) {
        panelRecorder = ShortcutRecorder(binding: panel, label: "Shortcut that opens the panel")
        sendRecorder = ShortcutRecorder(binding: send, label: "Shortcut that sends the clipboard")
        panelRecorder.quiet = [panel, send]
        sendRecorder.quiet = [panel, send]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420), styleMask: [.titled, .closable],
                          backing: .buffered, defer: true)
        super.init()
        window.title = "Catflap Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        build()
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func note(_ field: NSTextField) {
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
    }

    private func build() {
        for (control, name) in [(hoverBand, "Open the panel when the pointer rests at the top of the screen"),
                                (hoverFullScreen, "Also over full-screen apps"),
                                (receivedText, "Put received text on the clipboard"),
                                (login, "Start Catflap at login")] {
            control.target = self
            control.action = #selector(switched(_:))
            control.setAccessibilityLabel(name)
        }
        let choose = NSButton(title: "Choose\u{2026}", target: self, action: #selector(chooseInbox))
        choose.setAccessibilityLabel("Choose the folder for received files")
        inboxPath.lineBreakMode = .byTruncatingMiddle
        inboxPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inboxRow = NSStackView(views: [inboxPath, choose])
        inboxRow.spacing = 8
        let inboxNote = NSTextField(wrappingLabelWithString: "A new folder is used from the next start of Catflap.")
        note(inboxNote)
        note(loginNote)
        loginNote.preferredMaxLayoutWidth = 280
        inboxNote.preferredMaxLayoutWidth = 280
        for shortcutNote in [panelShortcutNote, sendShortcutNote] {
            note(shortcutNote)
            shortcutNote.textColor = .systemOrange
            shortcutNote.preferredMaxLayoutWidth = 280
            shortcutNote.isHidden = true
        }

        let grid = NSGridView(views: [
            [label("Open the panel:"), panelRecorder],
            [NSGridCell.emptyContentView, panelShortcutNote],
            [label("Send the clipboard:"), sendRecorder],
            [NSGridCell.emptyContentView, sendShortcutNote],
            [label("Top of the screen:"), switchRow(hoverBand, "Open the panel on hover")],
            [NSGridCell.emptyContentView, switchRow(hoverFullScreen, "Also over full-screen apps")],
            [label("Received text:"), switchRow(receivedText, "Put it on the clipboard")],
            [label("Received files:"), inboxRow],
            [NSGridCell.emptyContentView, inboxNote],
            [label("Login:"), switchRow(login, "Start Catflap at login")],
            [NSGridCell.emptyContentView, loginNote],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 10

        let devicesTitle = NSTextField(labelWithString: "Paired devices")
        devicesTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        devices.orientation = .vertical
        devices.alignment = .leading
        devices.spacing = 6
        devices.setAccessibilityElement(true)
        devices.setAccessibilityRole(.list)
        devices.setAccessibilityLabel("Paired devices")
        let pair = NSButton(title: "Pair a Device\u{2026}", target: self, action: #selector(pairPressed))
        message.textColor = .systemOrange
        message.preferredMaxLayoutWidth = 420

        let stack = NSStackView(views: [grid, NSBox.separator(), devicesTitle, devices, pair, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
    }

    private func switchRow(_ control: NSSwitch, _ text: String) -> NSView {
        let caption = NSTextField(labelWithString: text)
        let row = NSStackView(views: [control, caption])
        row.spacing = 8
        return row
    }

    /// Shows the window in front, with the keyboard. Catflap has no Dock entry, so it has to
    /// become the active app for its window to take the keyboard.
    func show() {
        if !window.isVisible { window.center() }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        panelRecorder.stop()
        sendRecorder.stop()
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        panelRecorder.stop()
        sendRecorder.stop()
    }

    func render(_ settings: MacSettings, devices list: [DeviceSummary], message text: String) {
        hoverBand.state = settings.hoverBand ? .on : .off
        hoverFullScreen.state = settings.hoverFullScreen ? .on : .off
        hoverFullScreen.isEnabled = settings.hoverBand
        receivedText.state = settings.receivedTextToClipboard ? .on : .off
        inboxPath.stringValue = settings.inbox ?? "Downloads/Catflap"
        inboxPath.toolTip = settings.inbox
        switch settings.startAtLogin {
        case "on":
            login.state = .on; login.isEnabled = true
            loginNote.stringValue = "Catflap starts when you log in. You can also switch it off in System Settings, General, Login Items."
        case "requires_approval":
            login.state = .on; login.isEnabled = true
            loginNote.stringValue = "Allow Catflap in System Settings, General, Login Items, so it can start at login."
        case "unavailable":
            login.state = .off; login.isEnabled = false
            loginNote.stringValue = "Available when Catflap runs from Catflap.app."
        default:
            login.state = .off; login.isEnabled = true
            loginNote.stringValue = ""
        }
        panelRecorder.refresh()
        sendRecorder.refresh()
        for (shortcutNote, state) in [(panelShortcutNote, settings.panelShortcutState), (sendShortcutNote, settings.sendShortcutState)] {
            // A shortcut whose keys macOS or another app has does nothing until it is rebound.
            shortcutNote.stringValue = state == "conflict" ? "macOS or another app uses this shortcut, so it does nothing. Record another." : ""
            shortcutNote.isHidden = shortcutNote.stringValue.isEmpty
        }
        message.stringValue = text
        message.isHidden = text.isEmpty
        let ids = list.map { $0.id + "\u{0}" + $0.name }
        guard ids != shownDevices else { return }
        shownDevices = ids
        for view in devices.arrangedSubviews { view.removeFromSuperview() }
        if list.isEmpty {
            let none = NSTextField(labelWithString: "No paired devices.")
            none.textColor = .secondaryLabelColor
            devices.addArrangedSubview(none)
        }
        for device in list {
            let name = NSTextField(labelWithString: device.name)
            let remove = NSButton(title: "Remove\u{2026}", target: self, action: #selector(removePressed(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(device.id)
            remove.toolTip = device.name
            remove.setAccessibilityLabel("Remove \(device.name)")
            let row = NSStackView(views: [NSImageView(image: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil) ?? NSImage()),
                                          name, remove])
            row.spacing = 8
            devices.addArrangedSubview(row)
        }
    }

    @objc private func switched(_ sender: NSSwitch) {
        let value = sender.state == .on ? "on" : "off"
        let key: MacSettings.Key
        switch sender {
        case hoverBand: key = .hoverBand
        case hoverFullScreen: key = .hoverFullScreen
        case receivedText: key = .receivedTextToClipboard
        default: key = .startAtLogin
        }
        actions?.settingsSet(key, value)
    }

    @objc private func chooseInbox() { actions?.settingsChooseInbox() }
    @objc private func pairPressed() { actions?.settingsPair() }

    @objc private func removePressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let name = sender.toolTip ?? "this device"
        let alert = NSAlert()
        alert.messageText = "Remove \(name)?"
        alert.informativeText = "\(name) can no longer send to this Mac, and this Mac can no longer send to it. To use it again, pair again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.actions?.settingsRemove(deviceID: id, name: name)
            }
        }
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
#endif
