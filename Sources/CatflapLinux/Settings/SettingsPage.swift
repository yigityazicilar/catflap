import CAdwaita
import CGtk
import CGtkShim
import CatflapCore
import Foundation

/// Settings inside the panel: both shortcuts, the hover band, start at login, received text to
/// the clipboard, the inbox folder, a private relay, the paired devices with Remove and
/// Pair, and Quit. libadwaita's preference rows, the same on KDE and GNOME.
// Touched only on the GTK thread, like the panel itself.
final class SettingsPage: @unchecked Sendable {
    private unowned let controller: PanelController
    let widget: OpaquePointer
    private let shortcutRow: OpaquePointer
    private let sendShortcutRow: OpaquePointer
    private let hoverRow: OpaquePointer
    private let loginRow: OpaquePointer
    private let clipboardRow: OpaquePointer
    private let inboxRow: OpaquePointer
    private let relayRow: OpaquePointer
    private let devicesGroup: OpaquePointer
    private let firstControl: OpaquePointer
    private var deviceRows: [OpaquePointer] = []
    private var devices: [PanelDevice] = []
    private var confirming: String?
    private var updating = false

    init(controller: PanelController) {
        self.controller = controller
        widget = opaque(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8))
        let header = opaque(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6))
        let back = opaque(gtk_button_new_from_icon_name("go-previous-symbolic"))
        gtk_widget_add_css_class(back.cast(), "flat")
        cf_accessible_label(back.cast(), "Back to the list")
        gtk_widget_set_tooltip_text(back.cast(), "Back to the list")
        firstControl = back
        let title = opaque(gtk_label_new("Settings"))
        gtk_widget_add_css_class(title.cast(), "title-4")
        gtk_box_append(header.cast(), back.cast())
        gtk_box_append(header.cast(), title.cast())
        gtk_box_append(widget.cast(), header.cast())

        let content = opaque(gtk_box_new(GTK_ORIENTATION_VERTICAL, 18))
        let scroller = opaque(gtk_scrolled_window_new())
        gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scroller, content.cast())
        gtk_widget_set_vexpand(scroller.cast(), 1)
        gtk_box_append(widget.cast(), scroller.cast())

        let general = Self.group("General")
        shortcutRow = Self.actionRow("Show or hide Catflap", "")
        sendShortcutRow = Self.actionRow("Send the newest copy", "")
        hoverRow = Self.switchRow("Open from the top edge", "Rest the pointer at the top centre of the screen")
        loginRow = Self.switchRow("Start at login", nil)
        clipboardRow = Self.switchRow("Put received text on the clipboard", nil)
        for row in [shortcutRow, sendShortcutRow, hoverRow, loginRow, clipboardRow] { adw_preferences_group_add(general.cast(), row.cast()) }
        gtk_box_append(content.cast(), general.cast())

        let files = Self.group("Receiving")
        inboxRow = Self.actionRow("Inbox folder", "")
        relayRow = opaque(adw_entry_row_new())
        adw_preferences_row_set_title(relayRow.cast(), "Private relay")
        adw_entry_row_set_show_apply_button(relayRow.cast(), 1)
        cf_accessible_label(relayRow.cast(), "Private relay")
        adw_preferences_group_add(files.cast(), inboxRow.cast())
        adw_preferences_group_add(files.cast(), relayRow.cast())
        gtk_box_append(content.cast(), files.cast())

        devicesGroup = Self.group("Devices")
        let pair = opaque(gtk_button_new_with_label("Pair a device…"))
        gtk_widget_add_css_class(pair.cast(), "flat")
        adw_preferences_group_set_header_suffix(devicesGroup.cast(), pair.cast())
        gtk_box_append(content.cast(), devicesGroup.cast())

        let quit = opaque(gtk_button_new_with_label("Quit Catflap"))
        gtk_widget_add_css_class(quit.cast(), "destructive-action")
        gtk_widget_set_halign(quit.cast(), GTK_ALIGN_CENTER)
        gtk_box_append(content.cast(), quit.cast())

        let changeShortcut = Self.suffixButton(shortcutRow, "Change…", "Change the shortcut that shows or hides Catflap")
        let changeSend = Self.suffixButton(sendShortcutRow, "Change…", "Change the shortcut that sends the newest copy")
        let chooseInbox = Self.suffixButton(inboxRow, "Choose…", "Choose the inbox folder")

        GLib.connect(back, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.controller.extras.show(page: "main") }
        GLib.connect(changeShortcut, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in _ = self?.controller.shortcut.configure() }
        GLib.connect(changeSend, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in _ = self?.controller.sendShortcut.configure() }
        GLib.connect(chooseInbox, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.chooseInbox() }
        GLib.connect(pair, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.controller.extras.show(page: "pair") }
        GLib.connect(quit, "clicked", Int32(CF_SHAPE_VOID)) { _ in
            // The agent's own shutdown, as at logout.
            kill(getpid(), SIGTERM)
        }
        for (row, key) in [(hoverRow, PanelSettings.Key.hoverBand), (loginRow, .startAtLogin), (clipboardRow, .receivedTextToClipboard)] {
            GLib.connect(row, "notify::active", Int32(CF_SHAPE_NOTIFY)) { [weak self] _ in
                guard let self, !updating else { return }
                set(key, adw_switch_row_get_active(row) != 0 ? "on" : "off")
            }
        }
        GLib.connect(relayRow, "apply", Int32(CF_SHAPE_VOID)) { [weak self] _ in
            guard let self else { return }
            set(.relay, gtk_editable_get_text(relayRow).map { String(cString: $0) } ?? "")
        }
        refresh()
    }

    private static func group(_ title: String) -> OpaquePointer {
        let group = opaque(adw_preferences_group_new())
        adw_preferences_group_set_title(group.cast(), title)
        return group
    }

    private static func actionRow(_ title: String, _ subtitle: String) -> OpaquePointer {
        let row = opaque(adw_action_row_new())
        adw_preferences_row_set_title(row.cast(), title)
        adw_action_row_set_subtitle(row.cast(), subtitle)
        return row
    }

    private static func switchRow(_ title: String, _ subtitle: String?) -> OpaquePointer {
        let row = opaque(adw_switch_row_new())
        adw_preferences_row_set_title(row.cast(), title)
        if let subtitle { adw_action_row_set_subtitle(row.cast(), subtitle) }
        return row
    }

    private static func suffixButton(_ row: OpaquePointer, _ title: String, _ description: String) -> OpaquePointer {
        let button = opaque(gtk_button_new_with_label(title))
        gtk_widget_set_valign(button.cast(), GTK_ALIGN_CENTER)
        cf_accessible_description(button.cast(), description)
        gtk_widget_set_tooltip_text(button.cast(), description)
        adw_action_row_add_suffix(row.cast(), button.cast())
        return button
    }

    func willShow() {
        controller.settings.startAtLogin = Autostart.isEnabled
        refresh()
    }

    func focus() { gtk_widget_grab_focus(firstControl.cast()) }

    /// Shows the current values without treating them as changes.
    func refresh() {
        updating = true
        defer { updating = false }
        let settings = controller.settings
        adw_switch_row_set_active(hoverRow, settings.hoverBand ? 1 : 0)
        adw_switch_row_set_active(loginRow, settings.startAtLogin ? 1 : 0)
        adw_switch_row_set_active(clipboardRow, settings.receivedTextToClipboard ? 1 : 0)
        let inbox = settings.inbox ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Catflap").path
        adw_action_row_set_subtitle(inboxRow.cast(), inbox + " (used from the next start)")
        gtk_editable_set_text(relayRow, settings.relay ?? "")
        refreshShortcuts()
    }

    func refreshShortcuts() {
        adw_action_row_set_subtitle(shortcutRow.cast(), Self.describe(controller.shortcut.state, controller.shortcut.trigger))
        adw_action_row_set_subtitle(sendShortcutRow.cast(), Self.describe(controller.sendShortcut.state, controller.sendShortcut.trigger))
    }

    private static func describe(_ state: String, _ trigger: String?) -> String {
        switch state {
        case "bound": trigger ?? "Set"
        case "pending": "Waiting for the system"
        case "declined": "Not allowed"
        case "unbound": "No shortcut set"
        default: "This desktop offers no global shortcuts"
        }
    }

    /// Applies one setting, saves it and shows the result. The sentence of a refusal goes to
    /// the panel's message line and comes back to the caller.
    func set(_ key: PanelSettings.Key, _ value: String, done: (@Sendable (String?) -> Void)? = nil) {
        var copy = controller.settings
        let runtime = controller.runtime, loop = controller.loop
        controller.track(Task { [weak self] in
            let refusal = await copy.set(key, value, store: await runtime.store)
            let result = copy
            await loop.perform { [weak self] in
                guard let self else { return }
                if refusal == nil { controller.settings = result }
                refresh()
                if let refusal { controller.extras.setMessage(refusal) }
                controller.publish()
            }
            done?(refusal)
        })
    }

    private func chooseInbox() {
        controller.dialogOpen = true
        controller.host.withdraw(controller.view.window)
        controller.picker.chooseFolder(parent: nil) { [weak self] path in
            guard let self else { return }
            controller.dialogOpen = false
            controller.returnFromDialog()
            if let path { set(.inbox, path) }
        }
    }

    // MARK: Devices

    func deviceName(_ id: String) -> String? { devices.first { $0.id == id }?.name }

    /// A paired device by id, or by name when exactly one has it.
    func device(_ text: String) -> PanelDevice? {
        if let device = devices.first(where: { $0.id == text }) { return device }
        let named = devices.filter { $0.name == text }
        return named.count == 1 ? named[0] : nil
    }

    /// The most recently used device, which the agent lists first.
    var firstDevice: PanelDevice? { devices.first }

    func update(devices next: [PanelDevice]) {
        guard next != devices else { return }
        devices = next
        for row in deviceRows { adw_preferences_group_remove(devicesGroup.cast(), row.cast()) }
        deviceRows = []
        for device in next {
            let row = Self.actionRow(device.name, "")
            let remove = opaque(gtk_button_new_with_label(confirming == device.id ? "Remove now" : "Remove…"))
            gtk_widget_set_valign(remove.cast(), GTK_ALIGN_CENTER)
            cf_accessible_label(remove.cast(), "Remove \(device.name)")
            adw_action_row_add_suffix(row.cast(), remove.cast())
            GLib.connect(remove, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in
                guard let self else { return }
                // Two steps: the first click asks, the second removes.
                if confirming == device.id {
                    confirming = nil
                    controller.sender.remove(deviceID: device.id, name: device.name)
                } else {
                    confirming = device.id
                    gtk_button_set_label(remove.cast(), "Remove now")
                    gtk_widget_add_css_class(remove.cast(), "destructive-action")
                    adw_action_row_set_subtitle(row.cast(), "\(device.name) will no longer reach this device")
                }
            }
            adw_preferences_group_add(devicesGroup.cast(), row.cast())
            deviceRows.append(row)
        }
    }
}
