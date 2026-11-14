#if os(macOS)
import AppKit
import CatflapCore

/// The pairing in progress as `ui state` shows it. The code itself is never included.
struct MacPairingState: Codable, Sendable, Equatable {
    var state: String
    var role: String?
    var digits: String?
    var peerName: String?
    var hasCode: Bool
    var error: String?
    enum CodingKeys: String, CodingKey {
        case state, role, digits, error
        case peerName = "peer_name", hasCode = "has_code"
    }
}

/// The fields `ui state` adds on macOS for this task's actions, beside MacUIState's.
struct MacActionState: Codable, Sendable {
    var wired: Bool
    var dontKeep: Bool
    var paused: Bool
    var pickerOpen: Bool
    var settingsOpen: Bool
    var pairingOpen: Bool
    var pairing: MacPairingState
    var settings: MacSettings
    var sendShortcut: String
    var sendShortcutKeys: String
    var panelShortcutKeys: String
    var notifications: [Notifier.Record]
    var notificationDelivery: String
    var lastMessage: String
    enum CodingKeys: String, CodingKey {
        case wired, paused, pairing, settings, notifications
        case dontKeep = "dont_keep", pickerOpen = "picker_open", settingsOpen = "settings_open", pairingOpen = "pairing_open"
        case sendShortcut = "send_shortcut", sendShortcutKeys = "send_shortcut_keys", panelShortcutKeys = "panel_shortcut_keys"
        case notificationDelivery = "notification_delivery", lastMessage = "last_message"
    }
}

/// `ui state` on macOS: the panel's fields and this task's, in one object.
struct MacStateReport: Encodable, Sendable {
    let ui: MacUIState
    let actions: MacActionState
    func encode(to encoder: any Encoder) throws {
        try ui.encode(to: encoder)
        try actions.encode(to: encoder)
    }
}

/// What a `ui invoke` action of this task answers: the rows it started, what it copied, the
/// sentence it ended with, and the state after it.
struct MacActionResult: Encodable, Sendable {
    let action: String
    let transfers: [TransferRecord]
    let copied: String?
    let message: String
    let state: MacStateReport
}

/// The `ui invoke` actions, each doing what the matching control does. Optional arguments
/// name what a person would have chosen on screen; without them the action uses what the
/// panel shows.
///
/// - `type text`: puts `text` in the field.
/// - `send-text [text] [device] [keep]`: sends `text`, or the text in the field.
/// - `send-clip [id] [device] [keep]`: sends a clipboard row, by default the newest.
/// - `send`: presses the send button (the selected row, else the attachments, else the text).
/// - `send-latest`: what the send-clipboard shortcut does.
/// - `attach [files]`: attaches `files` (newline-separated paths or file URLs) to a focused
///   panel; without them the open panel appears. `attach-cancel` closes it.
/// - `paste`: ⌘V in the panel (files on the clipboard are attached).
/// - `simulate-drop files`: files dropped on the panel. `service files`: the Services menu.
/// - `copy [id]`, `delete id`, `reveal id`, `retry id device`: a list row by id
///   (`<device>/<id>` for history); copy defaults to the newest history row.
/// - `dont-keep on|off`, `pause on|off`.
/// - `pair`, `pair-start`, `pair-join code`, `pair-copy-code`, `pair-confirm`, `pair-decline`,
///   `pair-close`; `settings`, `settings-close`, `set key value`, `remove device`.
/// - `clear-notifications`.
///
/// Any other action goes to the panel's own (`toggle`, `hide`, `simulate-*`).
extension PanelActions {
    func registerCommands() async {
        await runtime.register("ui.invoke") { [weak self] request in
            guard let self else { return ControlResponse(error: .unsupported, exitCode: 64) }
            return await self.invoke(request.arguments)
        }
        await runtime.register("ui.state") { [weak self] _ in
            guard let self else { return ControlResponse(error: .unsupported, exitCode: 64) }
            return try ControlResponse(value: await self.report())
        }
    }

