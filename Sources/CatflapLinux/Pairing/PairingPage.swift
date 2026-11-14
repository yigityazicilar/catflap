import CAdwaita
import CGtk
import CGtkShim
import CatflapCore
import Foundation

/// Pairing inside the panel, driving the agent's pairing commands (`pair.start`, `pair.join`,
/// `pair.status`, `pair.confirm`, `pair.decline`). The code is long (a few hundred
/// characters), so nobody types it: the device that makes it offers Copy, the other a field
/// to paste it into. Both then show the six digits large, with the other device's name.
// Touched only on the GTK thread, like the panel itself.
final class PairingPage: @unchecked Sendable {
    struct Report: Codable, Sendable, Equatable {
        var step: String
        var state: String
        var role: String?
        var hasCode: Bool
        var digits: String?
        var peerName: String?
        var error: String?
        enum CodingKeys: String, CodingKey {
            case step, state, role, digits, error
            case hasCode = "has_code", peerName = "peer_name"
        }
    }

    private unowned let controller: PanelController
    let widget: OpaquePointer
    private let stack: OpaquePointer
    private let codeField: OpaquePointer
    private let joinButton: OpaquePointer
    private let digitsLabel: OpaquePointer
    private let confirmText: OpaquePointer
    private let waitingLabel: OpaquePointer
    private let doneLabel: OpaquePointer
    private let failedLabel: OpaquePointer
    private let expiresLabel: OpaquePointer
    private var status = PairingStatus(state: .idle)
    private var code: String?
    private var poll: UInt32 = 0
    private var busy = false
    private(set) var step = "choose"

    init(controller: PanelController) {
        self.controller = controller
        widget = opaque(gtk_box_new(GTK_ORIENTATION_VERTICAL, 12))
        let header = opaque(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6))
        let back = opaque(gtk_button_new_from_icon_name("go-previous-symbolic"))
        gtk_widget_add_css_class(back.cast(), "flat")
        cf_accessible_label(back.cast(), "Back to the list")
        gtk_widget_set_tooltip_text(back.cast(), "Back to the list")
        let title = opaque(gtk_label_new("Pair a device"))
        gtk_widget_add_css_class(title.cast(), "title-4")
        gtk_box_append(header.cast(), back.cast())
        gtk_box_append(header.cast(), title.cast())
        gtk_box_append(widget.cast(), header.cast())

