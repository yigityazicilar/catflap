import CGtk
import CatflapCore
import Foundation

/// The panel's actions on the agent: send what Return or the send button names, copy, delete,
/// retry, remove a device, and send the newest copy for the send-clipboard shortcut. Every
/// send goes through the agent's own control commands, as the command line's do.
// Touched only on the GTK thread, like the panel itself.
final class Sender: @unchecked Sendable {
    private unowned let controller: PanelController
    private(set) var tasks: [Task<Void, Never>] = []

    init(controller: PanelController) { self.controller = controller }

    private var runtime: AgentRuntime { controller.runtime }

    private func track(_ task: Task<Void, Never>) {
        tasks.removeAll { $0.isCancelled }
        tasks.append(task)
    }

    // MARK: Sending, called on the GTK thread

    /// What Return or the send button chose. Files are the attached ones, by path.
    func send(_ payload: PanelPayload, to device: PanelDevice, keep: Bool) {
        let requests: [ControlRequest]
        switch payload {
        case .text(let text):
            requests = [ControlRequest("send", arguments: ["device_id": device.id, "text": text, "keep": keep ? "true" : "false"])]
        case .files:
            requests = controller.extras.attachedPaths.map {
                ControlRequest("send", arguments: ["device_id": device.id, "file": $0, "keep": keep ? "true" : "false"])
            }
        case .row(let row):
            guard let request = request(for: row, to: device, keep: keep) else {
                controller.extras.setMessage("This item was not kept, so it cannot be sent again.")
                return
            }
            requests = [request]
        }
        start(requests, to: device, clearing: payload)
    }

    private func request(for row: PanelRow, to device: PanelDevice, keep: Bool) -> ControlRequest? {
        let flag = keep ? "true" : "false"
        switch row.source {
        case .clipboard:
            return ControlRequest("clip.send", arguments: ["id": row.id, "device_id": device.id, "keep": flag])
        case .history:
            guard let record = controller.record(for: row) else { return nil }
            if let text = record.text { return ControlRequest("send", arguments: ["device_id": device.id, "text": text, "keep": flag]) }
            if let path = record.path { return ControlRequest("send", arguments: ["device_id": device.id, "file": path, "keep": flag]) }
            return nil
        }
    }

    /// Starts each send and follows it to its end. Answers, through `started`, with the rows
    /// that started or with the sentence that says why none did.
    @discardableResult
    func start(_ requests: [ControlRequest], to device: PanelDevice, clearing payload: PanelPayload? = nil,
               started: (@Sendable (Result<[TransferRecord], SendRefusal>) -> Void)? = nil) -> Bool {
        guard !requests.isEmpty else {
            started?(.failure(SendRefusal(message: "Nothing to send.")))
            return false
        }
        controller.extras.setMessage("Sending to \(device.name)…")
        controller.tray.set(.moving)
        let runtime = runtime, loop = controller.loop
        track(Task { [weak self] in
            var rows: [TransferRecord] = []
            var refusal: String?
            for request in requests {
                let response = await runtime.handle(request)
                if response.ok, let row = try? response.decode(TransferRecord.self) { rows.append(row) }
                else { refusal = response.error ?? "Not sent." }
            }
            let begun = rows
            let refused = refusal
            await loop.perform { [weak self] in
                guard let self else { return }
                for row in begun { controller.watcher.panelSent(deviceID: row.deviceID, id: row.id) }
                if let refusal = refused, begun.isEmpty {
                    controller.extras.setMessage(refusal)
                    controller.tray.set(.problem)
                } else if let payload {
                    // The send is under way: the field and the attachments are ready for the next one.
                    switch payload {
                    case .text: controller.extras.setField("")
                    case .files: controller.extras.clearAttachments()
                    case .row: controller.view.clearSelection()
                    }
                }
                controller.refresh()
            }
            if let refusal, begun.isEmpty { started?(.failure(SendRefusal(message: refusal))) } else { started?(.success(begun)) }
            guard !begun.isEmpty else { return }
            let finished = await Self.follow(begun, runtime: runtime)
            await loop.perform { [weak self] in self?.finished(finished, device: device) }
        })
        return true
    }

