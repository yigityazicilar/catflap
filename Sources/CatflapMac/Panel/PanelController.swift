#if os(macOS)
import AppKit
import CatflapCore

/// What `catflap ui state --json` prints on macOS: the fields every desktop reports
/// (`visible`, `mode`, `has_focus`, `display`, `shortcut`) and what this one can show about
/// the window and the accessibility settings in effect.
struct MacUIState: Codable, Sendable {
    struct Frame: Codable, Sendable, Equatable {
        var x: Double, y: Double, width: Double, height: Double
        init(_ rect: NSRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    }
    var visible: Bool
    var mode: String
    var hasFocus: Bool
    var display: String?
    var shortcut: String
    var shortcutKeys: String
    /// The panel's surface on screen, its display's frame, and the part of that display below
    /// the menu bar.
    var frame: Frame?
    var displayFrame: Frame?
    var visibleFrame: Frame?
    var level: Int
    /// AppKit's `isActive`, which it sets while a non-activating panel is key.
    var appActive: Bool
    /// Whether the system has this app in front, and how often it activated it.
    var appFrontmost: Bool
    var activations: Int
    var activationPolicy: String
    var eventLoop: Bool
    /// `material`, or `opaque` under Reduce Transparency or Increase Contrast.
    var background: String
    /// `flap`, or `fade` under Reduce Motion.
    var motion: String
    var statusItem: Bool
    var list: String
    var rows: Int
    var clipboardRows: Int
    var historyRows: Int
    var devices: Int
    var attachments: Int
    var sendLabel: String
    enum CodingKeys: String, CodingKey {
        case visible, mode, display, shortcut, frame, level, background, motion, list, rows, devices, attachments
        case hasFocus = "has_focus", shortcutKeys = "shortcut_keys", displayFrame = "display_frame", visibleFrame = "visible_frame"
        case appActive = "app_active", appFrontmost = "app_frontmost", activations, activationPolicy = "activation_policy", eventLoop = "event_loop"
        case statusItem = "status_item", clipboardRows = "clipboard_rows", historyRows = "history_rows"
        case sendLabel = "send_label"
    }
}

/// Runs the panel: turns what the triggers report into state-machine events, moves the window
/// to match the state, keeps the lists fresh while the panel is open, and answers the control
/// channel's `toggle`, `ui state` and `ui invoke`.
@MainActor
final class PanelController: PanelWindowEvents, PanelViewActions, HoverBandEvents, StatusItemEvents {
    enum Placement {
        case topCentre(NSScreen)
        case under(NSRect, NSScreen)
        var screen: NSScreen {
            switch self {
            case .topCentre(let screen), .under(_, let screen): screen
            }
        }
    }

    /// Set by the actions task (T13): sends `payload` to `device`; `keep` is false with Don't keep.
    var sendHandler: ((PanelPayload, PanelDevice, Bool) -> Void)?

    private let feed: PanelFeed
    private let shell: AppShell
    private let window: PanelWindow
    private let surface: PanelView
    private let container: FlapContainer
    private let band = HoverBand()
    private var statusItem: PanelStatusItem?
    private var shortcut: PanelShortcut?
    private var machine = PanelStateMachine()
    private var model = PanelModel()
    private var placement: Placement?
    private var deadline: Task<Void, Never>?
    private var refresher: Task<Void, Never>?
    private var hiding: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private init(runtime: AgentRuntime) {
        feed = PanelFeed(runtime: runtime)
        // The application object and its accessory policy come before any window, so the
        // panel's window is made by an app that has neither a Dock entry nor activation.
        let shell = AppShell()
        shell.start()
        self.shell = shell
        let surface = PanelView()
        self.surface = surface
        container = FlapContainer(surface: surface)
        window = PanelWindow.make(size: NSSize(width: PanelView.width, height: 480))
    }

    /// Starts AppKit, the panel and its triggers, and takes over the control commands.
    static func start(runtime: AgentRuntime) async -> PanelController {
        let controller = PanelController(runtime: runtime)
        controller.install()
        await runtime.register("toggle") { _ in
            guard let state = await controller.invoke("toggle") else { return ControlResponse(error: .unsupported, exitCode: 64) }
            return try ControlResponse(value: state)
        }
        await runtime.register("ui.state") { _ in
            let state = await controller.snapshot()
            return try ControlResponse(value: state)
        }
        await runtime.register("ui.invoke") { request in
            guard let state = await controller.invoke(request.arguments["action"] ?? "") else {
                return ControlResponse(error: .unsupported, exitCode: 64)
            }
            return try ControlResponse(value: state)
        }
        return controller
    }

