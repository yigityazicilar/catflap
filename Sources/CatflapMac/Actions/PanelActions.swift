#if os(macOS)
import AppKit
import CatflapCore

/// A send or another action that did not happen, with the sentence to show.
struct ActionRefusal: Error, Sendable {
    let message: String
}

/// An attached file that did not start sending, with the sentence saying why.
struct NotSent: Codable, Sendable, Equatable {
    var file: String
    var reason: String
}

/// How starting a send went: the rows that started, while they are `sending`, and the attached
/// files that did not start. `files` are the attached files that started, in the order of `rows`.
struct SendStart: Sendable {
    var rows: [TransferRecord] = []
    var files: [URL] = []
    var notSent: [NotSent] = []
}

/// Everything the panel does beyond appearing and leaving: sending typed text, attached files
/// and list rows; Copy, Delete, Retry and Reveal; Attach through the open panel, pasted files
/// and the Services menu; the send-clipboard shortcut; notifications on arrival and on a
/// failed send; pairing, removing a device, and settings.
///
/// The panel (PanelController) owns the window, its states, its lists, the menu bar glyph and
/// the line saying how the last send went. It calls this object for what its controls do beyond
/// that; this object tells it how sends go, and adds its own `ui invoke` actions and `ui state`
/// fields (see ActionCommands.swift).
@MainActor
final class PanelActions {
    let runtime: AgentRuntime
    let controller: PanelController
    let notifier = Notifier()
    let history: HistoryWatcher
    let picker = FilePicker()
    let services = ServiceProvider()
    let pairing: PairingFlow
    /// The panel's shortcut, which the panel registers; settings rebind it here.
    var panelShortcut: ShortcutBinding { controller.shortcut }
    /// The send-clipboard shortcut, ⌃⌥⇧⌘Space by default.
    let sendShortcut = ShortcutBinding(name: ShortcutBinding.sendClipboardName, default: ShortcutBinding.sendClipboardDefault)
    private(set) var settings = MacSettings()
    private(set) var settingsWindow: SettingsWindowController?
    private(set) var pairingWindow: PairingWindowController?
    private(set) var settingsMessage = ""
    /// The last sentence an action ended with: a refusal, or what happened.
    private(set) var message = ""
    /// Whether the panel's own controls reach this object.
    var wired: Bool { controller.actions === self }
    /// The panel's Don't keep switch, as last set.
    var dontKeep = false
    /// The device chosen in the panel, when the person chose one.
    var chosenDevice: String?
    /// The row last selected by a click or by `ui invoke select`; nil once the selection may
    /// have moved without this object seeing where (arrow keys, typing, another list).
    var selectedRow: String?
    private let pollClipboard: @MainActor () async -> Void
    private var lastPanelSend: Task<Result<SendStart, ActionRefusal>, Never>?
    /// The row action (Copy, Delete, Reveal) the panel started most recently.
    private var lastRowAction: Task<Void, Never>?
    private var deviceNames: [String: String] = [:]
    private var stopped = false
    /// The registration `ui invoke test-hold-shortcut` made; test hooks only.
    var testHeldShortcut: HotKeyRegistrar.Registration?

    private init(runtime: AgentRuntime, controller: PanelController, pollClipboard: @escaping @MainActor () async -> Void) {
        self.runtime = runtime
        self.controller = controller
        self.pollClipboard = pollClipboard
        history = HistoryWatcher(runtime: runtime)
        pairing = PairingFlow(runtime: runtime)
    }

    /// Joins the panel that `controller` runs. `pollClipboard` reads the clipboard once, so
    /// a copy made a moment before the send-clipboard shortcut is seen first.
    static func start(runtime: AgentRuntime, controller: PanelController,
                      pollClipboard: @escaping @MainActor () async -> Void) async -> PanelActions {
        let actions = PanelActions(runtime: runtime, controller: controller, pollClipboard: pollClipboard)
        await actions.install()
        return actions
    }