    func report() async -> MacStateReport {
        let paused = await runtime.service(ClipboardHistory.self)?.isPaused() ?? false
        let status = pairing.status
        var current = settings
        current.startAtLogin = LoginItem.state
        current.panelShortcut = panelShortcut.keys
        current.sendShortcut = sendShortcut?.keys ?? ""
        let state = MacActionState(
            wired: wired, dontKeep: dontKeep, paused: paused, pickerOpen: picker.isOpen,
            settingsOpen: settingsWindow?.isOpen ?? false, pairingOpen: pairingWindow?.isOpen ?? false,
            pairing: MacPairingState(state: status.state.rawValue, role: status.role?.rawValue, digits: status.digits,
                                     peerName: status.peerName, hasCode: status.code != nil, error: status.error ?? pairing.message),
            settings: current, sendShortcut: sendShortcut?.state ?? "unavailable", sendShortcutKeys: sendShortcut?.keys ?? "",
            panelShortcutKeys: panelShortcut.keys, notifications: notifier.shown,
            notificationDelivery: Notifier.canDeliver ? "notification_center" : "recorded_only", lastMessage: message)
        return MacStateReport(ui: controller.snapshot(), actions: state)
    }

    private func answer(_ action: String, transfers: [TransferRecord] = [], copied: String? = nil, message text: String? = nil) async -> ControlResponse {
        let value = MacActionResult(action: action, transfers: transfers, copied: copied, message: text ?? message, state: await report())
        return (try? ControlResponse(value: value)) ?? ControlResponse(error: .storage)
    }

    private func refuse(_ refusal: ActionRefusal) -> ControlResponse { ControlResponse(failure: refusal.message) }

    private func answer(_ action: String, _ outcome: Result<[TransferRecord], ActionRefusal>) async -> ControlResponse {
        switch outcome {
        case .success(let rows): return await answer(action, transfers: rows)
        case .failure(let refusal): return refuse(refusal)
        }
    }