    private func install() {
        window.contentView = container
        window.events = self
        surface.actions = self
        band.events = self
        band.start()
        let environment = ProcessInfo.processInfo.environment
        // The menu bar item belongs to the app. A bare `catflap agent` run from a build
        // folder shows it only when asked, so tests and development runs leave no item
        // position in the person's preferences.
        if Bundle.main.bundleIdentifier != nil || environment["CATFLAP_STATUS_ITEM"] == "on" {
            let item = PanelStatusItem()
            item.events = self
            statusItem = item
        }
        shortcut = PanelShortcut { [weak self] in _ = self?.invoke("toggle") }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.applyAppearance() } })
        applyAppearance()
        render()
    }

    func stop() {
        machine.handle(.hide, now: Date())
        for task in [deadline, refresher, hiding] { task?.cancel() }
        window.orderOut(nil)
        band.stop()
        shortcut?.stop()
        statusItem?.remove()
        statusItem = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        shell.stop()
    }

    // MARK: Control channel

    /// Runs one `ui invoke` action and returns the state after it; nil for an unknown action.
    /// The `simulate-*` actions feed the state machine the events the triggers would.
    func invoke(_ action: String) -> MacUIState? {
        switch action {
        case "toggle":
            if machine.mode == .hidden { placement = .topCentre(Self.screenForHotkey()) }
            handle(.hotkey)
        case "hide": handle(.hide)
        case "simulate-hover":
            placement = .topCentre(Self.screenForHotkey())
            handle(.bandDwell)
        case "simulate-leave": handle(.pointerInside(false))
        case "simulate-return": handle(.pointerInside(true))
        case "simulate-drag":
            if machine.mode == .hidden { placement = .topCentre(Self.screenForHotkey()) }
            handle(.dragEnteredBand)
        case "simulate-drag-leave": handle(.dragInside(false))
        case "simulate-click-inside": handle(.clickInside)
        case "simulate-click-outside": handle(.clickOutside)
        case "simulate-escape": viewEscape()
        default: return nil
        }
        return snapshot()
    }

    func snapshot() -> MacUIState {
        let visible = machine.mode != .hidden
        let screen = placement?.screen
        let surfaceFrame = visible ? Self.surface(of: window.frame) : nil
        let accessibility = NSWorkspace.shared
        let policy: String = switch NSApplication.shared.activationPolicy() {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "unknown"
        }
        return MacUIState(
            visible: visible, mode: machine.mode.rawValue, hasFocus: visible && window.isKeyWindow,
            display: visible ? screen.map(Self.displayID) : nil,
            shortcut: shortcut?.state ?? "unavailable", shortcutKeys: shortcut?.description ?? "",
            frame: surfaceFrame.map(MacUIState.Frame.init), displayFrame: visible ? screen.map { MacUIState.Frame($0.frame) } : nil,
            visibleFrame: visible ? screen.map { MacUIState.Frame($0.visibleFrame) } : nil,
            level: window.level.rawValue, appActive: NSApplication.shared.isActive,
            appFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
            activations: shell.activations, activationPolicy: policy,
            eventLoop: shell.running, background: surface.opaqueBackground ? "opaque" : "material",
            motion: accessibility.accessibilityDisplayShouldReduceMotion ? "fade" : "flap",
            statusItem: statusItem != nil, list: model.list.rawValue, rows: model.rows.count,
            clipboardRows: model.clipboard.count, historyRows: model.history.count, devices: model.devices.count,
            attachments: model.attachments.count, sendLabel: model.sendLabel())
    }

    // MARK: State

    private func handle(_ event: PanelEvent) {
        let before = machine.mode
        machine.handle(event, now: Date())
        let after = machine.mode
        if before != after { transition(from: before, to: after) }
        scheduleDeadline()
    }

    private func scheduleDeadline() {
        deadline?.cancel()
        deadline = nil
        guard let closeAt = machine.closeAt else { return }
        let wait = max(0, closeAt.timeIntervalSinceNow) + 0.005
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            guard !Task.isCancelled else { return }
            self?.handle(.tick)
        }
    }

    private func transition(from before: PanelMode, to after: PanelMode) {
        switch after {
        case .hidden:
            hideWindow()
        case .hover, .drag:
            showWindow(animated: before == .hidden)
        case .focused:
            showWindow(animated: before == .hidden)
            // Key without activation: the panel is non-activating, and ordering it in front
            // apart from making it key keeps AppKit from activating the app as well.
            window.orderFrontRegardless()
            window.makeKey()
            _ = window.makeFirstResponder(surface.field)
        }
        statusItem?.pressed = after != .hidden && openedUnderItem
        render()
    }

    private var openedUnderItem: Bool {
        if case .under? = placement { return true }
        return false
    }

    private func showWindow(animated: Bool) {
        hiding?.cancel()
        hiding = nil
        guard let placement else { return }
        layoutWindow(placement)
        if animated || !window.isVisible {
            window.orderFrontRegardless()
            container.playOpen(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            startRefreshing()
        }
    }

    private func hideWindow() {
        refresher?.cancel()
        refresher = nil
        let duration = container.playClose(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 10))
            guard let self, !Task.isCancelled, self.machine.mode == .hidden else { return }
            self.window.orderOut(nil)
            self.container.reset()
        }
    }

    private func layoutWindow(_ placement: Placement) {
        container.layoutSubtreeIfNeeded()
        let size = NSSize(width: PanelView.width, height: max(surface.fittingSize.height, 200))
        let margin = FlapContainer.margin
        let surfaceFrame = Self.surfaceFrame(size: size, placement: placement)
        let frame = NSRect(x: surfaceFrame.minX - margin.left, y: surfaceFrame.minY - margin.bottom,
                           width: surfaceFrame.width + margin.left + margin.right,
                           height: surfaceFrame.height + margin.top + margin.bottom)
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }

    /// The hotkey and the hover band open the panel at the top centre, below the menu bar;
    /// the menu bar item opens it under itself.
    static func surfaceFrame(size: NSSize, placement: Placement) -> NSRect {
        let screen = placement.screen
        switch placement {
        case .topCentre:
            let top = screen.visibleFrame.maxY - 8
            return NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: top - size.height, width: size.width, height: size.height)
        case .under(let anchor, _):
            let low = screen.frame.minX + 8, high = screen.frame.maxX - 8 - size.width
            let x = min(max(anchor.midX - size.width / 2, low), high).rounded()
            let top = screen.visibleFrame.maxY - 6
            return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        }
    }

    static func surface(of windowFrame: NSRect) -> NSRect {
        let margin = FlapContainer.margin
        return NSRect(x: windowFrame.minX + margin.left, y: windowFrame.minY + margin.bottom,
                      width: windowFrame.width - margin.left - margin.right,
                      height: windowFrame.height - margin.top - margin.bottom)
    }

    /// The hotkey opens the panel on the display holding the pointer, else the focused one.
    static func screenForHotkey() -> NSScreen {
        HoverBand.screen(at: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func displayID(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { String($0.uint32Value) } ?? "unknown"
    }

    /// The band, the panel and the strip between them, where a hover panel stays open.
    private func hoverRegion() -> NSRect? {
        guard let screen = placement?.screen else { return nil }
        let surface = Self.surface(of: window.frame)
        return NSRect(x: surface.minX, y: surface.minY, width: surface.width, height: screen.frame.maxY + 1 - surface.minY)
    }

    private func regionContains(_ point: NSPoint) -> Bool {
        guard let region = hoverRegion() else { return false }
        return point.x >= region.minX && point.x <= region.maxX && point.y >= region.minY && point.y <= region.maxY
    }

    private func applyAppearance() {
        let workspace = NSWorkspace.shared
        surface.apply(.init(opaque: workspace.accessibilityDisplayShouldReduceTransparency || workspace.accessibilityDisplayShouldIncreaseContrast,
                            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast))
    }

    private func render() {
        surface.render(model, mode: machine.mode)
        statusItem?.glyph = model.paused ? .paused : .idle
        if machine.mode != .hidden, let placement, abs(Self.surface(of: window.frame).height - surface.fittingSize.height) > 0.5 {
            layoutWindow(placement)
        }
    }

    // MARK: Lists

    private func startRefreshing() {
        refresher?.cancel()
        let feed = feed
        refresher = Task { [weak self] in
            await feed.checkDevices()
            while !Task.isCancelled {
                let snapshot = await feed.load()
                guard !Task.isCancelled, let self else { return }
                self.model.update(devices: snapshot.devices, clipboard: snapshot.clipboard, history: snapshot.history, paused: snapshot.paused)
                self.render()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Window events

    func panelBecameKey() { handle(.clickInside) }
    func panelResignedKey() { handle(.resignedKey) }
    func panelEscape() { viewEscape() }
    func panelReturn() { viewReturn() }

    func panelKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let key = event.charactersIgnoringModifiers else { return false }
        if flags == .command {
            switch key {
            case "1": viewSelectList(.clipboard); return true
            case "2": viewSelectList(.history); return true
            case "[": model.moveTarget(by: -1); render(); return true
            case "]": model.moveTarget(by: 1); render(); return true
            case "d": viewSetDontKeep(!model.dontKeep); return true
            default: return false
            }
        }
        if flags == [.command, .option], let digit = Int(key), (1...9).contains(digit), digit <= model.devices.count {
            viewSelectDevice(model.devices[digit - 1].id)
            return true
        }
        return false
    }

    // MARK: View actions

    func viewFilterChanged(_ text: String) { model.setFilter(text); render() }
    func viewMoveSelection(_ step: Int) { model.moveSelection(by: step); render() }
    func viewSelectRow(_ id: String?) { model.select(id); render() }

    func viewReturn() { viewSend() }

    func viewEscape() {
        guard machine.mode == .focused else { return }
        let hadSelection = model.selectedRow != nil
        _ = model.escape()
        handle(.escape(selection: hadSelection))
        render()
    }

    func viewSelectList(_ list: PanelModel.List) { model.setList(list); render() }
    func viewSelectDevice(_ id: String) { model.selectTarget(id); render() }
    func viewSetDontKeep(_ on: Bool) { model.dontKeep = on; render() }

    func viewTogglePause() {
        let paused = !model.paused
        model.paused = paused
        render()
        let feed = feed
        Task { await feed.setPaused(paused) }
    }

    func viewSend() {
        guard let payload = model.payload, let device = model.target else { return }
        sendHandler?(payload, device, !model.dontKeep)
    }

    func viewRemoveAttachments() { model.attachments.removeAll(); render() }
    // Attach, pairing, settings, Retry and Reveal are the actions task's (T13).
    func viewAttach() {}
    func viewPair() {}
    func viewSettings() {}
    func viewRetry(_ rowID: String) {}
    func viewReveal(_ rowID: String) {}

    func viewDrag(inside: Bool) { handle(.dragInside(inside)) }

    func viewDrop(_ urls: [URL]) {
        model.attachments.append(contentsOf: urls)
        handle(.drop)
        render()
    }

    // MARK: Triggers

    func bandDwelled(on screen: NSScreen) {
        guard machine.mode == .hidden else { return }
        let runtime = feed.runtime
        Task { [weak self] in
            // The band can be switched off, and is off over full-screen apps unless switched on.
            let store = await runtime.store
            let enabled = (try? await store.setting("hover_band")) != "off"
            let overFullScreen = (try? await store.setting("hover_full_screen")) == "on"
            guard let self, enabled, overFullScreen || !Self.isFullScreen(screen),
                  self.machine.mode == .hidden, HoverBand.isInBand(NSEvent.mouseLocation) != nil else { return }
            self.placement = .topCentre(screen)
            self.handle(.bandDwell)
        }
    }

    func pointerMoved(to point: NSPoint) {
        guard machine.mode == .hover else { return }
        handle(.pointerInside(regionContains(point)))
    }

    func fileDragReachedBand(on screen: NSScreen) {
        switch machine.mode {
        case .hidden: placement = .topCentre(screen); handle(.dragEnteredBand)
        case .hover: handle(.dragEnteredBand)
        case .focused, .drag: break
        }
    }

    func fileDragMoved(to point: NSPoint) {
        guard machine.mode == .drag else { return }
        handle(.dragInside(regionContains(point)))
    }

    func fileDragEnded() {
        guard machine.mode == .drag else { return }
        handle(.dragInside(false))
    }

    func clickedOutside() { handle(.clickOutside) }

    func statusItemClicked(anchor: NSRect, screen: NSScreen?) {
        if machine.mode == .hidden { placement = .under(anchor, screen ?? Self.screenForHotkey()) }
        handle(.statusItem)
    }

    func statusItemDropped(_ urls: [URL], anchor: NSRect, screen: NSScreen?) {
        model.attachments = urls
        // The most recently used device is the first and the default.
        if let first = model.devices.first { model.selectTarget(first.id) }
        switch machine.mode {
        case .hidden:
            placement = .under(anchor, screen ?? Self.screenForHotkey())
            handle(.statusItem)
        case .hover, .drag: handle(.hotkey)
        case .focused: render()
        }
    }

    /// A window of another app covers the whole display: a full-screen app.
    static func isFullScreen(_ screen: NSScreen) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return false }
        let frame = screen.frame
        let target = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let me = Int(getpid())
        return windows.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? Int) != me,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect == target
        }
    }
}
#endif
