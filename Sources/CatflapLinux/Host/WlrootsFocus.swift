import CDataControl
import Foundation
import Synchronization

/// All connection and shortcut-state access is on the GTK thread. Only the capability
/// snapshot crosses to the control encoder, protected by a mutex.
final class WlrootsFocus {
    private var connection: OpaquePointer?
    private var timer: UInt32 = 0
    let isWlroots: Bool
    var onActivation: (() -> Void)?
    var onSetupChange: (() -> Void)?
    private static let capability = Mutex<(Bool, Bool)>((false, false))
    nonisolated(unsafe) private static var pending: Set<String> = ["toggle-panel", "send-clipboard"]
    nonisolated(unsafe) private static var setupChanged: (() -> Void)?

    static var shortcutPending: Bool { !pending.isEmpty }

    static func shortcutState(_ id: String, _ state: String) {
        if state == "pending" { pending.insert(id) } else { pending.remove(id) }
        setupChanged?()
    }

    init() {
        let opened = cf_wf_open()
        connection = opened
        isWlroots = opened.map { cf_wf_is_kde($0) == 0 } ?? false
        Self.capability.withLock { $0 = (isWlroots, connection.map { cf_wf_available($0) != 0 } ?? false) }
        Self.setupChanged = { [weak self] in self?.onSetupChange?() }
    }

    func discardActivations() {
        if let connection { _ = cf_wf_poll(connection) }
    }

    func start() {
        guard isWlroots, connection != nil, timer == 0 else { return }
        poll()
    }

    private func poll() {
        guard let connection else { return }
        let result = cf_wf_poll(connection)
        Self.capability.withLock { $0 = (isWlroots, cf_wf_available(connection) != 0) }
        if result > 0 && !Self.shortcutPending { onActivation?() }
        guard self.connection != nil, result >= 0 else { return }
        timer = GLib.timeout(milliseconds: 25) { [weak self] in
            guard let self else { return }
            timer = 0
            poll()
        }
    }

    func stop() {
        if timer != 0 { GLib.cancel(timer); timer = 0 }
        if let connection { cf_wf_destroy(connection) }
        connection = nil
        Self.setupChanged = nil
    }

    static var outsideClickPolicy: String? {
        capability.withLock { $0.0 ? ($0.1 ? "foreign-toplevel" : "escape-or-hotkey") : nil }
    }
}

// PanelPlacement's public shape is declared in the shared Host protocol file. Its
// encoder adds the wlroots-only capability without changing that file or KDE output.
extension PanelPlacement {
    public func encode(to encoder: any Encoder) throws {
        enum Keys: String, CodingKey {
            case layer, anchor, keyboard
            case exclusiveZone = "exclusive_zone", monitorRequested = "monitor_requested"
            case outsideClick = "outside_click"
        }
        var value = encoder.container(keyedBy: Keys.self)
        try value.encode(layer, forKey: .layer)
        try value.encode(anchor, forKey: .anchor)
        try value.encode(exclusiveZone, forKey: .exclusiveZone)
        try value.encode(keyboard, forKey: .keyboard)
        try value.encodeIfPresent(monitorRequested, forKey: .monitorRequested)
        try value.encodeIfPresent(WlrootsFocus.outsideClickPolicy, forKey: .outsideClick)
    }
}
