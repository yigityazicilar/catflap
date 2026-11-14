#if os(macOS)
import Foundation

/// One row of the panel's list, already reduced to what the panel shows.
struct PanelRow: Sendable, Equatable {
    enum Kind: String, Sendable { case text, url, image, files, sent, received }
    let id: String
    let kind: Kind
    /// Up to two lines of preview, or a file name with its size.
    let title: String
    /// Secondary text: the device name for history rows.
    let detail: String?
    let timestamp: Date
    /// `unconfirmed`, `failed`, `sending` and the like for history rows; nil for clipboard rows.
    let status: String?
    /// What sending this row sends, for the send button's label.
    let payloadName: String
    let canRetry: Bool
    let canReveal: Bool
}

struct PanelDevice: Sendable, Equatable {
    enum Reach: String, Sendable { case unknown, checking, reachable, unreachable }
    let id: String
    let name: String
    var reach: Reach
}

/// What Return or the send button would send.
enum PanelPayload: Equatable {
    case row(PanelRow)
    case files([URL])
    case text(String)
}

/// The panel's content and selection, and the keyboard rules of the Design brief that do not
/// need a window: typing filters and never selects, arrows select, Return sends the selected
/// row or else the field's text, Esc clears a selection before it closes.
struct PanelModel: Sendable, Equatable {
    enum List: String, Sendable { case clipboard, history }

    var list: List = .clipboard
    var devices: [PanelDevice] = []
    var clipboard: [PanelRow] = []
    var history: [PanelRow] = []
    var paused = false
    var dontKeep = false
    var attachments: [URL] = []
    private(set) var filter = ""
    private(set) var selectedID: String?
    /// The chosen target. The first device (most recently sent to) is the default.
    private(set) var targetID: String?

    var target: PanelDevice? { devices.first { $0.id == targetID } ?? devices.first }

    /// The rows of the current list that match the field.
    var rows: [PanelRow] {
        let all = list == .clipboard ? clipboard : history
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || ($0.detail?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    var selectedRow: PanelRow? { selectedID.flatMap { id in rows.first { $0.id == id } } }

    mutating func setFilter(_ text: String) {
        filter = text
        // Typing filters the list and never selects a row.
        selectedID = nil
    }

    mutating func setList(_ value: List) {
        guard value != list else { return }
        list = value
        selectedID = nil
    }

    mutating func select(_ id: String?) { selectedID = id.flatMap { id in rows.contains { $0.id == id } ? id : nil } }

    /// Arrow keys: down from no selection selects the first row, up from the first row
    /// clears the selection and returns to the field.
    mutating func moveSelection(by step: Int) {
        let visible = rows
        guard !visible.isEmpty else { selectedID = nil; return }
        guard let current = selectedID, let index = visible.firstIndex(where: { $0.id == current }) else {
            selectedID = step > 0 ? visible[0].id : nil
            return
        }
        let next = index + step
        if next < 0 { selectedID = nil } else { selectedID = visible[min(next, visible.count - 1)].id }
    }

    /// Esc. Returns true when the press should close the panel.
    mutating func escape() -> Bool {
        if selectedRow != nil { selectedID = nil; return false }
        return true
    }

    mutating func selectTarget(_ id: String) { if devices.contains(where: { $0.id == id }) { targetID = id } }

    mutating func moveTarget(by step: Int) {
        guard !devices.isEmpty else { return }
        let index = devices.firstIndex { $0.id == target?.id } ?? 0
        targetID = devices[(index + step + devices.count) % devices.count].id
    }

    /// Replaces the lists with fresh rows from the agent. The selection and the target stay
    /// when their rows and devices still exist.
    mutating func update(devices: [PanelDevice], clipboard: [PanelRow], history: [PanelRow], paused: Bool) {
        self.devices = devices; self.clipboard = clipboard; self.history = history; self.paused = paused
        if let id = targetID, !devices.contains(where: { $0.id == id }) { targetID = nil }
        if let id = selectedID, !rows.contains(where: { $0.id == id }) { selectedID = nil }
    }

    /// Return: the selected row if there is one, else attached files, else the field's text.
    var payload: PanelPayload? {
        if let row = selectedRow { return .row(row) }
        if !attachments.isEmpty { return .files(attachments) }
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : .text(filter)
    }

    var canSend: Bool { target != nil && payload != nil }

    /// The send button's label. It always names the payload and the device. A long payload
    /// is shortened in its middle; the device name is never shortened. `fits` says whether a
    /// candidate label fits the button.
    func sendLabel(fits: (String) -> Bool = { $0.count <= 56 }) -> String {
        guard let device = target else { return "Pair a device to send" }
        guard let payload else { return "Type something to send" }
        switch payload {
        case .files(let urls):
            let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
            return Self.label(quoted: false, payload: name, device: device.name, fits: fits)
        case .row(let row):
            return Self.label(quoted: row.kind == .text || row.kind == .sent || row.kind == .received,
                              payload: row.payloadName, device: device.name, fits: fits)
        case .text(let text):
            return Self.label(quoted: true, payload: text, device: device.name, fits: fits)
        }
    }

    static func label(quoted: Bool, payload: String, device: String, fits: (String) -> Bool) -> String {
        let flat = payload.split(whereSeparator: \.isNewline).joined(separator: " ")
        func compose(_ shown: String) -> String { quoted ? "Send \u{201C}\(shown)\u{201D} to \(device)" : "Send \(shown) to \(device)" }
        let whole = compose(flat)
        if fits(whole) { return whole }
        let characters = Array(flat)
        // The longest middle-shortened payload that fits, found by halving.
        var low = 0, high = characters.count
        while low < high {
            let keep = (low + high + 1) / 2
            if fits(compose(middle(characters, keep: keep))) { low = keep } else { high = keep - 1 }
        }
        return compose(middle(characters, keep: max(low, 1)))
    }

    private static func middle(_ characters: [Character], keep: Int) -> String {
        guard keep < characters.count else { return String(characters) }
        let head = (keep + 1) / 2, tail = keep / 2
        return String(characters.prefix(head)) + "\u{2026}" + String(characters.suffix(tail))
    }
}

/// A quiet relative time for list rows: `now`, `2 min`, `1 h`, `3 d`.
func panelRelativeTime(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60)) min"
    case ..<86_400: return "\(Int(seconds / 3600)) h"
    default: return "\(Int(seconds / 86_400)) d"
    }
}
#endif