        stack = opaque(gtk_stack_new())
        gtk_stack_set_transition_type(stack, GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_widget_set_vexpand(stack.cast(), 1)
        gtk_box_append(widget.cast(), stack.cast())

        // Choose: make a code here, or paste one made on the other device.
        let choose = Self.page()
        Self.text(choose, "Pairing links this device with another of yours, once. Make a code here and paste it on the other device, or paste a code the other device made.")
        let show = Self.button("Show a code", suggested: true)
        let enter = Self.button("Enter a code")
        gtk_box_append(choose.cast(), show.cast())
        gtk_box_append(choose.cast(), enter.cast())
        gtk_stack_add_named(stack, choose.cast(), "choose")

        // Code shown on this device.
        let shown = Self.page()
        Self.text(shown, "On the other device, open Catflap, choose Pair a device, then Enter a code, and paste this code there.")
        let copy = Self.button("Copy code", suggested: true)
        gtk_box_append(shown.cast(), copy.cast())
        expiresLabel = opaque(gtk_label_new(""))
        gtk_widget_add_css_class(expiresLabel.cast(), "dim-label")
        gtk_widget_add_css_class(expiresLabel.cast(), "caption")
        gtk_box_append(shown.cast(), expiresLabel.cast())
        let cancelShown = Self.button("Cancel")
        gtk_box_append(shown.cast(), cancelShown.cast())
        gtk_stack_add_named(stack, shown.cast(), "code")

        // Paste a code from the other device.
        let enterPage = Self.page()
        Self.text(enterPage, "Paste the code the other device shows.")
        codeField = opaque(gtk_password_entry_new())
        gtk_password_entry_set_show_peek_icon(codeField, 0)
        cf_accessible_label(codeField.cast(), "Pairing code")
        gtk_box_append(enterPage.cast(), codeField.cast())
        joinButton = Self.button("Pair", suggested: true)
        gtk_box_append(enterPage.cast(), joinButton.cast())
        let cancelEnter = Self.button("Cancel")
        gtk_box_append(enterPage.cast(), cancelEnter.cast())
        gtk_stack_add_named(stack, enterPage.cast(), "enter")

        // Connecting, or waiting for the other device to answer.
        let waiting = Self.page()
        let spinner = opaque(gtk_spinner_new())
        gtk_spinner_start(spinner)
        gtk_box_append(waiting.cast(), spinner.cast())
        waitingLabel = Self.text(waiting, "Connecting…")
        let cancelWaiting = Self.button("Cancel")
        gtk_box_append(waiting.cast(), cancelWaiting.cast())
        gtk_stack_add_named(stack, waiting.cast(), "waiting")

        // The six digits, large, on both devices.
        let confirm = Self.page()
        digitsLabel = opaque(gtk_label_new(""))
        gtk_widget_add_css_class(digitsLabel.cast(), "title-1")
        gtk_widget_add_css_class(digitsLabel.cast(), "numeric")
        gtk_label_set_selectable(digitsLabel, 1)
        gtk_box_append(confirm.cast(), digitsLabel.cast())
        confirmText = Self.text(confirm, "")
        let match = Self.button("They match", suggested: true)
        let differ = Self.button("They differ")
        gtk_box_append(confirm.cast(), match.cast())
        gtk_box_append(confirm.cast(), differ.cast())
        gtk_stack_add_named(stack, confirm.cast(), "confirm")

        let done = Self.page()
        doneLabel = Self.text(done, "")
        let finish = Self.button("Done", suggested: true)
        gtk_box_append(done.cast(), finish.cast())
        gtk_stack_add_named(stack, done.cast(), "done")

        let failed = Self.page()
        failedLabel = Self.text(failed, "")
        let again = Self.button("Try again", suggested: true)
        gtk_box_append(failed.cast(), again.cast())
        gtk_stack_add_named(stack, failed.cast(), "failed")

        GLib.connect(back, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.leave() }
        GLib.connect(show, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.start() }
        GLib.connect(enter, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.go("enter") }
        GLib.connect(copy, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in _ = self?.copyCode() }
        GLib.connect(joinButton, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.join(nil) }
        GLib.connect(codeField, "activate", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.join(nil) }
        GLib.connect(match, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.confirm() }
        for button in [differ, cancelShown, cancelEnter, cancelWaiting] {
            GLib.connect(button, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.decline() }
        }
        GLib.connect(finish, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.leave() }
        GLib.connect(again, "clicked", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.go("choose") }
    }

    private static func page() -> OpaquePointer {
        let box = opaque(gtk_box_new(GTK_ORIENTATION_VERTICAL, 12))
        gtk_widget_set_valign(box.cast(), GTK_ALIGN_CENTER)
        return box
    }

    @discardableResult
    private static func text(_ box: OpaquePointer, _ text: String) -> OpaquePointer {
        let label = opaque(gtk_label_new(text))
        gtk_label_set_wrap(label, 1)
        gtk_label_set_justify(label, GTK_JUSTIFY_CENTER)
        gtk_label_set_max_width_chars(label, 44)
        gtk_box_append(box.cast(), label.cast())
        return label
    }

    private static func button(_ title: String, suggested: Bool = false) -> OpaquePointer {
        let button = opaque(gtk_button_new_with_label(title))
        gtk_widget_add_css_class(button.cast(), "pill")
        if suggested { gtk_widget_add_css_class(button.cast(), "suggested-action") }
        gtk_widget_set_halign(button.cast(), GTK_ALIGN_CENTER)
        return button
    }

    var report: Report {
        Report(step: step, state: status.state.rawValue, role: status.role?.rawValue, hasCode: code != nil,
               digits: step == "confirm" ? status.digits : nil, peerName: status.peerName, error: status.error)
    }

    private func go(_ name: String) {
        let changed = name != step
        step = name
        gtk_stack_set_visible_child_name(stack, name)
        guard changed else { return }
        if name == "enter" { gtk_widget_grab_focus(codeField.cast()) }
        controller.snapshot("pair-" + name)
        controller.publish()
    }

    func willShow() {
        if !status.isActive && (step == "done" || step == "failed") { go("choose") }
    }

    func focus() {
        if step == "enter" { gtk_widget_grab_focus(codeField.cast()) }
    }

    /// The panel closed; a pairing in progress goes on and is shown again when it reopens.
    func panelHidden() {}

    private func leave() {
        if status.isActive { decline() }
        controller.extras.show(page: "main")
    }

    func stop() {
        if poll != 0 { GLib.cancel(poll); poll = 0 }
    }