    private func install() async {
        settings = await MacSettings.load(from: runtime.store)
        await refreshDevices()
        controller.actions = self
        sendShortcut.activate { [weak self] in
            guard let self else { return }
            Task { _ = await self.sendLatest() }
        }
        noteShortcuts()
        notifier.perform = { [weak self] action in self?.perform(action) }
        services.receive = { [weak self] urls in self?.attachFromElsewhere(urls) }
        NSApplication.shared.servicesProvider = services
        pairing.onChange = { [weak self] in self?.pairingChanged() }
        history.onChange = { [weak self] change in self?.historyChanged(change) }
        history.onRead = { [weak self] in self?.updateMoving() }
        await history.start()
        await registerCommands()
    }

    func stop() {
        stopped = true
        history.stop()
        pairing.stop()
        picker.cancel()
        sendShortcut.stop()
        releaseTestHeldShortcut()
        settingsWindow?.close()
        pairingWindow?.close()
        if controller.actions === self { controller.actions = nil }
        NSApplication.shared.servicesProvider = nil
    }

    func releaseTestHeldShortcut() {
        if let held = testHeldShortcut { HotKeyRegistrar.shared.unregister(held) }
        testHeldShortcut = nil
    }

    // MARK: Devices

    func refreshDevices() async {
        let devices = ((try? await runtime.store.devices()) ?? []).map(DeviceSummary.init)
        deviceNames = Dictionary(devices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        if let chosen = chosenDevice, deviceNames[chosen] == nil { chosenDevice = nil }
        if let window = settingsWindow { window.render(settings, devices: devices, message: settingsMessage) }
    }

    func devices() async -> [DeviceSummary] {
        ((try? await runtime.store.devices()) ?? []).map(DeviceSummary.init)
    }

    func name(of deviceID: String) -> String { deviceNames[deviceID] ?? "the other device" }

    /// A device by id or by name; without one, the device chosen in the panel, else the most
    /// recently used one, which the store lists first.
    func resolveDevice(_ text: String?) async -> DeviceSummary? {
        let list = await devices()
        if let text { return list.first { $0.id == text } ?? list.first { $0.name == text } }
        if let chosen = chosenDevice, let device = list.first(where: { $0.id == chosen }) { return device }
        return list.first
    }

    // MARK: Sending

    /// Return or the send button in the panel.
    func panelSend(_ payload: PanelPayload, to deviceID: String, keep: Bool) {
        let task = Task { [weak self] () -> Result<SendStart, ActionRefusal> in
            guard let self else { return .failure(ActionRefusal(message: "Catflap is stopping.")) }
            let outcome = await self.send(payload, to: deviceID, keep: keep)
            switch outcome {
            case .success(let start):
                // What was sent leaves the field, the attachment row and the selection. An
                // attached file that did not start stays attached, to be sent again.
                switch payload {
                case .text: self.controller.viewFilterChanged("")
                case .files: self.controller.removeAttachments(start.files)
                case .row: self.selectedRow = nil; self.controller.viewSelectRow(nil)
                }
            case .failure(let refusal):
                self.sendFailed(title: "Not sent to \(self.name(of: deviceID))", body: refusal.message)
            }
            return outcome
        }
        lastPanelSend = task
    }

    /// Retry on a history row in the panel.
    func panelRetry(_ rowID: String) {
        let (device, id) = Self.split(rowID)
        lastPanelSend = Task { [weak self] () -> Result<SendStart, ActionRefusal> in
            guard let self else { return .failure(ActionRefusal(message: "Catflap is stopping.")) }
            let outcome = await self.retry(deviceID: device, id: id)
            if case .failure(let refusal) = outcome { self.sendFailed(title: "Not sent to \(self.name(of: device))", body: refusal.message) }
            return outcome
        }
    }

    /// Copy, Delete and Reveal on a row in the panel. A refusal says why in a notification.
    func panelCopy(_ rowID: String) { rowAction("Cannot copy it") { await $0.copy(rowID: rowID) } }
    func panelDelete(_ rowID: String) { rowAction("Cannot delete it") { await $0.delete(rowID: rowID) } }
    func panelReveal(_ rowID: String) { rowAction("Cannot show the file") { await $0.reveal(rowID: rowID) } }

    private func rowAction(_ title: String, _ body: @escaping @Sendable @MainActor (PanelActions) async -> ActionRefusal?) {
        lastRowAction = Task { [weak self] in
            guard let self, let refusal = await body(self) else { return }
            self.notifier.problem(title: title, body: refusal.message)
        }
    }

    /// The row action the panel started most recently, for `ui invoke press`.
    func takeRowAction() -> Task<Void, Never>? {
        defer { lastRowAction = nil }
        return lastRowAction
    }

    /// A send that did not start or did not end well: the panel's line, and cf-problem until
    /// the panel next opens. With the panel closed a notification says it too.
    func sendFailed(title: String, body: String, retry: (deviceID: String, id: String)? = nil) {
        message = body
        controller.showSendLine(title + ". " + body, failed: true)
        controller.showProblem()
        if !controller.isVisible { notifier.problem(title: title, body: body, retry: retry) }
    }

    /// A send started: the panel's line, and cf-moving until history shows it ended.
    private func started(_ rows: [TransferRecord], to deviceID: String) {
        message = "Sending to \(name(of: deviceID))\u{2026}"
        controller.showSendLine(message, failed: false)
        for row in rows { history.markSending(row.deviceID + "/" + row.id) }
        updateMoving()
    }

    /// cf-moving while history shows anything sending or being received.
    private func updateMoving() {
        controller.showMoving(history.statuses.values.contains { $0 == "sending" || $0 == "receiving" })
    }

    /// The send the panel started most recently, for `ui invoke send`.
    func takePanelSend() -> Task<Result<SendStart, ActionRefusal>, Never>? {
        defer { lastPanelSend = nil }
        return lastPanelSend
    }

    /// Starts sending `payload`; returns the rows at once, while they are `sending`. How each
    /// ends is seen by the history watcher, whoever started it. Attached files start one by
    /// one: a file that cannot start (gone, unreadable, too large) does not stop the others,
    /// and is reported with its reason; only when none started is the send refused.
    func send(_ payload: PanelPayload, to deviceID: String, keep: Bool) async -> Result<SendStart, ActionRefusal> {
        guard let transfers = await runtime.service(TransferService.self) else {
            return .failure(ActionRefusal(message: "Sending is not available."))
        }
        var begun = SendStart()
        do {
            switch payload {
            case .text(let text):
                begun.rows.append(try await transfers.start(deviceID: deviceID, payload: .text(text), keep: keep))
            case .files(let urls):
                for url in urls {
                    do {
                        begun.rows.append(try await transfers.start(deviceID: deviceID, payload: .file(url), keep: keep))
                        begun.files.append(url)
                    } catch {
                        begun.notSent.append(NotSent(file: url.path, reason: Self.sentence(error)))
                    }
                }
                if begun.rows.isEmpty, let first = begun.notSent.first {
                    return .failure(ActionRefusal(message: urls.count == 1 ? first.reason : Self.notSentSentence(begun.notSent, started: 0)))
                }
            case .row(let row):
                switch row.kind {
                case .text, .url, .image, .files:
                    guard let clipboard = await runtime.service(ClipboardService.self) else {
                        return .failure(ActionRefusal(message: "Clipboard history is not available."))
                    }
                    begun.rows.append(try await clipboard.send(id: row.id, deviceID: deviceID, keep: keep))
                case .sent, .received:
                    let (device, id) = Self.split(row.id)
                    guard let record = try await transfers.history.record(deviceID: device, id: id) else {
                        return .failure(ActionRefusal(message: "That item is no longer in history."))
                    }
                    if record.kind == "text" {
                        guard let text = try await transfers.copyText(deviceID: device, id: id) else {
                            return .failure(ActionRefusal(message: "That text was not kept, so it cannot be sent again."))
                        }
                        begun.rows.append(try await transfers.start(deviceID: deviceID, payload: .text(text), keep: keep))
                    } else if let path = record.path, FileManager.default.fileExists(atPath: path) {
                        begun.rows.append(try await transfers.start(deviceID: deviceID, payload: .file(URL(fileURLWithPath: path)), keep: keep))
                    } else {
                        return .failure(ActionRefusal(message: "That file is not kept on this Mac, so it cannot be sent again."))
                    }
                }
            }
        } catch {
            return .failure(ActionRefusal(message: Self.sentence(error)))
        }
        started(begun.rows, to: deviceID)
        if !begun.notSent.isEmpty {
            sendFailed(title: "Not every file sent to \(name(of: deviceID))", body: Self.notSentSentence(begun.notSent, started: begun.rows.count))
        }
        return .success(begun)
    }

    /// Each attached file that did not start, with why, and how many others are on their way.
    static func notSentSentence(_ files: [NotSent], started: Int) -> String {
        let each = files.map { URL(fileURLWithPath: $0.file).lastPathComponent + ": " + $0.reason }.joined(separator: " ")
        switch started {
        case 0: return each
        case 1: return each + " The other file is on its way."
        default: return each + " The other \(started) files are on their way."
        }
    }

    /// The send-clipboard shortcut: the newest copy, if clipboard history recorded it, to the
    /// most recently used device. Success is quiet; a refusal says why in a notification.
    func sendLatest() async -> Result<SendStart, ActionRefusal> {
        // A copy made less than one poll before the shortcut is seen first.
        await pollClipboard()
        let response = await runtime.handle(ControlRequest("clip.send", arguments: ["latest": "true"]))
        guard response.ok, let row = try? response.decode(TransferRecord.self) else {
            let sentence = response.error ?? "Not sent."
            sendFailed(title: "Clipboard not sent", body: sentence)
            return .failure(ActionRefusal(message: sentence))
        }
        started([row], to: row.deviceID)
        return .success(SendStart(rows: [row]))
    }

    func retry(deviceID: String, id: String) async -> Result<SendStart, ActionRefusal> {
        guard let transfers = await runtime.service(TransferService.self) else {
            return .failure(ActionRefusal(message: "Sending is not available."))
        }
        do {
            let row = try await transfers.retry(deviceID: deviceID, id: id)
            started([row], to: deviceID)
            return .success(SendStart(rows: [row]))
        } catch {
            return .failure(ActionRefusal(message: Self.sentence(error)))
        }
    }

    // MARK: Copy, Delete, Reveal

    /// Puts a list row on the clipboard: a history row by `device/id`, a clipboard row by id.
    func copy(rowID: String) async -> ActionRefusal? {
        do {
            if rowID.contains("/") {
                let (device, id) = Self.split(rowID)
                guard let transfers = await runtime.service(TransferService.self),
                      let record = try await transfers.history.record(deviceID: device, id: id) else {
                    return ActionRefusal(message: "That item is no longer in history.")
                }
                if record.kind == "text" {
                    guard let text = try await transfers.copyText(deviceID: device, id: id) else {
                        return ActionRefusal(message: "That text was not kept, and the ten minutes to copy it are over.")
                    }
                    // A text that was not kept goes on the clipboard marked concealed, so no
                    // clipboard history, Catflap's own included, reads or keeps it. This is the
                    // Copy of the row, of the notification, and of received text put on the
                    // clipboard on arrival.
                    PasteboardWriter.write(text: text, concealed: !record.keep)
                } else if let path = record.path, FileManager.default.fileExists(atPath: path) {
                    PasteboardWriter.write(files: [URL(fileURLWithPath: path)])
                } else {
                    return ActionRefusal(message: "That file is not on this Mac any more.")
                }
            } else {
                guard let clipboard = await runtime.service(ClipboardHistory.self) else {
                    return ActionRefusal(message: "Clipboard history is not available.")
                }
                let item = try await clipboard.item(id: rowID)
                switch item.kind {
                case .text, .url: PasteboardWriter.write(text: item.text ?? "")
                case .image: PasteboardWriter.write(image: item.content, mime: item.mime)
                case .files:
                    let urls = (item.text ?? "").split(whereSeparator: \.isNewline).compactMap { URL(string: String($0)) }.filter(\.isFileURL)
                    PasteboardWriter.write(files: urls)
                }
            }
        } catch {
            return ActionRefusal(message: Self.sentence(error))
        }
        message = "Copied."
        return nil
    }

    /// Removes a row from its list. A received file stays in the inbox.
    func delete(rowID: String) async -> ActionRefusal? {
        do {
            if rowID.contains("/") {
                let (device, id) = Self.split(rowID)
                try await runtime.store.execute("DELETE FROM history WHERE device_id=? AND id=?", bindings: [.text(device), .text(id)])
            } else {
                guard let clipboard = await runtime.service(ClipboardHistory.self) else {
                    return ActionRefusal(message: "Clipboard history is not available.")
                }
                try await clipboard.delete(id: rowID)
            }
        } catch {
            return ActionRefusal(message: "Could not delete it.")
        }
        controller.viewSelectRow(nil)
        selectedRow = nil
        message = "Deleted."
        return nil
    }

    /// Shows a received file in Finder.
    func reveal(rowID: String) async -> ActionRefusal? {
        let (device, id) = Self.split(rowID)
        guard let transfers = await runtime.service(TransferService.self),
              let record = try? await transfers.history.record(deviceID: device, id: id),
              let path = record.path, FileManager.default.fileExists(atPath: path) else {
            return ActionRefusal(message: "That file is not on this Mac any more.")
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        message = "Shown in Finder."
        return nil
    }

    // MARK: Attach

    /// Attach in the panel: the open panel, then a focused panel with the chosen files.
    func openPicker() {
        picker.pickFiles { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            self.attach(urls)
        }
    }

    /// Attaches `urls` to a focused panel; Return or Send sends them.
    func attach(_ urls: [URL]) {
        ensureFocused()
        controller.viewDrop(urls)
    }

    /// Files from Finder's Services menu: a focused panel with the files attached and the
    /// most recently used device selected.
    func attachFromElsewhere(_ urls: [URL]) {
        attach(urls)
        Task { [weak self] in
            guard let self, let first = await self.devices().first else { return }
            self.chosenDevice = first.id
            self.controller.viewSelectDevice(first.id)
        }
    }

    /// ⌘V in the panel: files on the clipboard are attached. Returns false when it holds none,
    /// so the field pastes text as usual.
    func pasteFiles(from board: NSPasteboard = .general) -> Bool {
        let urls = PasteboardWriter.files(on: board)
        guard !urls.isEmpty else { return false }
        attach(urls)
        return true
    }

    func ensureFocused() { controller.showFocused() }

    /// What the panel's field holds.
    var fieldText: String { controller.fieldText }

    // MARK: Pause, Don't keep

    func setDontKeep(_ on: Bool) {
        dontKeep = on
        controller.viewSetDontKeep(on)
    }

    func setPaused(_ on: Bool) async -> ActionRefusal? {
        guard let clipboard = await runtime.service(ClipboardHistory.self) else {
            return ActionRefusal(message: "Clipboard history is not available.")
        }
        do { try await clipboard.setPaused(on) } catch { return ActionRefusal(message: "Could not change the pause.") }
        return nil
    }

    // MARK: Windows

    func showSettings() {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        settings.startAtLogin = LoginItem.state
        noteShortcuts()
        if controller.snapshot().visible { _ = controller.invoke("hide") }
        window.show()
        Task { await refreshDevices() }
    }

    private func makeSettingsWindow() -> SettingsWindowController {
        let window = SettingsWindowController(panel: panelShortcut, send: sendShortcut)
        window.actions = self
        for recorder in [window.panelRecorder, window.sendRecorder] {
            recorder.onChange = { [weak self] refusal in
                guard let self else { return }
                self.settingsMessage = refusal ?? ""
                self.noteShortcuts()
                Task { await self.refreshDevices() }
            }
        }
        return window
    }

    /// The shortcuts as the settings show them: their keys, and whether each is bound.
    func noteShortcuts() {
        settings.noteShortcuts(panel: panelShortcut, send: sendShortcut)
    }

    func showPairing() {
        let window = pairingWindow ?? PairingWindowController()
        window.actions = self
        pairingWindow = window
        if controller.snapshot().visible { _ = controller.invoke("hide") }
        window.render(pairing.status, message: pairing.message, thisDevice: Self.thisDevice)
        window.show()
        Task { await pairing.refresh() }
    }

    static var thisDevice: String { PairingConfiguration.defaultName }

    private func pairingChanged() {
        pairingWindow?.render(pairing.status, message: pairing.message, thisDevice: Self.thisDevice)
        if pairing.status.state == .paired {
            pairingWindow?.clearCode()
            // The panel learns the new device now, not when it next opens and refreshes.
            controller.reloadLists()
            Task { await refreshDevices() }
        }
    }

    /// Applies one setting. Returns the sentence to show when it was refused.
    func set(_ key: MacSettings.Key, _ value: String) async -> ActionRefusal? {
        var refusal: String?
        switch key {
        case .startAtLogin:
            refusal = LoginItem.set(MacSettings.on(value))
            settings.startAtLogin = LoginItem.state
        case .panelShortcut, .sendShortcut:
            let binding = key == .panelShortcut ? panelShortcut : sendShortcut
            if ["none", "off", ""].contains(value.lowercased()) { _ = binding.rebind(nil) }
            else if let shortcut = binding.parse(value) {
                if let why = binding.rebind(shortcut) { refusal = ShortcutBinding.sentence(why, shortcut) }
            } else { refusal = "Write the shortcut as, for example, ctrl+option+cmd+space." }
            noteShortcuts()
        default:
            var updated = settings
            refusal = await updated.store(key, value, in: runtime.store)
            settings = updated
        }
        settingsMessage = refusal ?? ""
        await refreshDevices()
        return refusal.map(ActionRefusal.init)
    }

    func removeDevice(_ deviceID: String) async -> ActionRefusal? {
        let response = await runtime.handle(ControlRequest("unpair", arguments: ["device": deviceID]))
        await refreshDevices()
        guard response.ok else { return ActionRefusal(message: response.error ?? "Could not remove the device.") }
        message = "Removed."
        return nil
    }

    // MARK: What happened elsewhere

    private func historyChanged(_ change: HistoryWatcher.Change) {
        guard !stopped else { return }
        switch change {
        case .arrived(let row):
            let from = name(of: row.deviceID)
            let fileName = row.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? row.targetName
            notifier.arrived(kind: row.kind, text: row.text, fileName: fileName, path: row.path, deviceID: row.deviceID, id: row.id, from: from)
            controller.showArrived()
            // Received text goes on the clipboard only when the person turned that on.
            if row.kind == "text" && settings.receivedTextToClipboard {
                Task { _ = await self.copy(rowID: row.deviceID + "/" + row.id) }
            }
        case .sent(let row):
            message = "Sent to \(name(of: row.deviceID))."
            controller.showSendLine(message, failed: false)
            controller.showArrived()
        case .notSent(let row, let reason):
            let to = name(of: row.deviceID)
            var body = reason ?? (row.status == "unconfirmed" ? "\(to) may not have it." : "Not sent.")
            // After the other device removed this one, it still lists it here.
            if body.hasPrefix("Cannot reach") { body += " If \(to) removed this Mac, remove \(to) in Catflap's settings." }
            sendFailed(title: "Not sent to \(to)", body: body, retry: (row.deviceID, row.id))
        }
        Task { await refreshDevices() }
    }

    private func perform(_ action: Notifier.Action) {
        Task {
            switch action {
            case .copy(let device, let id): _ = await copy(rowID: device + "/" + id)
            case .reveal(let path): NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            case .retry(let device, let id): _ = await retry(deviceID: device, id: id)
            }
        }
    }

    // MARK: Helpers

    /// A history row's panel id is `device/id`.
    static func split(_ rowID: String) -> (String, String) {
        guard let slash = rowID.firstIndex(of: "/") else { return ("", rowID) }
        return (String(rowID[..<slash]), String(rowID[rowID.index(after: slash)...]))
    }

    static func sentence(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Not sent."
    }
}

extension PanelActions: SettingsWindowActions {
    func settingsSet(_ key: MacSettings.Key, _ value: String) {
        Task { _ = await set(key, value) }
    }

    func settingsChooseInbox() {
        picker.pickFolder { [weak self] urls in
            guard let self, let folder = urls.first else { return }
            Task { _ = await self.set(.inbox, folder.path) }
        }
    }

    func settingsRemove(deviceID: String, name: String) {
        Task { _ = await removeDevice(deviceID) }
    }

    func settingsPair() { showPairing() }
}

extension PanelActions: PairingWindowActions {
    func pairingStart() { pairing.start() }
    func pairingJoin(_ code: String) { pairing.join(code) }
    func pairingCopyCode() { _ = pairing.copyCode() }
    func pairingConfirm() { pairing.confirm() }
    func pairingDecline() { pairing.decline() }
}
#endif
