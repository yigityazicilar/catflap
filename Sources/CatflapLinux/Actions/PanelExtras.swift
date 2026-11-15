import CAdwaita
import CGtk
import CGtkShim
import CatflapCore
import Foundation

/// What the panel adds around T10's widgets: pages for pairing and settings beside the list,
/// the files attached to the next send, actions for the selected row (Copy, Delete, Retry,
/// Show in folder), and a line that says how the last send went, with Retry and Remove.
///
/// T10's widgets stay as they are. They move, in order, into the first page of a stack that
/// takes their place in the panel's surface.
// Touched only on the GTK thread, like the panel itself.
final class PanelExtras: @unchecked Sendable {
    private unowned let view: PanelView
    private unowned let controller: PanelController
    private let stack: OpaquePointer
    private let entry: OpaquePointer
    private let list: OpaquePointer
    private let keepSwitch: OpaquePointer
    private let attachmentsBox: OpaquePointer
    private let actionBar: OpaquePointer
    private let copyButton: OpaquePointer
    private let deleteButton: OpaquePointer
    private let retryRowButton: OpaquePointer
    private let revealButton: OpaquePointer
    private let messageBar: OpaquePointer
    private let messageLabel: OpaquePointer
    private let messageRetry: OpaquePointer
    private let messageRemove: OpaquePointer
    private var chips: [OpaquePointer] = []
    /// Attached files, as file URIs.
    private(set) var attachments: [String] = []
    private(set) var message = ""
    private var retryTarget: (device: String, id: String)?
    private var removeTarget: (id: String, name: String)?
    private(set) var controls: [PanelView.Control] = []

    init(view: PanelView, controller: PanelController) {
        self.view = view
        self.controller = controller
        let surface = view.surfaceWidget
        var children: [OpaquePointer] = []
        var child = gtk_widget_get_first_child(surface.cast())
        while let current = child {
            children.append(OpaquePointer(current))
            child = gtk_widget_get_next_sibling(current)
        }
        // T10's order: field, Attach, devices, switch, list, send button, footer.
        entry = children[0]
        let scroller = children[4]
        // The list, inside the viewport GTK puts between a scrolled window and a child that
        // does not scroll by itself.
        var inner = OpaquePointer(gtk_scrolled_window_get_child(scroller))!
        if g_type_check_instance_is_a(UnsafeMutablePointer(inner), gtk_list_box_get_type()) == 0,
           let child = gtk_widget_get_first_child(inner.cast()) {
            inner = OpaquePointer(child)
        }
        list = inner
        // The footer: connection, "Don't keep" label, its switch, pause, settings.
        var footerChildren: [OpaquePointer] = []
        var footerChild = gtk_widget_get_first_child(children[6].cast())
        while let current = footerChild {
            footerChildren.append(OpaquePointer(current))
            footerChild = gtk_widget_get_next_sibling(current)
        }
        keepSwitch = footerChildren[2]

        let main = opaque(gtk_box_new(GTK_ORIENTATION_VERTICAL, 10))
        attachmentsBox = opaque(gtk_flow_box_new())
        gtk_flow_box_set_selection_mode(attachmentsBox, GTK_SELECTION_NONE)
        gtk_flow_box_set_max_children_per_line(attachmentsBox, 3)
        gtk_widget_set_visible(attachmentsBox.cast(), 0)

        actionBar = opaque(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4))
        copyButton = Self.iconButton("edit-copy-symbolic", "Copy")
        deleteButton = Self.iconButton("user-trash-symbolic", "Delete")
        retryRowButton = Self.iconButton("view-refresh-symbolic", "Retry")
        revealButton = Self.iconButton("folder-open-symbolic", "Show in folder")
        for button in [copyButton, deleteButton, retryRowButton, revealButton] { gtk_box_append(actionBar.cast(), button.cast()) }
        gtk_widget_set_halign(actionBar.cast(), GTK_ALIGN_END)

