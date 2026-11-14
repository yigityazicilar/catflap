#if os(macOS)
import CatflapCore
import Foundation

/// Reads the panel's lists from the agent it runs in: paired devices in the store's order
/// (most recently sent to first), clipboard history and transfer history. Nothing is cached
/// here; the panel asks again while it is open, so new rows appear without reopening it.
struct PanelFeed: Sendable {
    let runtime: AgentRuntime

    struct Snapshot: Sendable {
        var devices: [PanelDevice] = []
        var clipboard: [PanelRow] = []
        var history: [PanelRow] = []
        var paused = false
    }

    func load(now: Date = Date()) async -> Snapshot {
        var snapshot = Snapshot()
        let store = await runtime.store
        let summaries = ((try? await store.devices()) ?? []).map(DeviceSummary.init)
        let pairing = await runtime.service(PairingService.self)
        for device in summaries {
            let check = await pairing?.checkStatus(deviceID: device.id)
            snapshot.devices.append(PanelDevice(id: device.id, name: device.name, reach: Self.reach(check?.state)))
        }
        if let clipboard = await runtime.service(ClipboardHistory.self) {
            snapshot.paused = await clipboard.isPaused()
            snapshot.clipboard = ((try? await clipboard.items(now: now)) ?? []).map(Self.row)
        }
        let names = Dictionary(summaries.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        snapshot.history = ((try? await TransferHistory(store: store).rows()) ?? []).map { Self.row($0, names: names) }
        return snapshot
    }

    /// Device availability is checked when the panel opens, not on a timer.
    func checkDevices() async {
        guard let pairing = await runtime.service(PairingService.self) else { return }
        for device in (try? await runtime.store.devices()) ?? [] {
            _ = await pairing.startCheck(deviceID: device.id)
        }
    }

    func setPaused(_ value: Bool) async {
        try? await runtime.service(ClipboardHistory.self)?.setPaused(value)
    }

    static func reach(_ state: String?) -> PanelDevice.Reach {
        switch state {
        case "ok": .reachable
        case "failed": .unreachable
        case "running": .checking
        default: .unknown
        }
    }

    static func row(_ item: ClipboardItem) -> PanelRow {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        let title: String
        let payload: String
        switch item.kind {
        case .text, .url:
            title = preview(item.text ?? "")
            payload = title
        case .image:
            title = "Image, \(size)"
            payload = "image"
        case .files:
            let names = (item.text ?? "").split(whereSeparator: \.isNewline).map { line -> String in
                let value = String(line)
                return URL(string: value)?.lastPathComponent ?? (value as NSString).lastPathComponent
            }
            title = names.count == 1 ? names[0] : "\(names.count) files: " + names.joined(separator: ", ")
            payload = names.count == 1 ? names[0] : "\(names.count) files"
        }
        let kind: PanelRow.Kind = switch item.kind {
        case .text: .text
        case .url: .url
        case .image: .image
        case .files: .files
        }
        return PanelRow(id: item.id, kind: kind, title: title, detail: nil, timestamp: item.timestamp, status: nil,
                        payloadName: payload, canRetry: false, canReveal: false)
    }

    static func row(_ record: TransferRecord, names: [String: String]) -> PanelRow {
        let title: String
        if let text = record.text { title = preview(text) }
        else if let name = record.targetName ?? record.path.map({ ($0 as NSString).lastPathComponent }) {
            title = name + ", " + ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file)
        } else { title = record.kind == "text" ? "Text, not kept" : "File, not kept" }
        return PanelRow(id: record.deviceID + "/" + record.id, kind: record.direction == "sent" ? .sent : .received,
                        title: title, detail: names[record.deviceID] ?? "Removed device", timestamp: record.timestamp,
                        status: record.status, payloadName: title, canRetry: record.canRetry,
                        canReveal: record.direction == "received" && record.path != nil && record.status == "ok")
    }

    /// Up to two lines of a text, without trailing blank lines.
    static func preview(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).prefix(2).map { $0.trimmingCharacters(in: .whitespaces) }
        let joined = lines.joined(separator: "\n")
        return joined.count > 240 ? String(joined.prefix(240)) + "\u{2026}" : joined
    }
}
#endif
