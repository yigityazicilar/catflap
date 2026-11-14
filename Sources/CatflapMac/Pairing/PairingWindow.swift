#if os(macOS)
import AppKit
import CatflapCore

/// Drives one pairing through the agent's own pairing commands (`pair.start`, `pair.join`,
/// `pair.status`, `pair.confirm`, `pair.decline`), the same ones `catflap pair` uses, and
/// keeps the latest status for the window and for `ui state`.
@MainActor
final class PairingFlow {
    let runtime: AgentRuntime
    private(set) var status = PairingStatus(state: .idle)
    /// The refusal of the last command, if it was refused.
    private(set) var message: String?
    var onChange: (() -> Void)?
    private var poller: Task<Void, Never>?

    init(runtime: AgentRuntime) { self.runtime = runtime }

    func stop() { poller?.cancel(); poller = nil }

    /// This device makes the code. The command can take a few seconds; it runs on its own.
    func start() { run("pair.start") }

    /// This device joins the one that made `code`.
    func join(_ code: String) {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { message = "Paste the code from the other device first."; onChange?(); return }
        run("pair.join", ["code": text])
    }

    func confirm() { run("pair.confirm") }
    func decline() { run("pair.decline") }

    /// Puts the code on the clipboard, marked so clipboard managers leave it out.
    func copyCode() -> Bool {
        guard let code = status.code, status.state == .waiting else { return false }
        PasteboardWriter.write(text: code, concealed: true)
        return true
    }

    private func run(_ command: String, _ arguments: [String: String] = [:]) {
        message = nil
        let runtime = runtime
        Task { [weak self] in
            let response = await runtime.handle(ControlRequest(command, arguments: arguments))
            guard let self else { return }
            if !response.ok { self.message = response.error ?? "Pairing did not start." }
            await self.refresh()
            self.watch()
        }
    }

    func refresh() async {
        if let service = await runtime.service(PairingService.self) {
            status = await service.currentStatus()
        }
        onChange?()
    }

    /// Follows the pairing until it ends.
    private func watch() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
                if !self.status.isActive { self.poller = nil; return }
            }
        }
    }
}

@MainActor
protocol PairingWindowActions: AnyObject {
    func pairingStart()
    func pairingJoin(_ code: String)
    func pairingCopyCode()
    func pairingConfirm()
    func pairingDecline()
}

/// The pairing window. One device shows a code with a Copy button; the other pastes it. Both
/// then show the same six digits, large, with the other device's name, and each person
/// confirms that they match. The code itself is never shown: it is long and only travels by
/// the clipboard.
@MainActor
final class PairingWindowController: NSObject, NSWindowDelegate {
    weak var actions: PairingWindowActions?
    let window: NSWindow
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let digits = NSTextField(labelWithString: "")
    private let start = NSButton(title: "Show a Code", target: nil, action: nil)
    private let copy = NSButton(title: "Copy Code", target: nil, action: nil)
    private let codeField = NSTextField()
    private let join = NSButton(title: "Join", target: nil, action: nil)
    private let confirm = NSButton(title: "They Match", target: nil, action: nil)
    private let decline = NSButton(title: "Cancel", target: nil, action: nil)
    private let problem = NSTextField(wrappingLabelWithString: "")
    private let joinRow: NSStackView
    private let choices: NSStackView

    var isOpen: Bool { window.isVisible }

    override init() {
        joinRow = NSStackView(views: [codeField, join])
        choices = NSStackView(views: [decline, confirm])
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable],
                          backing: .buffered, defer: true)
        super.init()
        window.title = "Pair a Device"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        build()
    }

    private func build() {
        headline.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        detail.textColor = .secondaryLabelColor
        for field in [headline, detail, problem] { field.preferredMaxLayoutWidth = 380 }
        digits.font = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        digits.alignment = .center
        digits.setAccessibilityLabel("Six digits to compare")
        problem.textColor = .systemOrange
        codeField.placeholderString = "Paste the code from the other device"
        codeField.setAccessibilityLabel("Pairing code from the other device")
        codeField.lineBreakMode = .byTruncatingMiddle
        codeField.usesSingleLineMode = true
        codeField.target = self
        codeField.action = #selector(joinPressed)
        codeField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        for (button, selector) in [(start, #selector(startPressed)), (copy, #selector(copyPressed)), (join, #selector(joinPressed)),
                                   (confirm, #selector(confirmPressed)), (decline, #selector(declinePressed))] {
            button.target = self
            button.action = selector
            button.bezelStyle = .push
        }
        confirm.keyEquivalent = "\r"
        copy.setAccessibilityLabel("Copy the pairing code")
        joinRow.spacing = 8
        choices.spacing = 8
        let stack = NSStackView(views: [headline, detail, digits, start, copy, joinRow, choices, problem])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(20, after: detail)
        window.contentView = stack
    }

    func show() {
        if !window.isVisible { window.center() }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.orderOut(nil) }

    func windowWillClose(_ notification: Notification) {}

    static func spaced(_ digits: String) -> String {
        guard digits.count == 6 else { return digits }
        return String(digits.prefix(3)) + " " + String(digits.suffix(3))
    }

    func render(_ status: PairingStatus, message: String?, thisDevice: String) {
        let peer = status.peerName ?? "the other device"
        var showStart = false, showCopy = false, showJoin = false, showChoices = false, showDigits = false
        decline.title = "Cancel"
        switch status.state {
        case .idle, .failed:
            headline.stringValue = status.state == .failed ? "Pairing did not finish" : "Pair a device"
            detail.stringValue = "Show a code on this Mac and paste it on the other device, or paste the code the other device shows."
            showStart = true; showJoin = true
        case .paired:
            headline.stringValue = "Paired with \(peer)"
            detail.stringValue = "\(thisDevice) and \(peer) can now send to each other."
            showStart = true; showJoin = true
        case .starting:
            headline.stringValue = "Making a code\u{2026}"
            detail.stringValue = "This takes a few seconds."
            showChoices = true
        case .waiting:
            headline.stringValue = "Copy this code to the other device"
            detail.stringValue = "Paste it there in Catflap's Pair a Device. The code works once, for ten minutes."
            showCopy = true; showChoices = true
        case .connecting:
            headline.stringValue = "Connecting\u{2026}"
            detail.stringValue = "Reaching the device that made the code."
            showChoices = true
        case .confirm:
            headline.stringValue = "Do the digits match?"
            detail.stringValue = "Check that \(peer) shows the same six digits. Confirm on both devices."
            showDigits = true; showChoices = true
            decline.title = "They Don't Match"
        case .confirmed, .exchanging:
            headline.stringValue = "Waiting for \(peer)\u{2026}"
            detail.stringValue = "Confirm on \(peer) as well."
            showDigits = true
        }
        digits.stringValue = Self.spaced(status.digits ?? "")
        digits.isHidden = !showDigits
        start.isHidden = !showStart
        copy.isHidden = !showCopy
        joinRow.isHidden = !showJoin
        confirm.isHidden = status.state != .confirm
        choices.isHidden = !showChoices
        let failure = message ?? (status.state == .failed ? status.error : nil)
        problem.stringValue = failure ?? ""
        problem.isHidden = (failure ?? "").isEmpty
    }

    @objc private func startPressed() { actions?.pairingStart() }
    @objc private func copyPressed() { actions?.pairingCopyCode() }
    @objc private func joinPressed() { actions?.pairingJoin(codeField.stringValue) }
    @objc private func confirmPressed() { actions?.pairingConfirm() }
    @objc private func declinePressed() { actions?.pairingDecline() }

    func clearCode() { codeField.stringValue = "" }
}
#endif
