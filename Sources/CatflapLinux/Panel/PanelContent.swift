import CatflapCore
import Foundation

/// What the panel lists and sends, and the words it shows for them. No GTK here.
public struct PanelDevice: Sendable, Equatable {
    public let id: String
    public let name: String
}

public struct PanelRow: Sendable, Equatable {
    public enum Source: String, Sendable { case clipboard, history }
    public let id: String
    public let source: Source
    public let title: String
    public let subtitle: String
    /// The words a screen reader says for the row.
    public var accessibleLabel: String { subtitle.isEmpty ? title : "\(title), \(subtitle)" }
}

public enum PanelList: String, Sendable { case clipboard, history }

/// What Return or the send button would send.
public enum PanelPayload: Sendable, Equatable {
    case row(PanelRow)
    case text(String)
    case files([String])

    var preview: String {
        switch self {
        case .row(let row): return PanelText.preview(row.title)
        case .text(let text): return PanelText.preview(text)
        case .files(let names): return names.count == 1 ? PanelText.preview(names[0]) : "\(names.count) files"
        }
    }
}

public enum PanelText {
    static let previewLength = 20

    /// The first line, cut to a short preview with an ellipsis.
    public static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > previewLength else { return line }
        return String(line.prefix(previewLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The send button names the payload and the device, for example
    /// `Send "meeting notes…" to the Mac`.
    public static func sendLabel(_ payload: PanelPayload?, device: PanelDevice?) -> String {
        guard let device else { return "Pair a device to send" }
        guard let payload else { return "Send to \(device.name)" }
        if case .files(let names) = payload, names.count > 1 { return "Send \(names.count) files to \(device.name)" }
        return "Send \"\(payload.preview)\" to \(device.name)"
    }

    /// Return sends the selected row if there is one, otherwise the text in the field.
    public static func returnPayload(selected: PanelRow?, text: String) -> PanelPayload? {
        if let selected { return .row(selected) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(text)
    }

    /// Typing filters the list; it never selects a row.
    public static func filter(_ rows: [PanelRow], by text: String) -> [PanelRow] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query) }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func rows(clipboard items: [ClipboardItem]) -> [PanelRow] {
        items.map { item in
            let title: String
            switch item.kind {
            case .image: title = "Image"
            case .files:
                let names = (item.text ?? "").split(whereSeparator: \.isNewline).compactMap { URL(string: String($0))?.lastPathComponent }
                title = names.isEmpty ? "Files" : names.joined(separator: ", ")
            case .text, .url: title = item.text.map { preview(line: $0) } ?? ""
            }
            let kind = item.kind == .url ? "Link" : item.kind == .files ? "Files" : item.kind == .image ? "Image" : "Text"
            return PanelRow(id: item.id, source: .clipboard, title: title, subtitle: "\(kind), \(size(Int64(item.size)))")
        }
    }

    static func rows(history records: [HistoryRecord], devices: [PanelDevice]) -> [PanelRow] {
        records.map { record in
            let device = devices.first { $0.id == record.deviceID }?.name ?? "a removed device"
            let title = record.text.map { preview(line: $0) }
                ?? record.path.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? (record.kind == "text" ? "Text, not kept" : "File")
            let direction = record.direction == "received" ? "From \(device)" : "To \(device)"
            let status = record.status == "ok" ? "" : ", \(record.status)"
            return PanelRow(id: record.deviceID + "/" + record.id, source: .history, title: title,
                            subtitle: direction + status)
        }
    }

    /// One line for a list row: the first line, at most 120 characters.
    static func preview(line text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.count > 120 ? String(first.prefix(120)) + "…" : first
    }
}