    static func files(_ arguments: [String: String]) -> [URL] {
        let text = [arguments["files"], arguments["file"]].compactMap { $0 }.joined(separator: "\n")
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }.map { line in
            line.hasPrefix("file://") ? (URL(string: line) ?? URL(fileURLWithPath: line)) : URL(fileURLWithPath: line)
        }
    }

    func invoke(_ arguments: [String: String]) async -> ControlResponse {
        let action = arguments["action"] ?? ""
        func keep() -> Bool { arguments["keep"].map { $0 != "false" } ?? !dontKeep }
        switch action {
        case "type":
            ensureFocused()
            controller.viewFilterChanged(arguments["text"] ?? "")
            return await answer(action)

        case "send-text":
            let text = arguments["text"] ?? fieldText
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return refuse(ActionRefusal(message: "Type something to send.")) }
            guard let device = await resolveDevice(arguments["device"] ?? arguments["device_id"]) else {
                return refuse(ActionRefusal(message: "No paired device. Pair one first."))
            }
            let outcome = await send(.text(text), to: device.id, keep: keep())
            if case .success = outcome, arguments["text"] == nil { controller.viewFilterChanged("") }
            return await answer(action, outcome)

        case "send-clip":
            guard let clipboard = await runtime.service(ClipboardHistory.self) else { return refuse(ActionRefusal(message: "Clipboard history is not available.")) }
            let items = (try? await clipboard.items()) ?? []
            guard let item = arguments["id"].flatMap({ id in items.first { $0.id == id } }) ?? (arguments["id"] == nil ? items.first : nil) else {
                return refuse(ActionRefusal(message: arguments["id"] == nil ? "Clipboard history is empty." : "That clipboard item is gone."))
            }
            guard let device = await resolveDevice(arguments["device"] ?? arguments["device_id"]) else {
                return refuse(ActionRefusal(message: "No paired device. Pair one first."))
            }
            return await answer(action, await send(.row(PanelFeed.row(item)), to: device.id, keep: keep()))

        case "send":
            _ = takePanelSend()
            controller.viewSend()
            guard let task = takePanelSend() else { return refuse(ActionRefusal(message: controller.snapshot().sendLabel)) }
            return await answer(action, await task.value)

        case "send-latest":
            return await answer(action, await sendLatest())

        case "retry":
            guard let id = arguments["id"], let device = arguments["device"] ?? arguments["device_id"] else {
                return ControlResponse(failure: "Name the transfer id and its device.", exitCode: 64)
            }
            return await answer(action, await retry(deviceID: device, id: id))

        case "attach":
            let urls = Self.files(arguments)
            if let missing = urls.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                return refuse(ActionRefusal(message: "No file at \(missing.path)."))
            }
            if urls.isEmpty { openPicker() } else { attach(urls) }
            return await answer(action)

        case "attach-cancel":
            picker.cancel()
            return await answer(action)

        case "paste":
            guard pasteFiles() else { return refuse(ActionRefusal(message: "The clipboard holds no files.")) }
            return await answer(action)

        case "simulate-drop":
            let urls = Self.files(arguments)
            if !urls.isEmpty { controller.viewDrop(urls) }
            return await answer(action)

        case "service":
            let urls = Self.files(arguments)
            guard !urls.isEmpty else { return refuse(ActionRefusal(message: "Name the files.")) }
            attachFromElsewhere(urls)
            return await answer(action)

        case "copy":
            var id = arguments["id"]
            if id == nil, let newest = try? await TransferHistory(store: runtime.store).rows().first { id = newest.deviceID + "/" + newest.id }
            guard let id else { return refuse(ActionRefusal(message: "Nothing to copy.")) }
            if let refusal = await copy(rowID: id) { return refuse(refusal) }
            return await answer(action, copied: id)

        case "delete":
            guard let id = arguments["id"] else { return ControlResponse(failure: "Name the row to delete.", exitCode: 64) }
            if let refusal = await delete(rowID: id) { return refuse(refusal) }
            return await answer(action)

        case "reveal":
            guard let id = arguments["id"] else { return ControlResponse(failure: "Name the row to reveal.", exitCode: 64) }
            if let refusal = await reveal(rowID: id) { return refuse(refusal) }
            return await answer(action)

        case "dont-keep":
            setDontKeep(MacSettings.on(arguments["value"] ?? "on"))
            return await answer(action)

        case "pause":
            if let refusal = await setPaused(MacSettings.on(arguments["value"] ?? "on")) { return refuse(refusal) }
            return await answer(action)

        case "pair":
            showPairing()
            return await answer(action)

        case "pair-start", "pair-join", "pair-confirm", "pair-decline":
            if pairingWindow?.isOpen != true { showPairing() }
            switch action {
            case "pair-start": pairing.start()
            case "pair-join": pairing.join(arguments["code"] ?? "")
            case "pair-confirm": pairing.confirm()
            default: pairing.decline()
            }
            return await answer(action)

        case "pair-copy-code":
            guard pairing.copyCode() else { return refuse(ActionRefusal(message: "This device is not showing a code.")) }
            return await answer(action)

        case "pair-close":
            pairingWindow?.close()
            return await answer(action)

        case "settings":
            showSettings()
            return await answer(action)

        case "settings-close":
            settingsWindow?.close()
            return await answer(action)

        case "set":
            guard let name = arguments["key"], let key = MacSettings.Key(rawValue: name.replacingOccurrences(of: "-", with: "_")) else {
                return ControlResponse(failure: "Unknown setting. Use one of: \(MacSettings.Key.allCases.map(\.rawValue).joined(separator: ", ")).", exitCode: 64)
            }
            if let refusal = await set(key, arguments["value"] ?? "") { return refuse(refusal) }
            return await answer(action)

        case "remove":
            guard let device = await resolveDevice(arguments["device"] ?? arguments["device_id"] ?? "") else {
                return refuse(ActionRefusal(message: "No paired device has that id or name."))
            }
            if let refusal = await removeDevice(device.id) { return refuse(refusal) }
            return await answer(action)

        case "clear-notifications":
            notifier.clearRecords()
            return await answer(action)

        default:
            guard let state = controller.invoke(action) else { return ControlResponse(error: .unsupported, exitCode: 64) }
            return (try? ControlResponse(value: state)) ?? ControlResponse(error: .storage)
        }
    }
}
#endif