        messageBar = opaque(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6))
        messageLabel = opaque(gtk_label_new(""))
        gtk_label_set_wrap(messageLabel, 1)
        gtk_label_set_xalign(messageLabel, 0)
        gtk_widget_set_hexpand(messageLabel.cast(), 1)
        gtk_widget_add_css_class(messageLabel.cast(), "caption")
        messageRetry = opaque(gtk_button_new_with_label("Retry"))
        messageRemove = opaque(gtk_button_new_with_label("Remove"))
        gtk_widget_add_css_class(messageRemove.cast(), "destructive-action")
        for widget in [messageLabel, messageRetry, messageRemove] { gtk_box_append(messageBar.cast(), widget.cast()) }
        gtk_widget_set_visible(messageBar.cast(), 0)

        for (index, widget) in children.enumerated() {
            g_object_ref(UnsafeMutableRawPointer(widget))
            gtk_box_remove(surface.cast(), widget.cast())
            gtk_box_append(main.cast(), widget.cast())
            g_object_unref(UnsafeMutableRawPointer(widget))
            if index == 1 { gtk_box_append(main.cast(), attachmentsBox.cast()) }
            if index == 4 {
                gtk_box_append(main.cast(), actionBar.cast())
                gtk_box_append(main.cast(), messageBar.cast())
            }
        }
        gtk_widget_set_vexpand(main.cast(), 1)
        stack = opaque(gtk_stack_new())
        gtk_stack_set_transition_type(stack, GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_set_vhomogeneous(stack, 0)
        gtk_widget_set_vexpand(stack.cast(), 1)
        gtk_stack_add_named(stack, main.cast(), "main")
        gtk_box_append(surface.cast(), stack.cast())

        label(messageRetry, "Retry the send")
        label(messageRemove, "Remove this device")
        connect()
        listChanged()
    }

    private static func iconButton(_ icon: String, _ text: String) -> OpaquePointer {
        let button = opaque(gtk_button_new_from_icon_name(icon))
        gtk_widget_add_css_class(button.cast(), "flat")
        cf_accessible_label(button.cast(), text)
        gtk_widget_set_tooltip_text(button.cast(), text)
        return button
    }

    private func label(_ widget: OpaquePointer, _ text: String) {
        cf_accessible_label(widget.cast(), text)
        controls.append(PanelView.Control(role: "button", label: text))
    }

    private func connect() {
        for (button, text) in [(copyButton, "Copy"), (deleteButton, "Delete"), (retryRowButton, "Retry"), (revealButton, "Show in folder")] {
            controls.append(PanelView.Control(role: "button", label: text))
            _ = button
        }
        GLib.connect(list, "row-selected", Int32(CF_SHAPE_OBJECT)) { [weak self] _ in self?.listChanged() }
        GLib.connect(copyButton, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in
            guard let self, let row = view.selectedRow() else { return }
            controller.sender.copy(row)
        }
        GLib.connect(deleteButton, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in
            guard let self, let row = view.selectedRow() else { return }
            controller.sender.delete(row)
        }
        GLib.connect(retryRowButton, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in
            guard let self, let row = view.selectedRow(), let record = controller.record(for: row) else { return }
            let device = record.deviceID, id = record.id
            controller.sender.retry(deviceID: device, id: id)
        }
        GLib.connect(revealButton, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in
            guard let self, let row = view.selectedRow(), let path = controller.record(for: row)?.path else { return }
            controller.notifier.reveal(path)
        }
        GLib.connect(messageRetry, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in
            guard let self, let target = retryTarget else { return }
            controller.sender.retry(deviceID: target.device, id: target.id)
        }
        GLib.connect(messageRemove, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in
            guard let self, let target = removeTarget else { return }
            controller.sender.remove(deviceID: target.id, name: target.name)
        }
    }

    // MARK: Pages

    var page: String {
        gtk_stack_get_visible_child_name(stack).map { String(cString: $0) } ?? "main"
    }

    func add(page widget: OpaquePointer, named name: String) {
        gtk_stack_add_named(stack, widget.cast(), name)
    }

    func show(page name: String) {
        gtk_stack_set_visible_child_name(stack, name)
        if name == "settings" { controller.settingsPage.willShow() }
        if name == "pair" { controller.pairing.willShow() }
        if controller.machine.mode == .focused { focusDefault() }
        controller.snapshot(controller.machine.mode.rawValue + "-" + name)
        controller.publish()
    }

    func focusDefault() {
        switch page {
        case "pair": controller.pairing.focus()
        case "settings": controller.settingsPage.focus()
        default: view.focusField()
        }
    }

    func didHide() {
        if page != "main" { gtk_stack_set_visible_child_name(stack, "main") }
        controller.pairing.panelHidden()
    }

    // MARK: Attachments

    var attachmentNames: [String] { attachments.map { URL(string: $0)?.lastPathComponent ?? $0 } }

    /// Adds files to the next send. Paths and file URIs are both accepted.
    func attach(_ files: [String]) {
        for file in files {
            let uri = file.hasPrefix("file://") ? file : URL(fileURLWithPath: file).absoluteString
            if !attachments.contains(uri) { attachments.append(uri) }
        }
        renderAttachments()
    }

    func clearAttachments() {
        attachments = []
        renderAttachments()
    }

    /// Takes these files (by path) off the attachments and leaves the rest attached.
    func detach(_ paths: [String]) {
        attachments.removeAll { uri in URL(string: uri).map { paths.contains($0.path) } ?? false }
        renderAttachments()
    }

    var attachedPaths: [String] { attachments.compactMap { URL(string: $0)?.path } }

    private func renderAttachments() {
        for chip in chips { gtk_flow_box_remove(attachmentsBox, chip.cast()) }
        chips = []
        controls.removeAll { $0.role == "attachment" }
        for (index, name) in attachmentNames.enumerated() {
            let button = opaque(gtk_button_new())
            let content = opaque(adw_button_content_new())
            adw_button_content_set_icon_name(content, "window-close-symbolic")
            adw_button_content_set_label(content, name)
            gtk_button_set_child(button.cast(), content.cast())
            gtk_widget_add_css_class(button.cast(), "pill")
            gtk_widget_add_css_class(button.cast(), "small")
            let text = "Remove attachment \(name)"
            cf_accessible_label(button.cast(), text)
            gtk_widget_set_tooltip_text(button.cast(), text)
            controls.append(PanelView.Control(role: "attachment", label: text))
            let uri = attachments[index]
            GLib.connect(button, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in
                guard let self else { return }
                attachments.removeAll { $0 == uri }
                renderAttachments()
            }
            gtk_flow_box_append(attachmentsBox, button.cast())
            chips.append(button)
        }
        gtk_widget_set_visible(attachmentsBox.cast(), attachments.isEmpty ? 0 : 1)
        // The send button names the files; T10's view counts them by name.
        view.attach(attachments)
        controller.publish()
    }

    /// The system file picker; the chosen files are attached. The panel steps aside while the
    /// picker is open: it sits on the overlay layer above every window, so it would cover the
    /// picker and keep the keyboard. It comes back focused, with the files attached.
    func pickFiles() {
        controller.ensureFocused()
        controller.dialogOpen = true
        controller.host.withdraw(view.window)
        controller.publish()
        controller.picker.openFiles(parent: nil) { [weak self] uris in
            guard let self else { return }
            controller.dialogOpen = false
            if !uris.isEmpty { attach(uris) }
            controller.returnFromDialog()
        }
    }

    // MARK: Selected row

    func listChanged() {
        let row = view.selectedRow()
        let record = row.flatMap { controller.record(for: $0) }
        gtk_widget_set_visible(actionBar.cast(), row == nil ? 0 : 1)
        let copyable = row.map { $0.source == .clipboard || record?.path != nil || record?.kind == "text" } ?? false
        gtk_widget_set_sensitive(copyButton.cast(), copyable ? 1 : 0)
        gtk_widget_set_visible(retryRowButton.cast(), record?.canRetry == true ? 1 : 0)
        gtk_widget_set_visible(revealButton.cast(), record?.path != nil ? 1 : 0)
        if let row {
            cf_accessible_label(copyButton.cast(), "Copy \(row.title)")
            cf_accessible_label(deleteButton.cast(), "Delete \(row.title)")
        }
    }

    // MARK: The line under the list

    var messageActions: [String] {
        var actions: [String] = []
        if retryTarget != nil { actions.append("retry") }
        if removeTarget != nil { actions.append("remove") }
        return actions
    }

    func setMessage(_ text: String, retry: (device: String, id: String)? = nil, remove: (id: String, name: String)? = nil) {
        message = text
        retryTarget = retry
        removeTarget = remove
        gtk_label_set_text(messageLabel, text)
        gtk_widget_set_visible(messageBar.cast(), text.isEmpty ? 0 : 1)
        gtk_widget_set_visible(messageRetry.cast(), retry == nil ? 0 : 1)
        gtk_widget_set_visible(messageRemove.cast(), remove == nil ? 0 : 1)
        if let remove { cf_accessible_label(messageRemove.cast(), "Remove \(remove.name)") }
        controller.publish()
    }

    // MARK: Keys

    /// Ctrl+V with files on the clipboard attaches them; Ctrl+C with a row selected and the
    /// field empty copies the row; Delete with a row selected deletes it.
    func key(_ keyval: UInt32, modifiers: UInt32) -> Bool {
        guard page == "main" else { return false }
        let control = modifiers & UInt32(GDK_CONTROL_MASK.rawValue) != 0
        switch keyval {
        case 0x76 where control, 0x56 where control:
            return pasteFiles()
        case 0x63 where control:
            guard view.fieldText.isEmpty, let row = view.selectedRow() else { return false }
            controller.sender.copy(row)
            return true
        case 0xffff:
            guard let row = view.selectedRow() else { return false }
            controller.sender.delete(row)
            return true
        default:
            return false
        }
    }

    private func pasteFiles() -> Bool {
        guard let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display),
              let formats = gdk_clipboard_get_formats(clipboard),
              gdk_content_formats_contain_gtype(formats, gdk_file_list_get_type()) != 0
                || gdk_content_formats_contain_mime_type(formats, "text/uri-list") != 0 else { return false }
        ClipboardWriter.readFiles(clipboard) { [weak self] uris in
            guard let self, !uris.isEmpty else { return }
            attach(uris)
        }
        return true
    }

    /// Puts text into the field, as typing would.
    func setField(_ text: String) {
        gtk_editable_set_text(entry, text)
    }

    /// The footer's "Don't keep" switch.
    var dontKeep: Bool { gtk_switch_get_active(keepSwitch) != 0 }

    func setDontKeep(_ on: Bool) { gtk_switch_set_active(keepSwitch, on ? 1 : 0) }
}
