import CAdwaita
import CGtk
import CGtkShim
import CatflapCore
import Foundation

/// The actions behind the panel's controls. Sending, Attach and Settings arrive with the
/// panel actions task; until then those calls do nothing.
protocol PanelActions: AnyObject {
    func send(_ payload: PanelPayload, to device: PanelDevice, keep: Bool)
    func attach()
    func openSettings()
    func setPaused(_ paused: Bool)
}

/// The panel's widgets, top to bottom as the design brief lays them out: the field that
/// filters and composes, Attach, the paired devices, the Clipboard / History switch, the list,
/// and a footer with the send button, the connection state, "don't keep", pause and settings.
final class PanelView {
    static let width: Int32 = 420
    static let height: Int32 = 480

    struct Control: Codable, Sendable, Equatable {
        let role: String
        let label: String
    }

    let window: OpaquePointer
    private let surface: OpaquePointer
    private let entry: OpaquePointer
    private let attachButton: OpaquePointer
    private let devicesBox: OpaquePointer
    private let noDevices: OpaquePointer
    private let clipboardButton: OpaquePointer
    private let historyButton: OpaquePointer
    private let list: OpaquePointer
    private let scroller: OpaquePointer
    private let placeholder: OpaquePointer
    private let sendButton: OpaquePointer
    private let connectionLabel: OpaquePointer
    private let keepSwitch: OpaquePointer
    private let pauseButton: OpaquePointer
    private let settingsButton: OpaquePointer

    weak var actions: PanelActions?
    /// Escape, with whether a row was selected; the state machine decides what it means.
    var onEscape: ((Bool) -> Void)?

    private(set) var listMode: PanelList = .clipboard
    private var clipboardRows: [PanelRow] = []
    private var historyRows: [PanelRow] = []
    private var visibleRows: [(row: OpaquePointer, item: PanelRow)] = []
    private var devices: [PanelDevice] = []
    private var deviceButtons: [OpaquePointer] = []
    private var selectedDeviceID: String?
    private var attached: [String] = []
    private var composing = false
    private var updatingPause = false
    private(set) var controls: [Control] = []
    private(set) var lastReturn: String?
    private(set) var connection = ""

    init() {
        window = opaque(gtk_window_new())
        gtk_window_set_title(window.cast(), "Catflap")
        gtk_window_set_default_size(window.cast(), Self.width, Self.height)
        gtk_window_set_resizable(window.cast(), 0)
        gtk_widget_add_css_class(window.cast(), "catflap-panel-window")

        surface = opaque(gtk_box_new(GTK_ORIENTATION_VERTICAL, 10))
        gtk_widget_add_css_class(surface.cast(), "catflap-surface")
        gtk_widget_set_size_request(surface.cast(), Self.width, Self.height)

        entry = opaque(gtk_search_entry_new())
        gtk_search_entry_set_placeholder_text(entry, "Search, or type to send")
        gtk_search_entry_set_search_delay(entry, 0)
        gtk_widget_set_hexpand(entry.cast(), 1)

        attachButton = opaque(gtk_button_new())
        let attachContent = opaque(adw_button_content_new())
        adw_button_content_set_icon_name(attachContent, "mail-attachment-symbolic")
        adw_button_content_set_label(attachContent, "Attach…")
        gtk_button_set_child(attachButton.cast(), attachContent.cast())
        gtk_widget_set_halign(attachButton.cast(), GTK_ALIGN_START)
        gtk_widget_add_css_class(attachButton.cast(), "flat")

        devicesBox = opaque(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6))
        noDevices = opaque(gtk_label_new("No paired devices"))
        gtk_widget_add_css_class(noDevices.cast(), "dim-label")
        gtk_box_append(devicesBox.cast(), noDevices.cast())