    /// Polls each started send until it is no longer `sending`.
    static func follow(_ rows: [TransferRecord], runtime: AgentRuntime) async -> [TransferRecord] {
        var result: [TransferRecord] = []
        for var row in rows {
            while row.status == "sending" && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let response = await runtime.handle(ControlRequest("send.status", arguments: ["device_id": row.deviceID, "id": row.id]))
                if response.ok, let next = try? response.decode(TransferRecord.self) { row = next } else { break }
            }
            result.append(row)
        }
        return result
    }

    private func finished(_ rows: [TransferRecord], device: PanelDevice) {
        controller.refresh()
        guard let failed = rows.first(where: { $0.status != "ok" }) else {
            controller.extras.setMessage(rows.count == 1 ? "Sent to \(device.name)." : "Sent \(rows.count) items to \(device.name).")
            controller.tray.set(.arrived)
            return
        }
        controller.tray.set(.problem)
        let reason = failed.error ?? (failed.status == "unconfirmed" ? "\(device.name) may not have it." : "Not sent.")
        // A device that removed this one still looks paired here and can only be reached as
        // "Cannot reach". Say so and offer to remove it on this side too.
        if reason.hasPrefix("Cannot reach") {
            controller.extras.setMessage(reason + " If \(device.name) removed this device, remove it here too.",
                                         retry: failed.canRetry ? (failed.deviceID, failed.id) : nil, remove: (device.id, device.name))
        } else {
            controller.extras.setMessage(reason, retry: failed.canRetry ? (failed.deviceID, failed.id) : nil)
        }
    }

    func retry(deviceID: String, id: String) {
        let name = controller.settingsPage.deviceName(deviceID) ?? "the other device"
        start([ControlRequest("send", arguments: ["device_id": deviceID, "retry": id])], to: PanelDevice(id: deviceID, name: name))
    }

    // MARK: Copy, delete, remove

    /// Puts the row's content on the clipboard. Text that was not kept goes with the
    /// password-manager marker, so clipboard history (this one and others) does not record it.
    func copy(_ row: PanelRow, done: (@Sendable (Bool) -> Void)? = nil) {
        switch row.source {
        case .clipboard:
            guard let item = controller.items.first(where: { $0.id == row.id }) else { done?(false); return }
            controller.clipboard.set(item)
            controller.extras.setMessage("Copied.")
            done?(true)
        case .history:
            guard let record = controller.record(for: row) else {
                done?(false); return
            }
            copy(record, done: done)
        }
    }

    func copy(_ record: TransferRecord, done: (@Sendable (Bool) -> Void)? = nil) {
        if let path = record.path, record.kind != "text" {
            controller.clipboard.set(files: [URL(fileURLWithPath: path).absoluteString])
            controller.extras.setMessage("Copied.")
            done?(true)
            return
        }
        let runtime = runtime, loop = controller.loop
        let deviceID = record.deviceID, id = record.id, keep = record.keep
        track(Task { [weak self] in
            let text = try? await runtime.service(TransferService.self)?.copyText(deviceID: deviceID, id: id)
            await loop.perform { [weak self] in
                guard let self else { return }
                guard let text else {
                    controller.extras.setMessage("This text was not kept, and is no longer held.")
                    done?(false)
                    return
                }
                controller.clipboard.set(text: text, secret: !keep)
                controller.extras.setMessage("Copied.")
                done?(true)
            }
        })
    }

    func delete(_ row: PanelRow) {
        let runtime = runtime
        let request: @Sendable () async -> Void
        switch row.source {
        case .clipboard:
            let id = row.id
            request = { _ = await runtime.handle(ControlRequest("clip.delete", arguments: ["id": id])) }
        case .history:
            guard let record = controller.record(for: row) else { return }
            let device = record.deviceID, id = record.id
            // The row only; a received file stays in the inbox.
            request = { try? await runtime.store.execute("DELETE FROM history WHERE device_id=? AND id=?", bindings: [.text(device), .text(id)]) }
        }
        let loop = controller.loop
        track(Task { [weak self] in
            await request()
            await loop.perform { [weak self] in
                self?.controller.view.clearSelection()
                self?.controller.refresh()
            }
        })
    }

    /// Removes a paired device here: its keys go and it can no longer send to this device.
    func remove(deviceID: String, name: String, done: (@Sendable (Result<Void, SendRefusal>) -> Void)? = nil) {
        let runtime = runtime, loop = controller.loop
        track(Task { [weak self] in
            let response = await runtime.handle(ControlRequest("unpair", arguments: ["device": deviceID]))
            await loop.perform { [weak self] in
                guard let self else { return }
                controller.extras.setMessage(response.ok ? "Removed \(name)." : (response.error ?? "Could not remove \(name)."))
                controller.refresh()
                controller.watcher.devicesMayHaveChanged()
            }
            done?(response.ok ? .success(()) : .failure(SendRefusal(message: response.error ?? "Could not remove \(name).")))
        })
    }

    /// The send-clipboard shortcut: the newest copy, if clipboard history recorded it, to the
    /// most recently used device. Success is quiet; a refusal raises a notification.
    func sendLatestCopy(done: (@Sendable (Result<[TransferRecord], SendRefusal>) -> Void)? = nil) {
        let runtime = runtime, loop = controller.loop
        controller.tray.set(.moving)
        track(Task { [weak self] in
            let response = await runtime.handle(ControlRequest("clip.send", arguments: ["latest": "true"]))
            guard response.ok, let row = try? response.decode(TransferRecord.self) else {
                let sentence = response.error ?? "Nothing was sent."
                await loop.perform { [weak self] in
                    self?.controller.tray.set(.problem)
                    self?.controller.notifier.problem(title: "Nothing sent", body: sentence)
                }
                done?(.failure(SendRefusal(message: sentence)))
                return
            }
            // The store watcher follows the row: quiet on success, a notification with Retry if not.
            done?(.success([row]))
        })
    }
}

struct SendRefusal: Error, Sendable {
    let message: String
}