    // MARK: Driving the agent's pairing

    func start() {
        request("pair.start", [:])
    }

    func join(_ given: String?) {
        let text = given ?? (gtk_editable_get_text(codeField).map { String(cString: $0) } ?? "")
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        gtk_editable_set_text(codeField, "")
        request("pair.join", ["code": code])
    }

    func confirm() { request("pair.confirm", [:]) }

    func decline() { request("pair.decline", [:]) }

    /// Puts this device's code on the clipboard, marked so clipboard histories skip it.
    @discardableResult
    func copyCode() -> Bool {
        guard let code else { return false }
        controller.clipboard.set(secret: code)
        controller.extras.setMessage("Code copied. Paste it on the other device.")
        return true
    }

    private func request(_ command: String, _ arguments: [String: String], done: (@Sendable (String?) -> Void)? = nil) {
        let runtime = controller.runtime, loop = controller.loop
        controller.track(Task { [weak self] in
            let response = await runtime.handle(ControlRequest(command, arguments: arguments))
            let next = response.ok ? try? response.decode(PairingStatus.self) : nil
            await loop.perform { [weak self] in
                guard let self else { return }
                if let next { show(next) } else { fail(response.error ?? "Pairing did not start.") }
            }
            done?(response.ok ? nil : (response.error ?? "Pairing did not start."))
        })
    }

    /// Starts a request and answers once the agent has answered it.
    func perform(_ command: String, _ arguments: [String: String] = [:]) async -> String? {
        await withCheckedContinuation { (result: CheckedContinuation<String?, Never>) in
            GLib.idle { [self] in request(command, arguments) { result.resume(returning: $0) } }
        }
    }

    private func fail(_ message: String) {
        status = PairingStatus(state: .failed)
        status.error = message
        gtk_label_set_text(failedLabel, message)
        go("failed")
    }

    private func show(_ next: PairingStatus) {
        status = next
        if let value = next.code { code = value }
        if !next.isActive && next.state != .paired { code = nil }
        let peer = next.peerName ?? "the other device"
        switch next.state {
        case .idle:
            code = nil
            go("choose")
        case .starting, .connecting, .exchanging:
            gtk_label_set_text(waitingLabel, next.state == .exchanging ? "Finishing…" : "Connecting…")
            go("waiting")
        case .waiting:
            if next.role == .initiator {
                if let expires = next.expiresAt {
                    let formatter = DateFormatter()
                    formatter.timeStyle = .short
                    gtk_label_set_text(expiresLabel, "The code works once, until \(formatter.string(from: expires)).")
                }
                go("code")
            } else {
                gtk_label_set_text(waitingLabel, "Connecting…")
                go("waiting")
            }
        case .confirm:
            let digits = next.digits ?? ""
            let spaced = digits.count == 6 ? String(digits.prefix(3)) + " " + String(digits.suffix(3)) : digits
            gtk_label_set_text(digitsLabel, spaced)
            cf_accessible_label(digitsLabel.cast(), digits.map { String($0) }.joined(separator: " "))
            gtk_label_set_text(confirmText, "Check that \(peer) shows the same six digits.")
            go("confirm")
        case .confirmed:
            gtk_label_set_text(waitingLabel, "Waiting for \(peer) to confirm…")
            go("waiting")
        case .paired:
            code = nil
            gtk_label_set_text(doneLabel, "Paired with \(peer).")
            go("done")
            controller.refresh()
            controller.watcher.devicesMayHaveChanged()
        case .failed:
            code = nil
            gtk_label_set_text(failedLabel, next.error ?? "Pairing did not finish. Nothing was stored.")
            go("failed")
        }
        schedulePoll()
    }

    /// Follows a pairing in progress with short status requests.
    private func schedulePoll() {
        if poll != 0 { GLib.cancel(poll); poll = 0 }
        guard status.isActive, !controller.stopped else { return }
        poll = GLib.timeout(milliseconds: 300) { [weak self] in
            guard let self else { return }
            poll = 0
            guard !busy else { schedulePoll(); return }
            busy = true
            let runtime = controller.runtime, loop = controller.loop
            controller.track(Task { [weak self] in
                let next = await PanelController.request(PairingStatus.self, "pair.status", runtime)
                await loop.perform { [weak self] in
                    guard let self else { return }
                    busy = false
                    if let next { show(next) } else { schedulePoll() }
                }
            })
        }
    }
}