        let switcher = opaque(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0))
        gtk_widget_add_css_class(switcher.cast(), "linked")
        gtk_box_set_homogeneous(switcher.cast(), 1)
        clipboardButton = opaque(gtk_toggle_button_new_with_label("Clipboard"))
        historyButton = opaque(gtk_toggle_button_new_with_label("History"))
        gtk_toggle_button_set_group(historyButton.cast(), clipboardButton.cast())
        gtk_toggle_button_set_active(clipboardButton.cast(), 1)
        gtk_box_append(switcher.cast(), clipboardButton.cast())
        gtk_box_append(switcher.cast(), historyButton.cast())

        list = opaque(gtk_list_box_new())
        gtk_list_box_set_selection_mode(list, GTK_SELECTION_SINGLE)
        gtk_widget_add_css_class(list.cast(), "navigation-sidebar")
        placeholder = opaque(gtk_label_new("Nothing copied yet"))
        gtk_widget_add_css_class(placeholder.cast(), "dim-label")
        gtk_widget_set_margin_top(placeholder.cast(), 24)
        gtk_list_box_set_placeholder(list, placeholder.cast())
        scroller = opaque(gtk_scrolled_window_new())
        gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scroller, list.cast())
        gtk_widget_set_vexpand(scroller.cast(), 1)

        sendButton = opaque(gtk_button_new_with_label("Pair a device to send"))
        gtk_widget_add_css_class(sendButton.cast(), "suggested-action")
        if let label = gtk_button_get_child(sendButton.cast()) {
            gtk_label_set_ellipsize(OpaquePointer(label), PANGO_ELLIPSIZE_END)
        }

        let footer = opaque(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8))
        connectionLabel = opaque(gtk_label_new(""))
        gtk_label_set_xalign(connectionLabel, 0)
        gtk_label_set_ellipsize(connectionLabel, PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(connectionLabel.cast(), 1)
        gtk_widget_add_css_class(connectionLabel.cast(), "dim-label")
        gtk_widget_add_css_class(connectionLabel.cast(), "caption")
        let keepLabel = opaque(gtk_label_new("Don't keep"))
        keepSwitch = opaque(gtk_switch_new())
        gtk_widget_set_valign(keepSwitch.cast(), GTK_ALIGN_CENTER)
        pauseButton = opaque(gtk_toggle_button_new())
        gtk_button_set_icon_name(pauseButton.cast(), "media-playback-pause-symbolic")
        gtk_widget_add_css_class(pauseButton.cast(), "flat")
        settingsButton = opaque(gtk_button_new_from_icon_name("emblem-system-symbolic"))
        gtk_widget_add_css_class(settingsButton.cast(), "flat")
        for widget in [connectionLabel, keepLabel, keepSwitch, pauseButton, settingsButton] {
            gtk_box_append(footer.cast(), widget.cast())
        }

        for widget in [entry, attachButton, devicesBox, switcher, scroller, sendButton, footer] {
            gtk_box_append(surface.cast(), widget.cast())
        }
        gtk_window_set_child(window.cast(), surface.cast())

        label(entry, role: "search", "Search the list, or type text to send")
        // Buttons that show text are named by it, so what is heard matches what is seen;
        // the description adds what they do.
        describe(attachButton, role: "button", "Attach…", "Attach files")
        describe(clipboardButton, role: "toggle button", "Clipboard", "Show clipboard history")
        describe(historyButton, role: "toggle button", "History", "Show transfer history")
        label(list, role: "list", "Items")
        controls.append(Control(role: "button", label: "Pair a device to send"))
        label(keepSwitch, role: "switch", "Don't keep what you send")
        label(pauseButton, role: "toggle button", "Pause clipboard history")
        label(settingsButton, role: "button", "Settings")
        gtk_widget_set_tooltip_text(pauseButton.cast(), "Pause clipboard history")
        gtk_widget_set_tooltip_text(settingsButton.cast(), "Settings")
        gtk_widget_set_tooltip_text(keepSwitch.cast(), "Don't keep what you send")
        connectSignals()
    }

    private func label(_ widget: OpaquePointer, role: String, _ text: String) {
        cf_accessible_label(widget.cast(), text)
        controls.append(Control(role: role, label: text))
    }

    private func describe(_ widget: OpaquePointer, role: String, _ name: String, _ description: String) {
        cf_accessible_description(widget.cast(), description)
        gtk_widget_set_tooltip_text(widget.cast(), description)
        controls.append(Control(role: role, label: name))
    }

    private func connectSignals() {
        GLib.connect(entry, "search-changed", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.render() }
        GLib.connect(entry, "activate", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.pressReturn() }
        if let text = gtk_editable_get_delegate(entry) {
            // Return and Escape belong to an input method while it composes.
            GLib.connect(text, "preedit-changed", Int32(CF_SHAPE_STRING)) { [weak self] event in
                let preedit = event.pointee.text.map { String(cString: $0) } ?? ""
                self?.composing = !preedit.isEmpty
            }
        }
        let keys = opaque(gtk_event_controller_key_new())
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        GLib.connect(keys, "key-pressed", Int32(CF_SHAPE_KEY)) { [weak self] event in
            guard let self, !composing else { return }
            switch event.pointee.keyval {
            case 0xff52, 0xff97: moveSelection(by: -1); event.pointee.result = 1
            case 0xff54, 0xff99: moveSelection(by: 1); event.pointee.result = 1
            case 0xff1b:
                onEscape?(selectedRow() != nil)
                event.pointee.result = 1
            default: break
            }
        }
        gtk_widget_add_controller(entry.cast(), keys)
        GLib.connect(list, "row-selected", Int32(CF_SHAPE_OBJECT)) { [weak self] _ in self?.updateSendLabel() }
        GLib.connect(list, "row-activated", Int32(CF_SHAPE_OBJECT)) { [weak self] _ in self?.pressReturn() }
        GLib.connect(clipboardButton, "toggled", Int32(CF_SHAPE_VOID)) { [weak self] _ in
            guard let self, gtk_toggle_button_get_active(clipboardButton.cast()) != 0 else { return }
            show(.clipboard)
        }
        GLib.connect(historyButton, "toggled", Int32(CF_SHAPE_VOID)) { [weak self] _ in
            guard let self, gtk_toggle_button_get_active(historyButton.cast()) != 0 else { return }
            show(.history)
        }
        GLib.connect(sendButton, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.sendCurrent() }
        GLib.connect(attachButton, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.actions?.attach() }
        GLib.connect(settingsButton, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.actions?.openSettings() }
        GLib.connect(pauseButton, "toggled", Int32(CF_SHAPE_VOID)) { [weak self] _ in
            guard let self, !updatingPause else { return }
            actions?.setPaused(gtk_toggle_button_get_active(pauseButton.cast()) != 0)
        }
    }

    // MARK: State from the agent

    func update(devices: [PanelDevice], clipboard: [ClipboardItem], history: [HistoryRecord], paused: Bool) {
        if devices != self.devices { setDevices(devices) }
        clipboardRows = PanelText.rows(clipboard: clipboard)
        historyRows = PanelText.rows(history: history, devices: devices)
        updatingPause = true
        gtk_toggle_button_set_active(pauseButton.cast(), paused ? 1 : 0)
        updatingPause = false
        let pauseLabel = paused ? "Resume clipboard history" : "Pause clipboard history"
        cf_accessible_label(pauseButton.cast(), pauseLabel)
        gtk_widget_set_tooltip_text(pauseButton.cast(), pauseLabel)
        replace(role: "toggle button", old: ["Pause clipboard history", "Resume clipboard history"], with: pauseLabel)
        render()
    }

    func setConnection(_ text: String) {
        connection = text
        gtk_label_set_text(connectionLabel, text)
    }

    private func setDevices(_ devices: [PanelDevice]) {
        for button in deviceButtons { gtk_box_remove(devicesBox.cast(), button.cast()) }
        deviceButtons = []
        controls.removeAll { $0.role == "device" }
        self.devices = devices
        if selectedDeviceID.map({ id in !devices.contains { $0.id == id } }) ?? true {
            // The first device is the default target.
            selectedDeviceID = devices.first?.id
        }
        gtk_widget_set_visible(noDevices.cast(), devices.isEmpty ? 1 : 0)
        var first: OpaquePointer?
        for device in devices {
            let button = opaque(gtk_toggle_button_new_with_label(device.name))
            if let first { gtk_toggle_button_set_group(button.cast(), first.cast()) } else { first = button }
            gtk_toggle_button_set_active(button.cast(), device.id == selectedDeviceID ? 1 : 0)
            let text = "Send to \(device.name)"
            // Named by the device name it shows; the description says what choosing it does.
            cf_accessible_description(button.cast(), text)
            gtk_widget_set_tooltip_text(button.cast(), text)
            controls.append(Control(role: "device", label: device.name))
            GLib.connect(button, "toggled", Int32(CF_SHAPE_VOID)) { [weak self] _ in
                guard let self, gtk_toggle_button_get_active(button.cast()) != 0 else { return }
                selectedDeviceID = device.id
                updateSendLabel()
            }
            gtk_box_append(devicesBox.cast(), button.cast())
            deviceButtons.append(button)
        }
    }

    var selectedDevice: PanelDevice? { devices.first { $0.id == selectedDeviceID } ?? devices.first }
    var deviceNames: [String] { devices.map(\.name) }

    // MARK: The list

    private func show(_ mode: PanelList) {
        guard listMode != mode else { return }
        listMode = mode
        gtk_label_set_text(placeholder, mode == .clipboard ? "Nothing copied yet" : "Nothing sent or received yet")
        render()
    }

    /// Rebuilds the rows that match the field. Keeps the selected row if it is still shown;
    /// typing never selects one.
    private func render() {
        let selectedID = selectedRow()?.id
        gtk_list_box_remove_all(list)
        visibleRows = []
        let rows = PanelText.filter(listMode == .clipboard ? clipboardRows : historyRows, by: fieldText)
        for item in rows.prefix(200) {
            let row = opaque(gtk_list_box_row_new())
            let box = opaque(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2))
            let title = opaque(gtk_label_new(item.title))
            gtk_label_set_xalign(title, 0)
            gtk_label_set_ellipsize(title, PANGO_ELLIPSIZE_END)
            let subtitle = opaque(gtk_label_new(item.subtitle))
            gtk_label_set_xalign(subtitle, 0)
            gtk_widget_add_css_class(subtitle.cast(), "dim-label")
            gtk_widget_add_css_class(subtitle.cast(), "caption")
            gtk_box_append(box.cast(), title.cast())
            gtk_box_append(box.cast(), subtitle.cast())
            gtk_list_box_row_set_child(row.cast(), box.cast())
            cf_accessible_label(row.cast(), item.accessibleLabel)
            gtk_list_box_append(list, row.cast())
            visibleRows.append((row, item))
            if item.id == selectedID { gtk_list_box_select_row(list, row.cast()) }
        }
        updateSendLabel()
    }

    var fieldText: String {
        gtk_editable_get_text(entry).map { String(cString: $0) } ?? ""
    }

    var rowTitles: [String] { visibleRows.map(\.item.title) }

    func selectedRow() -> PanelRow? {
        guard let selected = gtk_list_box_get_selected_row(list) else { return nil }
        let pointer = OpaquePointer(selected)
        return visibleRows.first { $0.row == pointer }?.item
    }

    var selectedIndex: Int? {
        guard let selected = gtk_list_box_get_selected_row(list) else { return nil }
        let pointer = OpaquePointer(selected)
        return visibleRows.firstIndex { $0.row == pointer }
    }

    private func moveSelection(by step: Int) {
        guard !visibleRows.isEmpty else { return }
        let next: Int
        if let current = selectedIndex {
            next = min(max(current + step, 0), visibleRows.count - 1)
        } else {
            next = step > 0 ? 0 : visibleRows.count - 1
        }
        let row = visibleRows[next].row
        gtk_list_box_select_row(list, row.cast())
        scroll(to: row)
    }

    private func scroll(to row: OpaquePointer) {
        var bounds = graphene_rect_t()
        guard gtk_widget_compute_bounds(row.cast(), list.cast(), &bounds) != 0,
              let adjustment = gtk_scrolled_window_get_vadjustment(scroller) else { return }
        let top = Double(bounds.origin.y), bottom = top + Double(bounds.size.height)
        let value = gtk_adjustment_get_value(adjustment), page = gtk_adjustment_get_page_size(adjustment)
        if top < value { gtk_adjustment_set_value(adjustment, top) }
        else if bottom > value + page { gtk_adjustment_set_value(adjustment, bottom - page) }
    }

    func clearSelection() {
        gtk_list_box_unselect_all(list)
        updateSendLabel()
    }

    // MARK: Sending

    var currentPayload: PanelPayload? {
        if let payload = PanelText.returnPayload(selected: selectedRow(), text: fieldText) { return payload }
        return attached.isEmpty ? nil : .files(attached.map { URL(string: $0)?.lastPathComponent ?? $0 })
    }

    private(set) var sendLabel = "Pair a device to send"

    private func updateSendLabel() {
        let text = PanelText.sendLabel(currentPayload, device: selectedDevice)
        sendLabel = text
        gtk_button_set_label(sendButton.cast(), text)
        if let label = gtk_button_get_child(sendButton.cast()) {
            gtk_label_set_ellipsize(OpaquePointer(label), PANGO_ELLIPSIZE_END)
        }
        cf_accessible_label(sendButton.cast(), text)
        controls.removeAll { $0.role == "button" && ($0.label.hasPrefix("Send") || $0.label.hasPrefix("Pair a device")) }
        controls.append(Control(role: "button", label: text))
        gtk_widget_set_sensitive(sendButton.cast(), currentPayload != nil && selectedDevice != nil ? 1 : 0)
    }

    private func pressReturn() {
        // Return sends the selected row if there is one, otherwise the text in the field.
        let payload = PanelText.returnPayload(selected: selectedRow(), text: fieldText)
        switch payload {
        case .row(let row)?: lastReturn = "row:" + row.id
        case .text?: lastReturn = "text"
        default: lastReturn = "nothing"
        }
        guard let payload, let device = selectedDevice else { return }
        actions?.send(payload, to: device, keep: gtk_switch_get_active(keepSwitch) == 0)
    }

    private func sendCurrent() {
        guard let payload = currentPayload, let device = selectedDevice else { return }
        actions?.send(payload, to: device, keep: gtk_switch_get_active(keepSwitch) == 0)
    }

    func attach(_ uris: [String]) {
        attached = uris
        updateSendLabel()
    }

    // MARK: Showing

    func focusField() { gtk_widget_grab_focus(entry.cast()) }

    /// Without the keyboard (hover, drag) no control should look focused.
    func clearFocus() { gtk_window_set_focus(window.cast(), nil) }

    func didHide() {
        clearSelection()
        composing = false
    }

    var surfaceWidget: OpaquePointer { surface }

    private func replace(role: String, old: [String], with label: String) {
        controls.removeAll { $0.role == role && old.contains($0.label) }
        controls.append(Control(role: role, label: label))
    }
}
