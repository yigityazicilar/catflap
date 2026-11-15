import CGtk
import CatflapCore
import Foundation

/// What a `ui invoke` action reports back.
struct ActionResult: Codable, Sendable {
    /// How one request of a send went: `started`, `refused` (with the agent's sentence) or
    /// `unstarted`. `file` is the file's name for a file.
    struct Outcome: Codable, Sendable {
        var file: String?
        var status: SendBatch.Status
        var error: String?
    }
    var action: String
    var transfers: [TransferRecord] = []
    /// One entry per request of a send, in order.
    var outcomes: [Outcome] = []
    var attachments: [String] = []
    var copied: String?
    var message: String = ""
    var state: UIState
}

/// The `ui invoke` actions this task adds, each doing what the matching control in the panel
/// does. Optional arguments name what a person would have chosen on screen; without them the
/// action uses what the panel shows (the field, the selected row, the selected device).
///
/// - `send-text [text] [device] [keep]`: the text in the field, or `text` put there first.
/// - `send-clip [id] [device] [keep]`: a clipboard row: `id`, else the selected row, else the newest.
/// - `send [device] [keep]`: what the send button names.
/// - `send-latest`: what the send-clipboard shortcut does.
/// - `attach [files]`: `files` (newline-separated paths or file URIs) are attached and the panel
///   opens focused; without them the system file picker opens.
/// - `copy [id]`, `delete [id]`: a row by id (`<device>/<id>` for history), else the selected
///   row, else (copy) the newest history row.
/// - `retry id device`, `remove device`.
/// - `dont-keep on|off`, `pair`, `pair-start`, `pair-join [code]`, `pair-copy-code`,
///   `pair-confirm`, `pair-decline`, `settings`, `set key value`.
enum PanelActionArguments {
    static func files(_ arguments: [String: String]) -> [String] {
        let text = [arguments["files"], arguments["file"]].compactMap { $0 }.joined(separator: "\n")
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    static func invoke(_ action: String, _ arguments: [String: String], on panel: PanelController) async -> ControlResponse {
        switch action {
        case "send-text", "send-clip", "send":
            return await send(action, arguments, panel)
        case "send-latest":
            let outcome = await withCheckedContinuation { (done: CheckedContinuation<Result<[TransferRecord], SendRefusal>, Never>) in
                GLib.idle { panel.sender.sendLatestCopy { done.resume(returning: $0) } }
            }
            return await respond(action, outcome.map { rows in
                SendBatch(outcomes: rows.map { SendBatch.Outcome(file: nil, status: .started, row: $0) }, refusal: nil)
            }, panel)
        case "attach":
            let files = files(arguments)
            let missing = files.map { $0.hasPrefix("file://") ? URL(string: $0)?.path ?? $0 : $0 }
                .first { !FileManager.default.fileExists(atPath: $0) }
            if let missing { return ControlResponse(failure: "No file at \(missing).") }
            return await result(action, panel) {
                panel.ensureFocused()
                if files.isEmpty { panel.extras.pickFiles() } else { panel.extras.attach(files) }
            }
        case "copy":
            // The agent's history as it is now: the panel's list may not have caught up yet.
            if let records = await PanelController.request([TransferRecord].self, "history", panel.runtime) {
                await panel.loop.perform { panel.records = records }
            }
            guard let row = await panel.loop.perform({ row(arguments["id"], panel, newestHistory: true) }) else {
                return ControlResponse(failure: "Nothing to copy.")
            }
            let copied = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                GLib.idle { panel.sender.copy(row) { done.resume(returning: $0) } }
            }
            guard copied else { return ControlResponse(failure: await panel.loop.perform { panel.extras.message }) }
            return await result(action, panel, copied: row.id) {}
        case "delete":
            guard let row = await panel.loop.perform({ row(arguments["id"], panel, newestHistory: false) }) else {
                return ControlResponse(failure: "Select a row to delete.")
            }
            return await result(action, panel) { panel.sender.delete(row) }
        case "retry":
            guard let id = arguments["id"], let device = arguments["device"] ?? arguments["device_id"] else {
                return ControlResponse(failure: "Name the transfer id and its device.", exitCode: 64)
            }
            return await result(action, panel) { panel.sender.retry(deviceID: device, id: id) }
        case "remove":
            let selected = await panel.loop.perform { panel.view.selectedDevice }
            let device: PanelDevice
            switch await target(arguments["device"], runtime: panel.runtime, selected: selected, missing: "No paired device has that id or name.") {
            case .success(let found): device = found
            case .failure(let refusal): return await refuse(refusal, panel)
            }
            let outcome = await withCheckedContinuation { (done: CheckedContinuation<Result<Void, SendRefusal>, Never>) in
                GLib.idle { panel.sender.remove(deviceID: device.id, name: device.name) { done.resume(returning: $0) } }
            }
            if case .failure(let refusal) = outcome { return ControlResponse(failure: refusal.message) }
            return await result(action, panel) {}
        case "dont-keep":
            let on = ["on", "true", "1"].contains(arguments["value"] ?? arguments["state"] ?? "on")
            return await result(action, panel) { panel.extras.setDontKeep(on) }
        case "pair", "settings":
            return await result(action, panel) {
                panel.ensureFocused()
                panel.extras.show(page: action == "pair" ? "pair" : "settings")
            }
        case "pair-start", "pair-join", "pair-confirm", "pair-decline":
            let command = "pair." + action.dropFirst(5)
            var request: [String: String] = [:]
            if action == "pair-join", let code = arguments["code"] { request["code"] = code }
            await panel.loop.perform {
                panel.ensureFocused()
                if panel.extras.page != "pair" { panel.extras.show(page: "pair") }
            }
            if action == "pair-join" && request.isEmpty {
                await panel.loop.perform { panel.pairing.join(nil) }
                return await result(action, panel) {}
            }
            if let refusal = await panel.pairing.perform(command, request) { return ControlResponse(failure: refusal) }
            return await result(action, panel) {}
        case "pair-copy-code":
            let copied = await panel.loop.perform { panel.pairing.copyCode() }
            return copied ? await result(action, panel) {} : ControlResponse(failure: "This device is not showing a code.")
        case "set":
            guard let name = arguments["key"], let key = PanelSettings.Key(rawValue: name.replacingOccurrences(of: "-", with: "_")) else {
                return ControlResponse(failure: "Unknown setting. Use one of: \(PanelSettings.Key.allCases.map(\.rawValue).joined(separator: ", ")).", exitCode: 64)
            }
            let value = arguments["value"] ?? ""
            let refusal = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
                GLib.idle { panel.settingsPage.set(key, value) { done.resume(returning: $0) } }
            }
            if let refusal { return ControlResponse(failure: refusal) }
            return await result(action, panel) {}
        default:
            return ControlResponse(error: .unsupported, exitCode: 64)
        }
    }

    // MARK: Sending

    private static func send(_ action: String, _ arguments: [String: String], _ panel: PanelController) async -> ControlResponse {
        var arguments = arguments
        if action == "send-clip", arguments["id"] == nil {
            // The newest item as the agent has it now, unless a clipboard row is selected; the
            // panel's own list may not have caught up with a copy made a moment ago.
            let selected = await panel.loop.perform { panel.view.selectedRow().flatMap { $0.source == .clipboard ? $0.id : nil } }
            let newest = await PanelController.request([ClipboardItem].self, "clip.list", panel.runtime)?.first
            if let id = selected ?? newest?.id { arguments["id"] = id }
            if let newest, !(await panel.loop.perform { panel.items.contains { $0.id == newest.id } }) {
                await panel.loop.perform { panel.items.insert(newest, at: 0) }
            }
        }
        let request = arguments
        let selected = await panel.loop.perform { panel.view.selectedDevice }
        let device: PanelDevice
        switch await target(request["device"] ?? request["device_id"], runtime: panel.runtime, selected: selected,
                            missing: "No paired device. Pair one first.") {
        case .success(let found): device = found
        case .failure(let refusal): return await refuse(refusal, panel)
        }
        let outcome = await withCheckedContinuation { (done: CheckedContinuation<Result<SendBatch, SendRefusal>, Never>) in
            GLib.idle {
                let keep = request["keep"].map { $0 != "false" } ?? !panel.extras.dontKeep
                let payload: PanelPayload?
                switch action {
                case "send-text":
                    if let text = request["text"] { panel.extras.setField(text) }
                    let text = panel.view.fieldText
                    payload = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(text)
                case "send-clip":
                    payload = clipboardRow(request["id"], panel).map(PanelPayload.row)
                default:
                    payload = panel.view.currentPayload
                }
                guard let payload else {
                    done.resume(returning: .failure(SendRefusal(message: "Nothing to send.")))
                    return
                }
                let requests: [ControlRequest]
                switch payload {
                case .text(let text):
                    requests = [ControlRequest("send", arguments: ["device_id": device.id, "text": text, "keep": keep ? "true" : "false"])]
                case .files:
                    requests = panel.extras.attachedPaths.map {
                        ControlRequest("send", arguments: ["device_id": device.id, "file": $0, "keep": keep ? "true" : "false"])
                    }
                case .row(let row):
                    guard let request = clipboardRequest(row, device, keep) else {
                        // A history row goes through the panel's own path.
                        panel.sender.send(payload, to: device, keep: keep)
                        done.resume(returning: .success(SendBatch(outcomes: [], refusal: nil)))
                        return
                    }
                    requests = [request]
                }
                panel.sender.start(requests, to: device, clearing: payload) { done.resume(returning: .success($0)) }
            }
        }
        return await respond(action, outcome, panel)
    }

    private static func clipboardRequest(_ row: PanelRow, _ device: PanelDevice, _ keep: Bool) -> ControlRequest? {
        guard row.source == .clipboard else { return nil }
        return ControlRequest("clip.send", arguments: ["id": row.id, "device_id": device.id, "keep": keep ? "true" : "false"])
    }

    /// A send that started everything answers ok. One that did not answers with the sentence
    /// that says which files did not go; when several were asked for, the reply still carries
    /// the sends that started and how each request went.
    private static func respond(_ action: String, _ outcome: Result<SendBatch, SendRefusal>, _ panel: PanelController) async -> ControlResponse {
        switch outcome {
        case .failure(let refusal): return ControlResponse(failure: refusal.message)
        case .success(let batch):
            let outcomes = batch.outcomes.map { ActionResult.Outcome(file: $0.file == nil ? nil : $0.name, status: $0.status, error: $0.error) }
            guard let refusal = batch.refusal else { return await result(action, panel, transfers: batch.started, outcomes: outcomes) {} }
            if batch.outcomes.count <= 1 { return ControlResponse(failure: refusal) }
            var response = await result(action, panel, transfers: batch.started, outcomes: outcomes) {}
            response.ok = false
            response.error = refusal
            response.exitCode = 1
            return response
        }
    }

    /// Shows a refusal that comes before anything is sent in the panel's message line too.
    private static func refuse(_ refusal: SendRefusal, _ panel: PanelController) async -> ControlResponse {
        if refusal.message == unreadableDevices { await panel.loop.perform { panel.extras.setMessage(refusal.message) } }
        return ControlResponse(failure: refusal.message)
    }

    // MARK: Devices

    /// What a send or remove answers when the agent's list of paired devices cannot be read.
    static let unreadableDevices = "Catflap could not read your paired devices. Try again."

    /// The paired devices as the agent lists them now, most recently used first; nil when the
    /// agent could not be asked or its answer could not be read.
    static func pairedDevices(_ runtime: AgentRuntime) async -> [PanelDevice]? {
        await PanelController.request([DeviceSummary].self, "devices", runtime)?.map { PanelDevice(id: $0.id, name: $0.name) }
    }

    /// The device a `ui invoke` action goes to, from the agent's own list as it is now: the
    /// panel's copy follows the store a moment later, so a send right after pairing would find
    /// no device in it, and a device removed since could still be in it. When the agent's list
    /// cannot be read, nothing goes anywhere. `missing` is the refusal when no device matches.
    static func target(_ text: String?, runtime: AgentRuntime, selected: PanelDevice?, missing: String) async -> Result<PanelDevice, SendRefusal> {
        guard let paired = await pairedDevices(runtime) else { return .failure(SendRefusal(message: unreadableDevices)) }
        guard let device = resolve(text, paired: paired, selected: selected) else { return .failure(SendRefusal(message: missing)) }
        return .success(device)
    }

    /// By id, or by a name only one device has; with none named, the device selected in the
    /// panel if it is still paired, else the most recently used one.
    static func resolve(_ text: String?, paired devices: [PanelDevice], selected: PanelDevice?) -> PanelDevice? {
        guard let text else {
            if let selected, devices.contains(selected) { return selected }
            return devices.first
        }
        if let device = devices.first(where: { $0.id == text }) { return device }
        let named = devices.filter { $0.name == text }
        return named.count == 1 ? named[0] : nil
    }

    // MARK: Rows, on the GTK thread

    private static func clipboardRow(_ id: String?, _ panel: PanelController) -> PanelRow? {
        if let id { return PanelText.rows(clipboard: panel.items.filter { $0.id == id }).first }
        if let selected = panel.view.selectedRow(), selected.source == .clipboard { return selected }
        return PanelText.rows(clipboard: Array(panel.items.prefix(1))).first
    }

    private static func row(_ id: String?, _ panel: PanelController, newestHistory: Bool) -> PanelRow? {
        let clipboard = PanelText.rows(clipboard: panel.items)
        let history = PanelText.rows(history: panel.records.map(Self.history), devices: [])
        if let id { return (clipboard + history).first { $0.id == id } }
        if let selected = panel.view.selectedRow() { return selected }
        return newestHistory ? history.first : nil
    }

    static func history(_ record: TransferRecord) -> HistoryRecord {
        HistoryRecord(id: record.id, deviceID: record.deviceID, timestamp: record.timestamp, direction: record.direction,
                      kind: record.kind, size: record.size, status: record.status, text: record.text, path: record.path)
    }

    /// Runs `body` on the GTK thread, then answers with what the panel shows.
    private static func result(_ action: String, _ panel: PanelController, transfers: [TransferRecord] = [], outcomes: [ActionResult.Outcome] = [],
                               copied: String? = nil, _ body: @escaping @Sendable () -> Void) async -> ControlResponse {
        let value = await panel.loop.perform {
            body()
            return ActionResult(action: action, transfers: transfers, outcomes: outcomes, attachments: panel.extras.attachmentNames, copied: copied,
                                message: panel.extras.message, state: panel.state())
        }
        return (try? ControlResponse(value: value)) ?? ControlResponse(error: .storage)
    }
}
