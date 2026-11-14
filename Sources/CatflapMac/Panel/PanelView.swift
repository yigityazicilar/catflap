#if os(macOS)
import AppKit

@MainActor
protocol PanelViewActions: AnyObject {
    func viewFilterChanged(_ text: String)
    func viewMoveSelection(_ step: Int)
    func viewSelectRow(_ id: String?)
    func viewReturn()
    func viewEscape()
    func viewSelectList(_ list: PanelModel.List)
    func viewSelectDevice(_ id: String)
    func viewSetDontKeep(_ on: Bool)
    func viewTogglePause()
    func viewAttach()
    func viewRemoveAttachments()
    func viewPair()
    func viewSettings()
    func viewSend()
    func viewRetry(_ rowID: String)
    func viewReveal(_ rowID: String)
    func viewDrag(inside: Bool)
    func viewDrop(_ urls: [URL])
}

/// The panel's surface, top to bottom as the Design brief lays it out: the field with Attach,
/// the paired devices, the Clipboard / History switch, the list, the send button, and a footer
/// with the connection state, Don't keep, pause and settings. System controls and system
/// materials only; Reduce Transparency and Increase Contrast give an opaque background.
final class PanelView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 420
    static let listHeight: CGFloat = 264
    static let radius: CGFloat = 20

    weak var actions: PanelViewActions?

    private let material = NSVisualEffectView()
    private let opaqueView = OpaqueBackground()
    let field = NSTextField()
    private let attach = NSButton()
    private let attachmentRow = NSStackView()
    private let attachmentLabel = NSTextField(labelWithString: "")
    private let removeAttachments = NSButton()
    private let deviceStrip = NSStackView()
    private let noDevices = NSStackView()
    private let listSwitch = NSSegmentedControl(labels: ["Clipboard", "History"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let listScroll = NSScrollView()
    private let empty = NSStackView()
    private let emptyGlyph = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(labelWithString: "")
    private let resume = NSButton(title: "Resume", target: nil, action: nil)
    let send = NSButton(title: "", target: nil, action: nil)
    private let connectionDot = NSImageView()
    private let connection = NSTextField(labelWithString: "")
    private let dontKeep = NSSwitch()
    private let dontKeepLabel = NSTextField(labelWithString: "Don't keep")
    private let pause = NSButton()
    private let settings = NSButton()

    private var rows: [PanelRow] = []
    private var shownDevices: [PanelDevice] = []
    private var shownTarget: String?
    private var applyingSelection = false
    private(set) var opaqueBackground = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Building

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.masksToBounds = true
        setAccessibilityElement(false)

        material.material = .popover
        material.blendingMode = .behindWindow
        // The app is never active, so the material must not follow the active state.
        material.state = .active
        material.maskImage = Self.roundedMask(radius: Self.radius)
        for background in [material, opaqueView] as [NSView] {
            background.translatesAutoresizingMaskIntoConstraints = false
            addSubview(background)
            NSLayoutConstraint.activate([
                background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
                background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        opaqueView.isHidden = true

        field.placeholderString = "Type to send, or filter"
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("Text to send, or filter the list")

        configureIcon(attach, symbol: "paperclip", label: "Attach files", key: "o", action: #selector(attachPressed))
        attach.bezelStyle = .push
        attach.controlSize = .large
        let top = NSStackView(views: [field, attach])
        top.orientation = .horizontal
        top.spacing = 8

        attachmentLabel.lineBreakMode = .byTruncatingMiddle
        attachmentLabel.textColor = .secondaryLabelColor
        attachmentLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        configureIcon(removeAttachments, symbol: "xmark.circle.fill", label: "Remove attached files", key: nil,
                      action: #selector(removeAttachmentsPressed))
        removeAttachments.isBordered = false
        attachmentRow.orientation = .horizontal
        attachmentRow.spacing = 4
        attachmentRow.addArrangedSubview(NSImageView(image: Self.symbol("paperclip", label: nil)))
        attachmentRow.addArrangedSubview(attachmentLabel)
        attachmentRow.addArrangedSubview(removeAttachments)
        attachmentRow.isHidden = true

        deviceStrip.orientation = .horizontal
        deviceStrip.spacing = 6
        deviceStrip.setAccessibilityElement(true)
        deviceStrip.setAccessibilityRole(.group)
        deviceStrip.setAccessibilityLabel("Send to")
        let pairLine = NSTextField(labelWithString: "Pair a device to start sending")
        pairLine.textColor = .secondaryLabelColor
        let pair = NSButton(title: "Pair a device\u{2026}", target: self, action: #selector(pairPressed))
        pair.bezelStyle = .push
        pair.setAccessibilityLabel("Pair a device")
        noDevices.orientation = .horizontal
        noDevices.spacing = 8
        noDevices.addArrangedSubview(pairLine)
        noDevices.addArrangedSubview(pair)

        listSwitch.target = self
        listSwitch.action = #selector(listSwitched)
        listSwitch.selectedSegment = 0
        listSwitch.segmentDistribution = .fillEqually
        listSwitch.setAccessibilityLabel("List")
        listSwitch.setToolTip("Clipboard \u{2318}1", forSegment: 0)
        listSwitch.setToolTip("History \u{2318}2", forSegment: 1)

        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Clipboard history")
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder

        emptyGlyph.imageScaling = .scaleProportionallyUpOrDown
        emptyGlyph.contentTintColor = .tertiaryLabelColor
        emptyGlyph.setAccessibilityElement(false)
        emptyTitle.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyTitle.alignment = .center
        emptyDetail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.alignment = .center
        resume.target = self
        resume.action = #selector(pausePressed)
        resume.bezelStyle = .push
        resume.controlSize = .small
        resume.setAccessibilityLabel("Resume clipboard history")
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 6
        for view in [emptyGlyph, emptyTitle, emptyDetail, resume] as [NSView] { empty.addArrangedSubview(view) }
        emptyGlyph.widthAnchor.constraint(equalToConstant: 44).isActive = true
        emptyGlyph.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let listArea = NSView()
        for view in [listScroll, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            listArea.addSubview(view)
        }
        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: listArea.topAnchor), listScroll.bottomAnchor.constraint(equalTo: listArea.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: listArea.leadingAnchor), listScroll.trailingAnchor.constraint(equalTo: listArea.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: listArea.centerXAnchor), empty.centerYAnchor.constraint(equalTo: listArea.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: listArea.widthAnchor),
            listArea.heightAnchor.constraint(equalToConstant: Self.listHeight),
        ])

        send.target = self
        send.action = #selector(sendPressed)
        send.bezelStyle = .push
        send.controlSize = .large
        send.bezelColor = .controlAccentColor
        send.lineBreakMode = .byTruncatingMiddle
        // Return is handled by the field and the window, not as a key equivalent, so that
        // Return while an input method is composing only commits the composition.
        send.toolTip = "Return"

        connectionDot.image = Self.symbol("circle.fill", label: nil, size: 7)
        connectionDot.contentTintColor = .tertiaryLabelColor
        connectionDot.setAccessibilityElement(false)
        connection.textColor = .secondaryLabelColor
        connection.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        dontKeep.target = self
        dontKeep.action = #selector(dontKeepSwitched)
        dontKeep.controlSize = .mini
        dontKeep.setAccessibilityLabel("Don't keep what you send in history")
        dontKeepLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        dontKeepLabel.textColor = .secondaryLabelColor
        dontKeepLabel.setAccessibilityElement(false)
        configureIcon(pause, symbol: "pause", label: "Pause clipboard history", key: "p", action: #selector(pausePressed))
        pause.keyEquivalentModifierMask = [.command, .shift]
        configureIcon(settings, symbol: "gearshape", label: "Settings", key: ",", action: #selector(settingsPressed))
        for button in [pause, settings] { button.bezelStyle = .accessoryBarAction; button.isBordered = false }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [connectionDot, connection, spacer, dontKeep, dontKeepLabel, pause, settings])
        footer.orientation = .horizontal
        footer.spacing = 6

        let stack = NSStackView(views: [top, attachmentRow, deviceStrip, noDevices, listSwitch, listArea, send, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        for row in [top, attachmentRow, deviceStrip, noDevices, listSwitch, listArea, send, footer] as [NSView] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }

        // The keyboard path through every control, also without Full Keyboard Access.
        field.nextKeyView = attach
        attach.nextKeyView = listSwitch
        listSwitch.nextKeyView = table
        table.nextKeyView = send
        send.nextKeyView = dontKeep
        dontKeep.nextKeyView = pause
        pause.nextKeyView = settings
        settings.nextKeyView = field

        registerForDraggedTypes([.fileURL])
    }

    private func configureIcon(_ button: NSButton, symbol: String, label: String, key: String?, action: Selector) {
        button.image = Self.symbol(symbol, label: label)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        if let key {
            button.keyEquivalent = key
            button.keyEquivalentModifierMask = .command
            button.toolTip = label + " (\u{2318}" + key.uppercased() + ")"
        } else { button.toolTip = label }
    }

    static func symbol(_ name: String, label: String?, size: CGFloat = 13) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: size, weight: .regular)) ?? image
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Rendering

    struct Appearance: Equatable {
        var opaque: Bool
        var increaseContrast: Bool
    }

    func apply(_ appearance: Appearance) {
        opaqueBackground = appearance.opaque
        material.isHidden = appearance.opaque
        opaqueView.isHidden = !appearance.opaque
        opaqueView.strongBorder = appearance.increaseContrast
        opaqueView.needsDisplay = true
    }

    /// Shows `model`. `mode` changes only the field's prompt while a file is dragged.
    func render(_ model: PanelModel, mode: PanelMode, now: Date = Date()) {
        if field.stringValue != model.filter { field.stringValue = model.filter }
        field.placeholderString = mode == .drag ? "Drop files to attach" : "Type to send, or filter"

        attachmentRow.isHidden = model.attachments.isEmpty
        attachmentLabel.stringValue = model.attachments.map(\.lastPathComponent).joined(separator: ", ")

        let hasDevices = !model.devices.isEmpty
        deviceStrip.isHidden = !hasDevices
        noDevices.isHidden = hasDevices
        if model.devices != shownDevices || model.target?.id != shownTarget { renderDevices(model) }

        listSwitch.selectedSegment = model.list == .clipboard ? 0 : 1
        table.setAccessibilityLabel(model.list == .clipboard ? "Clipboard history" : "Transfer history")
        let visible = model.rows
        if visible != rows {
            rows = visible
            table.reloadData()
        }
        applyingSelection = true
        if let id = model.selectedRow?.id, let index = rows.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else { table.deselectAll(nil) }
        applyingSelection = false
        renderEmpty(model)

        let font = send.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let room = Self.width - 24 - 40
        send.title = model.sendLabel { ($0 as NSString).size(withAttributes: [.font: font]).width <= room }
        send.isEnabled = model.canSend
        send.setAccessibilityLabel(send.title)

        let reach = model.target?.reach ?? .unknown
        switch reach {
        case .reachable: connection.stringValue = "Reachable"; connectionDot.contentTintColor = .systemGreen
        case .unreachable: connection.stringValue = "Not reachable"; connectionDot.contentTintColor = .systemRed
        case .checking: connection.stringValue = "Checking\u{2026}"; connectionDot.contentTintColor = .tertiaryLabelColor
        case .unknown: connection.stringValue = hasDevices ? "Not checked" : "No devices"; connectionDot.contentTintColor = .tertiaryLabelColor
        }
        connection.setAccessibilityLabel("Connection: " + connection.stringValue)
        dontKeep.state = model.dontKeep ? .on : .off
        pause.image = Self.symbol(model.paused ? "play" : "pause", label: nil)
        pause.contentTintColor = model.paused ? .controlAccentColor : nil
        pause.setAccessibilityLabel(model.paused ? "Resume clipboard history" : "Pause clipboard history")
    }

    private func renderDevices(_ model: PanelModel) {
        shownDevices = model.devices
        shownTarget = model.target?.id
        for view in deviceStrip.arrangedSubviews { view.removeFromSuperview() }
        for (index, device) in model.devices.enumerated() {
            let selected = device.id == model.target?.id
            let chip = DeviceChip(device: device, selected: selected, index: index)
            chip.target = self
            chip.action = #selector(devicePressed(_:))
            deviceStrip.addArrangedSubview(chip)
        }
        // Devices join the keyboard path after Attach.
        var previous: NSView = attach
        for chip in deviceStrip.arrangedSubviews { previous.nextKeyView = chip; previous = chip }
        previous.nextKeyView = listSwitch
    }

    private func renderEmpty(_ model: PanelModel) {
        let showEmpty = rows.isEmpty
        empty.isHidden = !showEmpty
        listScroll.isHidden = showEmpty
        guard showEmpty else { return }
        resume.isHidden = true
        if !model.filter.trimmingCharacters(in: .whitespaces).isEmpty, !(model.list == .clipboard ? model.clipboard : model.history).isEmpty {
            emptyGlyph.image = CatflapGlyph.idle.image(size: 44)
            emptyTitle.stringValue = "Nothing matches"
            emptyDetail.stringValue = "Return sends what you typed."
        } else if model.list == .clipboard && model.paused {
            emptyGlyph.image = CatflapGlyph.paused.image(size: 44)
            emptyTitle.stringValue = "Clipboard history is paused"
            emptyDetail.stringValue = "Nothing you copy is being recorded."
            resume.isHidden = false
        } else if model.list == .clipboard {
            emptyGlyph.image = CatflapGlyph.idle.image(size: 44)
            emptyTitle.stringValue = "Nothing copied yet"
            emptyDetail.stringValue = "What you copy is listed here."
        } else {
            emptyGlyph.image = CatflapGlyph.idle.image(size: 44)
            emptyTitle.stringValue = "Nothing has come through yet"
            emptyDetail.stringValue = "Things you send and receive are listed here."
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].title.contains("\n") ? 58 : 44
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = PanelRowView(row: rows[row], now: Date())
        cell.retry.target = self
        cell.retry.action = #selector(retryPressed(_:))
        cell.reveal.target = self
        cell.reveal.action = #selector(revealPressed(_:))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let index = table.selectedRow
        actions?.viewSelectRow(index >= 0 && index < rows.count ? rows[index].id : nil)
    }

    // MARK: Field

    func controlTextDidChange(_ obj: Notification) { actions?.viewFilterChanged(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // While an input method is composing, Return only commits the composition.
            if textView.hasMarkedText() { return false }
            actions?.viewReturn()
            return true
        case #selector(NSResponder.moveDown(_:)): actions?.viewMoveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): actions?.viewMoveSelection(-1); return true
        case #selector(NSResponder.cancelOperation(_:)): actions?.viewEscape(); return true
        default: return false
        }
    }

    // MARK: Drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        actions?.viewDrag(inside: true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { actions?.viewDrag(inside: false) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        actions?.viewDrop(urls)
        return true
    }

    // MARK: Actions

    @objc private func attachPressed() { actions?.viewAttach() }
    @objc private func removeAttachmentsPressed() { actions?.viewRemoveAttachments() }
    @objc private func pairPressed() { actions?.viewPair() }
    @objc private func settingsPressed() { actions?.viewSettings() }
    @objc private func sendPressed() { actions?.viewSend() }
    @objc private func pausePressed() { actions?.viewTogglePause() }
    @objc private func dontKeepSwitched() { actions?.viewSetDontKeep(dontKeep.state == .on) }
    @objc private func listSwitched() { actions?.viewSelectList(listSwitch.selectedSegment == 1 ? .history : .clipboard) }
    @objc private func devicePressed(_ sender: DeviceChip) { actions?.viewSelectDevice(sender.deviceID) }
    @objc private func retryPressed(_ sender: NSButton) { if let id = sender.identifier?.rawValue { actions?.viewRetry(id) } }
    @objc private func revealPressed(_ sender: NSButton) { if let id = sender.identifier?.rawValue { actions?.viewReveal(id) } }
}

/// A paired device: a computer glyph, the name and a status dot. The first is the default
/// target; the selected one is shown pressed in the accent colour.
final class DeviceChip: NSButton {
    let deviceID: String

    init(device: PanelDevice, selected: Bool, index: Int) {
        deviceID = device.id
        super.init(frame: .zero)
        setButtonType(.pushOnPushOff)
        bezelStyle = .accessoryBarAction
        state = selected ? .on : .off
        contentTintColor = selected ? .controlAccentColor : nil
        image = PanelView.symbol("desktopcomputer", label: nil)
        imagePosition = .imageLeading
        let dot: String = switch device.reach {
        case .reachable: " \u{25CF}"
        case .unreachable: " \u{25CB}"
        case .checking, .unknown: ""
        }
        title = device.name + dot
        alphaValue = device.reach == .unreachable ? 0.55 : 1
        let reach: String = switch device.reach {
        case .reachable: "reachable"
        case .unreachable: "not reachable"
        case .checking: "checking"
        case .unknown: "not checked"
        }
        setAccessibilityLabel("Send to \(device.name), \(reach)" + (index == 0 ? ", most recent" : ""))
        if index < 9 { toolTip = "\(device.name) (\u{2318}\u{2325}\(index + 1))" }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One list row: a kind glyph, up to two lines of preview, secondary text and a quiet time.
final class PanelRowView: NSTableCellView {
    let retry = NSButton(title: "Retry", target: nil, action: nil)
    let reveal = NSButton(title: "Reveal", target: nil, action: nil)

    init(row: PanelRow, now: Date) {
        super.init(frame: .zero)
        let symbol: String = switch row.kind {
        case .text: "doc.plaintext"
        case .url: "link"
        case .image: "photo"
        case .files: "doc"
        case .sent: "arrow.up"
        case .received: "arrow.down"
        }
        let glyph = NSImageView(image: PanelView.symbol(symbol, label: nil))
        glyph.contentTintColor = .secondaryLabelColor
        let title = NSTextField(wrappingLabelWithString: row.title)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var texts: [NSView] = [title]
        var spoken = row.title
        var secondary: [String] = []
        if let detail = row.detail { secondary.append(detail) }
        if row.status == "unconfirmed" { secondary.append("Unconfirmed") }
        else if row.status == "failed" { secondary.append("Failed") }
        else if row.status == "sending" || row.status == "receiving" { secondary.append(row.status == "sending" ? "Sending" : "Receiving") }
        if !secondary.isEmpty {
            let line = NSTextField(labelWithString: secondary.joined(separator: " \u{00B7} "))
            line.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            line.textColor = row.status == "unconfirmed" || row.status == "failed" ? .systemOrange : .secondaryLabelColor
            texts.append(line)
            spoken += ", " + secondary.joined(separator: ", ")
        }
        let column = NSStackView(views: texts)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        let time = NSTextField(labelWithString: panelRelativeTime(row.timestamp, now: now))
        time.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        time.textColor = .tertiaryLabelColor
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        var parts: [NSView] = [glyph, column]
        for (button, shown) in [(retry, row.canRetry), (reveal, row.canReveal)] where shown {
            button.bezelStyle = .push
            button.controlSize = .small
            button.identifier = .init(row.id)
            button.setAccessibilityLabel(button.title + " " + row.title)
            parts.append(button)
        }
        parts.append(time)
        let line = NSStackView(views: parts)
        line.orientation = .horizontal
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(spoken + ", " + time.stringValue)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The background under Reduce Transparency or Increase Contrast: the window colour, opaque,
/// with a stronger edge when contrast is increased.
final class OpaqueBackground: NSView {
    var strongBorder = false

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = PanelView.radius
        layer?.borderWidth = strongBorder ? 1 : 0.5
        layer?.borderColor = (strongBorder ? NSColor.labelColor : NSColor.separatorColor).cgColor
    }
}
#endif
