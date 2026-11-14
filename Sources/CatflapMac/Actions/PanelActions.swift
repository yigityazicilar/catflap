#if os(macOS)
import AppKit
import CatflapCore

/// A send or another action that did not happen, with the sentence to show.
struct ActionRefusal: Error, Sendable {
    let message: String
}

/// Everything the panel does beyond appearing and leaving: sending typed text, attached files
/// and list rows; Copy, Delete, Retry and Reveal; Attach through the open panel, pasted files
/// and the Services menu; the send-clipboard shortcut; notifications on arrival and on a
/// failed send; pairing, removing a device, and settings.
///
/// The panel (PanelController) owns the window, its states and its lists. This object answers
/// the panel's send hook and the view actions the panel leaves to it, and adds its own
/// `ui invoke` actions and `ui state` fields (see ActionCommands.swift).
@MainActor
final class PanelActions {
    let runtime: AgentRuntime
    let controller: PanelController
    let notifier = Notifier()
    let history: HistoryWatcher
    let picker = FilePicker()
    let services = ServiceProvider()
    let pairing: PairingFlow
    let panelShortcut = ShortcutBinding(existing: ShortcutBinding.panelName, default: ShortcutBinding.panelDefault)
    private(set) var sendShortcut: ShortcutBinding?
    private(set) var settings = MacSettings()
    private(set) var settingsWindow: SettingsWindowController?
    private(set) var pairingWindow: PairingWindowController?
    private(set) var settingsMessage = ""
    /// The last sentence an action ended with: a refusal, or what happened.
    private(set) var message = ""
    /// Whether the panel's own controls reach this object (see PanelWiring.swift).
    private(set) var wired = false
    /// The panel's Don't keep switch, as last set.
    var dontKeep = false
    /// The device chosen in the panel, when the person chose one.
    var chosenDevice: String?
    private let pollClipboard: @MainActor () async -> Void
    private var wiring: PanelWiring?
    private var lastPanelSend: Task<Result<[TransferRecord], ActionRefusal>, Never>?
    private var deviceNames: [String: String] = [:]
    private var stopped = false

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
        controller.sendHandler = { [weak self] payload, device, keep in
            self?.panelSend(payload, to: device.id, keep: keep)
        }
        wiring = PanelWiring(actions: self)
        wired = wiring?.attach() ?? false
        sendShortcut = ShortcutBinding(name: ShortcutBinding.sendClipboardName, default: ShortcutBinding.sendClipboardDefault) { [weak self] in
            guard let self else { return }
            Task { _ = await self.sendLatest() }
        }
        notifier.perform = { [weak self] action in self?.perform(action) }
        services.receive = { [weak self] urls in self?.attachFromElsewhere(urls) }
        NSApplication.shared.servicesProvider = services
        pairing.onChange = { [weak self] in self?.pairingChanged() }
        history.onChange = { [weak self] change in self?.historyChanged(change) }
        await history.start()
        await registerCommands()
    }

    func stop() {
        stopped = true
        history.stop()
        pairing.stop()
        picker.cancel()
        sendShortcut?.stop()
        settingsWindow?.close()
        pairingWindow?.close()
        wiring?.detach()
        controller.sendHandler = nil
        NSApplication.shared.servicesProvider = nil
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
    private func panelSend(_ payload: PanelPayload, to deviceID: String, keep: Bool) {
        let task = Task { [weak self] () -> Result<[TransferRecord], ActionRefusal> in
            guard let self else { return .failure(ActionRefusal(message: "Catflap is stopping.")) }
            let outcome = await self.send(payload, to: deviceID, keep: keep)
            switch outcome {
            case .success:
                // What was sent leaves the field, the attachment row and the selection.
                switch payload {
                case .text: self.controller.viewFilterChanged("")
                case .files: self.controller.viewRemoveAttachments()
                case .row: self.controller.viewSelectRow(nil)
                }
            case .failure(let refusal):
                self.notifier.problem(title: "Not sent to \(self.name(of: deviceID))", body: refusal.message)
            }
            return outcome
        }
        lastPanelSend = task
    }

    /// The send the panel started most recently, for `ui invoke send`.
    func takePanelSend() -> Task<Result<[TransferRecord], ActionRefusal>, Never>? {
        defer { lastPanelSend = nil }
        return lastPanelSend
    }

    /// Starts sending `payload`; returns the rows at once, while they are `sending`. How each
    /// ends is seen by the history watcher, whoever started it.
    func send(_ payload: PanelPayload, to deviceID: String, keep: Bool) async -> Result<[TransferRecord], ActionRefusal> {
        guard let transfers = await runtime.service(TransferService.self) else {
            return .failure(ActionRefusal(message: "Sending is not available."))
        }
        var rows: [TransferRecord] = []
        do {
            switch payload {
            case .text(let text):
                rows.append(try await transfers.start(deviceID: deviceID, payload: .text(text), keep: keep))
            case .files(let urls):
                for url in urls { rows.append(try await transfers.start(deviceID: deviceID, payload: .file(url), keep: keep)) }
            case .row(let row):
                switch row.kind {
                case .text, .url, .image, .files:
                    guard let clipboard = await runtime.service(ClipboardService.self) else {
                        return .failure(ActionRefusal(message: "Clipboard history is not available."))
                    }
                    rows.append(try await clipboard.send(id: row.id, deviceID: deviceID, keep: keep))
                case .sent, .received:
                    let (device, id) = Self.split(row.id)
                    guard let record = try await transfers.history.record(deviceID: device, id: id) else {
                        return .failure(ActionRefusal(message: "That item is no longer in history."))
                    }
                    if record.kind == "text" {
                        guard let text = try await transfers.copyText(deviceID: device, id: id) else {
                            return .failure(ActionRefusal(message: "That text was not kept, so it cannot be sent again."))
                        }
                        rows.append(try await transfers.start(deviceID: deviceID, payload: .text(text), keep: keep))
                    } else if let path = record.path, FileManager.default.fileExists(atPath: path) {
                        rows.append(try await transfers.start(deviceID: deviceID, payload: .file(URL(fileURLWithPath: path)), keep: keep))
                    } else {
                        return .failure(ActionRefusal(message: "That file is not kept on this Mac, so it cannot be sent again."))
                    }
                }
            }
        } catch {
            return .failure(ActionRefusal(message: Self.sentence(error)))
        }
        message = "Sending to \(name(of: deviceID))\u{2026}"
        history.refresh()
        return .success(rows)
    }

    /// The send-clipboard shortcut: the newest copy, if clipboard history recorded it, to the
    /// most recently used device. Success is quiet; a refusal says why in a notification.
    func sendLatest() async -> Result<[TransferRecord], ActionRefusal> {
        // A copy made less than one poll before the shortcut is seen first.
        await pollClipboard()
        let response = await runtime.handle(ControlRequest("clip.send", arguments: ["latest": "true"]))
        guard response.ok, let row = try? response.decode(TransferRecord.self) else {
            let sentence = response.error ?? "Not sent."
            message = sentence
            notifier.problem(title: "Clipboard not sent", body: sentence)
            return .failure(ActionRefusal(message: sentence))
        }
        message = "Sending to \(name(of: row.deviceID))\u{2026}"
        history.refresh()
        return .success([row])
    }

    func retry(deviceID: String, id: String) async -> Result<[TransferRecord], ActionRefusal> {
        guard let transfers = await runtime.service(TransferService.self) else {
            return .failure(ActionRefusal(message: "Sending is not available."))
        }
        do {
            let row = try await transfers.retry(deviceID: deviceID, id: id)
            history.refresh()
            return .success([row])
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
                    PasteboardWriter.write(text: text)
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
    func pasteFiles() -> Bool {
        let urls = PasteboardWriter.files()
        guard !urls.isEmpty else { return false }
        attach(urls)
        return true
    }

    func ensureFocused() {
        if controller.snapshot().mode != PanelMode.focused.rawValue { _ = controller.invoke("toggle") }
    }

    /// What the panel's field holds.
    var fieldText: String { wiring?.fieldText ?? "" }

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
        settings.panelShortcut = panelShortcut.keys
        settings.sendShortcut = sendShortcut?.keys ?? ""
        if controller.snapshot().visible { _ = controller.invoke("hide") }
        window.show()
        Task { await refreshDevices() }
    }

    private func makeSettingsWindow() -> SettingsWindowController {
        let send = sendShortcut ?? ShortcutBinding(existing: ShortcutBinding.sendClipboardName, default: ShortcutBinding.sendClipboardDefault)
        let window = SettingsWindowController(panel: panelShortcut, send: send)
        window.actions = self
        for recorder in [window.panelRecorder, window.sendRecorder] {
            recorder.onChange = { [weak self] refusal in
                guard let self else { return }
                self.settingsMessage = refusal ?? ""
                self.settings.panelShortcut = self.panelShortcut.keys
                self.settings.sendShortcut = self.sendShortcut?.keys ?? ""
                Task { await self.refreshDevices() }
            }
        }
        return window
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
            guard let binding = key == .panelShortcut ? panelShortcut : sendShortcut else {
                return ActionRefusal(message: "That shortcut is not available.")
            }
            if ["none", "off", ""].contains(value.lowercased()) { _ = binding.rebind(nil) }
            else if let shortcut = binding.parse(value) {
                if !binding.rebind(shortcut) { refusal = "macOS or another app already uses \(ShortcutBinding.describe(shortcut)). Choose another." }
            } else { refusal = "Write the shortcut as, for example, ctrl+option+space." }
            settings.panelShortcut = panelShortcut.keys
            settings.sendShortcut = sendShortcut?.keys ?? ""
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
            // Received text goes on the clipboard only when the person turned that on.
            if row.kind == "text" && settings.receivedTextToClipboard {
                Task { _ = await self.copy(rowID: row.deviceID + "/" + row.id) }
            }
        case .sent(let row):
            message = "Sent to \(name(of: row.deviceID))."
        case .notSent(let row, let reason):
            let to = name(of: row.deviceID)
            var body = reason ?? (row.status == "unconfirmed" ? "\(to) may not have it." : "Not sent.")
            // After the other device removed this one, it still lists it here.
            if body.hasPrefix("Cannot reach") { body += " If \(to) removed this Mac, remove \(to) in Catflap's settings." }
            message = body
            notifier.problem(title: "Not sent to \(to)", body: body, retry: (row.deviceID, row.id))
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
