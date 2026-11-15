import CGtk
import CGtkShim
import CatflapCore
import Foundation

/// What `catflap ui invoke describe` reports: the panel's own state plus what the actions,
/// pairing, settings, notifications and the tray item add.
struct PanelReport: Codable, Sendable {
    var visible: Bool
    var mode: String
    var hasFocus: Bool
    var display: String?
    var shortcut: String
    var shortcutTrigger: String?
    var sendClipboardShortcut: String
    /// Which of the two shortcut requests made at start is open: `panel`, `send` or `settled`.
    var shortcutSetup: String
    /// `system-dialog` while the focused panel waits for the keyboard back from the system's
    /// question about a shortcut; nil otherwise.
    var focusLostTo: String?
    var desktop: String
    var placement: PanelPlacement
    var openedFrom: String
    var bands: [String]
    var width: Int
    var height: Int
    var reducedMotion: Bool
    var highContrast: Bool
    var opaque: Bool
    var motion: String
    var list: String
    var rows: [String]
    var selectedRow: Int?
    var field: String
    var sendLabel: String
    var devices: [String]
    var connection: String
    var lastReturn: String?
    var controls: [PanelView.Control]
    var page: String
    var attachments: [String]
    var message: String
    var messageActions: [String]
    var pairing: PairingPage.Report
    var settings: PanelSettings
    var tray: String
    enum CodingKeys: String, CodingKey {
        case visible, mode, display, shortcut, desktop, placement, bands, width, height, opaque, motion, list, rows
        case field, devices, connection, controls, page, attachments, message, pairing, settings, tray
        case hasFocus = "has_focus", shortcutTrigger = "shortcut_trigger", reducedMotion = "reduced_motion"
        case highContrast = "high_contrast", selectedRow = "selected_row", sendLabel = "send_label"
        case lastReturn = "last_return", openedFrom = "opened_from", messageActions = "message_actions"
        case sendClipboardShortcut = "send_clipboard_shortcut", shortcutSetup = "shortcut_setup", focusLostTo = "focus_lost_to"
    }
}

/// What `ui state` answers on Linux: the fields every desktop reports, and the panel's lists
/// whose latest read failed (`devices`, `clipboard`, `history`, `pause`), which the panel keeps
/// showing as it last read them.
struct LinuxUIState: Encodable, Sendable {
    let state: UIState
    let unreadable: [String]
    enum CodingKeys: String, CodingKey { case unreadable }
    func encode(to encoder: any Encoder) throws {
        try state.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(unreadable, forKey: .unreadable)
    }
}

/// The panel inside the agent with everything it does: the state machine, the view, the host,
/// the hover band and the hotkey as T10 built them, and the actions behind the controls,
/// pairing, settings, notifications on arrival, the tray item, the send-clipboard shortcut and
/// the file manager's menu.
final class PanelController: @unchecked Sendable {
    let runtime: AgentRuntime
    let loop: GtkLoop
    let host: any PanelHost
    let dataDirectory: URL
    // Everything below is touched only on the GTK thread.
    var machine = PanelMachine()
    var view: PanelView!
    var extras: PanelExtras!
    var pairing: PairingPage!
    var settingsPage: SettingsPage!
    var sender: Sender!
    var notifier: Notifier!
    var watcher: StoreWatcher!
    var tray: StatusNotifierItem!
    let clipboard: any ClipboardBackend
    let picker = FilePicker()
    var settings = PanelSettings()
    private let style = PanelStyle()
    let shortcut: any ShortcutBackend
    let sendShortcut: any ShortcutBackend
    /// The two shortcut requests the agent makes at start, one at a time: the system asks the
    /// person about each, and two questions at once leave one unanswered. `panel` until the
    /// panel's own shortcut is settled, `send` until the send-clipboard one is, then `settled`.
    enum ShortcutSetup: String { case panel, send, settled }
    private(set) var shortcutSetup = ShortcutSetup.panel
    /// The focused panel lost the keyboard while a request of `shortcutSetup` was open: to the
    /// system's question about it, which Catflap caused, not to a click outside.
    private(set) var focusLostToSystemDialog = false
    private var timers: [PanelMachine.Timer: UInt32] = [:]
    private var waiters: [(id: Int, mode: PanelMode, resume: () -> Void)] = []
    /// `panel.show` calls waiting for the panel they opened to get the keyboard.
    private var keyboardWaiters: [(id: Int, resume: () -> Void)] = []
    private var nextWaiter = 0
    private var wasActive = false
    private var refreshPending: UInt32 = 0
    private var tasks: [Task<Void, Never>] = []
    private(set) var stopped = false
    /// While the system file picker is open the panel has given up the keyboard on purpose,
    /// so losing focus must not close it.
    var dialogOpen = false
    /// Where the panel opened from: `top` (hotkey, hover band, drag) or `tray` (lower right).
    private(set) var openedFrom = "top"
    var records: [TransferRecord] = []
    var items: [ClipboardItem] = []
    /// The rest of what the panel last read from the agent, kept while a read fails.
    private var knownDevices: [PanelDevice] = []
    private var knownHistory: [HistoryRecord] = []
    private var knownPaused = false
    /// The lists whose latest read failed, by name; `ui state` reports them.
    private(set) var unreadable: [String] = []
    private let snapshots = ProcessInfo.processInfo.environment["CATFLAP_PANEL_SNAPSHOT_DIR"]

    private init(runtime: AgentRuntime, loop: GtkLoop, backends: DesktopBackends, dataDirectory: URL) {
        self.runtime = runtime; self.loop = loop; self.host = backends.host; self.dataDirectory = dataDirectory
        shortcut = backends.shortcut; sendShortcut = backends.sendShortcut; clipboard = backends.clipboard
    }

    /// Starts the panel if this session has a Wayland display and a desktop that
    /// `DesktopBackends.select` can serve. Nil otherwise; the agent then goes on without a panel.
    static func start(on runtime: AgentRuntime) async -> PanelController? {
        let environment = ProcessInfo.processInfo.environment
        // Only the display the agent was given: without one there is no desktop to show on.
        guard DesktopSession.hasPanelDisplay(environment), environment["CATFLAP_PANEL"] != "off" else {
            return nil
        }
        // The panel is one small surface in an agent that runs all day: software rendering
        // keeps a GPU context out of the process. A renderer the person chose still wins.
        setenv("GSK_RENDERER", "cairo", 0)
        guard let loop = await GtkLoop.start() else { return nil }
        if Task.isCancelled {
            await loop.stop()
            return nil
        }
        guard let backends = await loop.perform({ DesktopBackends.select() }) else {
            await loop.stop()
            return nil
        }
        let directory = await runtime.store.paths.directory
        let settings = await PanelSettings.load(from: runtime.store)
        let app = PanelController(runtime: runtime, loop: loop, backends: backends, dataDirectory: directory)
        await loop.perform { app.settings = settings; app.build() }
        let desktop = app.host.desktop
        await runtime.updatePlatformStatus { $0.desktop = desktop }
        await app.register()
        return app
    }

    func stop() async {
        let pending = await loop.perform { [self] () -> [Task<Void, Never>] in
            stopped = true
            for (_, source) in timers { GLib.cancel(source) }
            timers = [:]
            if refreshPending != 0 { GLib.cancel(refreshPending); refreshPending = 0 }
            for waiter in waiters { waiter.resume() }
            waiters = []
            for waiter in keyboardWaiters { waiter.resume() }
            keyboardWaiters = []
            shortcut.stop()
            sendShortcut.stop()
            host.stopTriggers()
            watcher.stop()
            tray.stop()
            notifier.stop()
            pairing.stop()
            gtk_window_destroy(view.window.cast())
            return tasks + sender.tasks
        }
        for task in pending { task.cancel() }
        await loop.stop()
    }

    // MARK: Building, on the GTK thread

    private func build() {
        style.install()
        view = PanelView()
        view.actions = self
        view.onEscape = { [weak self] selected in self?.escape(selected) }
        style.onChange = { [weak self] in
            guard let self else { return }
            style.apply(to: view.window, surface: view.surfaceWidget, blurAvailable: host.blurAvailable)
        }
        sender = Sender(controller: self)
        extras = PanelExtras(view: view, controller: self)
        pairing = PairingPage(controller: self)
        settingsPage = SettingsPage(controller: self)
        extras.add(page: pairing.widget, named: "pair")
        extras.add(page: settingsPage.widget, named: "settings")
        host.adopt(view.window)
        host.onDrop = { [weak self] files in self?.drop(files) }
        connectWindow()
        host.startTriggers { [weak self] event in self?.handle(event) }
        shortcut.start(onChange: { [weak self] in
            guard let self else { return }
            publish()
            settingsPage?.refreshShortcuts()
            if shortcutSetup == .panel && shortcut.state != "pending" { advanceShortcutSetup(to: .send) }
        }, onActivated: { [weak self] in self?.open(from: "top"); self?.handle(.hotkey(display: nil)) })
        notifier = Notifier(controller: self)
        tray = StatusNotifierItem(controller: self)
        watcher = StoreWatcher(controller: self)
        watcher.start()
        publish()
    }

    /// The panel's shortcut is settled: the send-clipboard request goes next. Once that one is
    /// settled too, a panel that lost the keyboard to the system's question gets it back.
    private func advanceShortcutSetup(to next: ShortcutSetup) {
        shortcutSetup = next
        switch next {
        case .panel:
            break
        case .send:
            sendShortcut.start(onChange: { [weak self] in
                guard let self else { return }
                settingsPage?.refreshShortcuts()
                if shortcutSetup == .send && sendShortcut.state != "pending" { advanceShortcutSetup(to: .settled) }
                publish()
            }, onActivated: { [weak self] in self?.sender.sendLatestCopy() })
        case .settled:
            if focusLostToSystemDialog {
                focusLostToSystemDialog = false
                returnFromDialog()
            }
        }
        publish()
    }

    private func connectWindow() {
        let window = view.window
        GLib.connect(window, "notify::is-active", Int32(CF_SHAPE_NOTIFY)) { [weak self] _ in
            guard let self else { return }
            let active = gtk_window_is_active(window.cast()) != 0
            defer { wasActive = active; publish() }
            if active {
                focusLostToSystemDialog = false
                let ready = keyboardWaiters
                keyboardWaiters = []
                for waiter in ready { waiter.resume() }
            }
            guard wasActive && !active && !dialogOpen && machine.mode == .focused && host.closesOnKeyboardLoss else { return }
            // On Wayland a click outside shows up as the panel losing keyboard focus. While a
            // shortcut request is open, the system may show its question about it at any moment
            // and that window takes the keyboard: Catflap's own question, so the panel stays.
            if shortcutSetup != .settled { focusLostToSystemDialog = true } else { handle(.focusLost) }
        }
        GLib.connect(window, "map", Int32(CF_SHAPE_VOID)) { [weak self] _ in
            guard let self else { return }
            style.apply(to: window, surface: view.surfaceWidget, blurAvailable: host.blurAvailable)
            if machine.mode != .focused { view.clearFocus() }
        }
        let motion = opaque(gtk_event_controller_motion_new())
        GLib.connect(motion, "enter", Int32(CF_SHAPE_POINT)) { [weak self] _ in self?.handle(.panelEntered) }
        GLib.connect(motion, "leave", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.handle(.panelLeft) }
        gtk_widget_add_controller(window.cast(), motion)
        let click = opaque(gtk_gesture_click_new())
        gtk_gesture_single_set_button(click, 0)
        gtk_event_controller_set_propagation_phase(click, GTK_PHASE_CAPTURE)
        GLib.connect(click, "pressed", Int32(CF_SHAPE_PRESS)) { [weak self] _ in self?.handle(.clickInside) }
        gtk_widget_add_controller(window.cast(), click)
        let drop = opaque(gtk_drop_target_new(gdk_file_list_get_type(), GDK_ACTION_COPY))
        GLib.connect(drop, "enter", Int32(CF_SHAPE_DROP_POINT)) { [weak self] event in
            guard let self else { return }
            handle(.dragEntered(display: machine.display, onPanel: true))
            event.pointee.result = Int32(GDK_ACTION_COPY.rawValue)
        }
        GLib.connect(drop, "leave", Int32(CF_SHAPE_VOID)) { [weak self] _ in self?.handle(.dragLeft(onPanel: true)) }
        GLib.connect(drop, "drop", Int32(CF_SHAPE_DROP)) { [weak self] event in
            let uris = event.pointee.text.map { String(cString: $0) } ?? ""
            self?.drop(uris.split(separator: "\n").map(String.init))
            event.pointee.result = 1
        }
        gtk_widget_add_controller(window.cast(), drop)
        // Paste files into the panel: a file list on the clipboard attaches its files instead
        // of pasting their names into the field.
        let keys = opaque(gtk_event_controller_key_new())
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        GLib.connect(keys, "key-pressed", Int32(CF_SHAPE_KEY)) { [weak self] event in
            guard let self else { return }
            event.pointee.result = extras.key(event.pointee.keyval, modifiers: event.pointee.modifiers) ? 1 : 0
        }
        gtk_widget_add_controller(window.cast(), keys)
    }

    /// A drop with files ends Drag and leaves the panel focused with the files attached, so
    /// Return or the send button sends them. A drop with nothing usable closes it.
    func drop(_ files: [String]) {
        guard !files.isEmpty else { handle(.dropped); return }
        extras.attach(files)
        if machine.mode != .focused { handle(.hotkey(display: machine.display)) }
        handle(.dropped)
    }

    private func escape(_ selected: Bool) {
        // A page other than the list goes back to the list first.
        if extras.page != "main" && !selected { extras.show(page: "main"); return }
        handle(.escape(hasSelection: selected))
    }

    // MARK: Events and effects, on the GTK thread

    func handle(_ event: PanelMachine.Event) {
        guard !stopped else { return }
        // With the hover band switched off in settings, resting on it does nothing; a file
        // dragged onto it still opens the panel.
        if case .bandEntered = event, !settings.hoverBand { return }
        let before = machine.mode
        for effect in machine.handle(event) { apply(effect) }
        if machine.mode != before { modeChanged() }
        publish()
    }

    /// Records where the next opening comes from, so the panel is placed there.
    func open(from origin: String) {
        guard machine.mode == .hidden else { return }
        openedFrom = origin
        TrayPlacement.apply(origin, to: view.window)
    }

    private func apply(_ effect: PanelMachine.Effect) {
        switch effect {
        case .start(let timer):
            if let old = timers.removeValue(forKey: timer) { GLib.cancel(old) }
            timers[timer] = GLib.timeout(milliseconds: timer.milliseconds) { [weak self] in
                guard let self else { return }
                timers[timer] = nil
                handle(.timerFired(timer))
            }
        case .cancel(let timer):
            if let old = timers.removeValue(forKey: timer) { GLib.cancel(old) }
        case .show(let mode, let display):
            let wasVisible = gtk_widget_get_visible(view.window.cast()) != 0
            if !wasVisible {
                // Hotkey, hover and drag open at the top centre; only the tray item opens it
                // in the corner, and it says so before it asks.
                if openedFrom != "tray" { TrayPlacement.apply("top", to: view.window) }
                style.enter(view.surfaceWidget)
            }
            host.present(view.window, mode: mode, display: display)
            if mode == .focused { extras.focusDefault() } else { view.clearFocus() }
            if !wasVisible {
                refresh()
                checkAvailability()
                tray.panelOpened()
            }
        case .hide:
            host.withdraw(view.window)
            wasActive = false
            focusLostToSystemDialog = false
            openedFrom = "top"
            view.didHide()
            extras.didHide()
        case .clearSelection:
            view.clearSelection()
        }
    }

    private func modeChanged() {
        let mode = machine.mode
        let ready = waiters.filter { $0.mode == mode }
        waiters.removeAll { $0.mode == mode }
        for waiter in ready { waiter.resume() }
        if let snapshots, mode != .hidden {
            _ = GLib.timeout(milliseconds: 600) { [weak self] in
                guard let self, machine.mode == mode else { return }
                let page = extras.page == "main" ? "" : "-" + extras.page
                _ = cf_snapshot_png(view.window.cast(), snapshots + "/panel-\(mode.rawValue)\(page).png")
            }
        }
    }

    /// Takes a picture of the panel as it is now, when snapshots are switched on.
    func snapshot(_ name: String) {
        guard let snapshots, machine.mode != .hidden else { return }
        _ = GLib.timeout(milliseconds: 400) { [weak self] in
            guard let self else { return }
            _ = cf_snapshot_png(view.window.cast(), snapshots + "/panel-\(name).png")
        }
    }

    func state() -> UIState {
        var state = UIState()
        let visible = gtk_widget_get_visible(view.window.cast()) != 0 && machine.mode != .hidden
        state.visible = visible
        state.mode = machine.mode.rawValue
        state.hasFocus = visible && gtk_window_is_active(view.window.cast()) != 0
        state.display = visible ? host.display(of: view.window) ?? machine.display : nil
        state.shortcut = shortcut.state
        return state
    }

    private func describe() -> PanelReport {
        let state = state()
        var placement = host.placement(of: view.window)
        placement.anchor = TrayPlacement.anchor(of: view.window)
        return PanelReport(
            visible: state.visible, mode: state.mode, hasFocus: state.hasFocus, display: state.display,
            shortcut: state.shortcut, shortcutTrigger: shortcut.trigger, sendClipboardShortcut: sendShortcut.state,
            shortcutSetup: shortcutSetup.rawValue, focusLostTo: focusLostToSystemDialog ? "system-dialog" : nil,
            desktop: host.desktop, placement: placement, openedFrom: openedFrom, bands: host.triggerDisplays,
            width: Int(gtk_widget_get_width(view.window.cast())), height: Int(gtk_widget_get_height(view.window.cast())),
            reducedMotion: style.reducedMotion, highContrast: style.highContrast, opaque: style.opaqueBackground,
            motion: style.motion, list: view.listMode.rawValue, rows: view.rowTitles, selectedRow: view.selectedIndex,
            field: view.fieldText, sendLabel: view.sendLabel, devices: view.deviceNames, connection: view.connection,
            lastReturn: view.lastReturn, controls: view.controls + extras.controls, page: extras.page,
            attachments: extras.attachmentNames, message: extras.message, messageActions: extras.messageActions,
            pairing: pairing.report, settings: settings, tray: tray.state)
    }

    /// Keeps the agent's copy of the UI state current for anything that reads it there.
    func publish() {
        let state = state()
        let runtime = runtime
        Task { await runtime.setUIState(state) }
    }

    // MARK: Lists from the agent

    func refresh() {
        let runtime = runtime, loop = loop
        track(Task { [weak self] in
            async let devices = Self.read([DeviceSummary].self, list: "devices", "devices", runtime)
            async let clipboard = Self.read([ClipboardItem].self, list: "clipboard", "clip.list", runtime)
            async let history = Self.read([HistoryRecord].self, list: "history", "history", runtime)
            async let transfers = Self.read([TransferRecord].self, list: "history", "history", runtime)
            async let pause = Self.read([String: Bool].self, list: "pause", "clip.pause", runtime)
            let readDevices = (await devices)?.map { PanelDevice(id: $0.id, name: $0.name) }
            let readItems = await clipboard, readRows = await history, readRecords = await transfers
            let readPaused = (await pause).map { $0["paused"] ?? false }
            guard !Task.isCancelled else { return }
            await loop.perform { [weak self] in
                guard let self, !stopped else { return }
                // A list that could not be read keeps what the panel last had instead of showing
                // as empty; only the agent's answer replaces it, an empty one too.
                var failed: [String] = []
                if let readDevices { knownDevices = readDevices } else { failed.append("devices") }
                if let readItems { items = readItems } else { failed.append("clipboard") }
                if let readRows, let readRecords { knownHistory = readRows; records = readRecords } else { failed.append("history") }
                if let readPaused { knownPaused = readPaused } else { failed.append("pause") }
                unreadable = failed
                view.update(devices: knownDevices, clipboard: items, history: knownHistory, paused: knownPaused)
                extras.listChanged()
                if readDevices != nil { settingsPage.update(devices: knownDevices) }
                tray.update(paused: knownPaused)
            }
        })
    }

    /// Device availability is checked when the panel opens, not on a timer.
    func checkAvailability() {
        let runtime = runtime, loop = loop
        track(Task { [weak self] in
            guard let devices = await Self.request([DeviceSummary].self, "devices", runtime), !devices.isEmpty,
                  let pairing = await runtime.service(PairingService.self) else {
                await loop.perform { [weak self] in self?.view.setConnection("") }
                return
            }
            let target = await loop.perform { [weak self] in self?.view.selectedDevice?.id } ?? devices[0].id
            let name = devices.first { $0.id == target }?.name ?? devices[0].name
            await loop.perform { [weak self] in self?.view.setConnection("Checking \(name)…") }
            var status = await pairing.startCheck(deviceID: target)
            while status.state == "running" && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                status = await pairing.checkStatus(deviceID: target) ?? status
            }
            guard !Task.isCancelled else { return }
            let text = status.state == "ok" ? "\(name) is reachable" : "Cannot reach \(name)"
            await loop.perform { [weak self] in
                guard let self, machine.mode != .hidden else { return }
                view.setConnection(text)
            }
        })
    }

    func track(_ task: Task<Void, Never>) {
        tasks.removeAll { $0.isCancelled }
        tasks.append(task)
        if tasks.count > 16 { tasks.removeFirst().cancel() }
    }

    static func request<T: Decodable>(_ type: T.Type, _ command: String, _ runtime: AgentRuntime,
                                      _ arguments: [String: String] = [:]) async -> T? {
        let response = await runtime.handle(ControlRequest(command, arguments: arguments))
        guard response.ok else { return nil }
        return try? response.decode(type)
    }

    /// One of the panel's lists from the agent, as `request` reads it; `list` is the name the
    /// test fault below and `ui state` use for it.
    static func read<T: Decodable>(_ type: T.Type, list: String, _ command: String, _ runtime: AgentRuntime) async -> T? {
        if failing(list) { return nil }
        return await request(type, command, runtime)
    }

    /// Tests only: while the file this names exists, the panel's reads of the lists it names
    /// (one per line: devices, clipboard, history, pause) fail as an agent error would. The
    /// read of the paired devices before a send has its own, CATFLAP_TEST_DEVICES_FAULT.
    /// Unset outside tests.
    private static let listsFault = ProcessInfo.processInfo.environment["CATFLAP_TEST_LISTS_FAULT"].flatMap { $0.isEmpty ? nil : $0 }

    private static func failing(_ list: String) -> Bool {
        guard let path = listsFault, let names = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return names.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == list }
    }

    // MARK: Control commands

    private func register() async {
        await runtime.register("ui.state") { [self] _ in
            try ControlResponse(value: await loop.perform { LinuxUIState(state: self.state(), unreadable: self.unreadable) })
        }
        await runtime.register("toggle") { [self] _ in
            try ControlResponse(value: await loop.perform {
                self.open(from: "top"); self.handle(.hotkey(display: nil)); return self.state()
            })
        }
        await runtime.register("ui.invoke") { [self] request in await invoke(request) }
        await runtime.register("panel.show") { [self] _ in await showPanel() }
    }

    private func invoke(_ request: ControlRequest) async -> ControlResponse {
        let action = request.arguments["action"] ?? ""
        switch action {
        case "toggle":
            return await reply { self.open(from: "top"); self.handle(.hotkey(display: nil)) }
        case "hide":
            return await reply { self.handle(.hide) }
        case "simulate-hover":
            return await reply(waitingFor: .hover) { self.handle(.bandEntered(display: self.host.triggerDisplays.first)) }
        case "simulate-leave":
            return await reply(waitingFor: .hidden) { self.handle(.bandLeft); self.handle(.panelLeft) }
        case "simulate-drag":
            return await reply { self.handle(.dragEntered(display: self.host.triggerDisplays.first, onPanel: false)) }
        case "simulate-drag-leave":
            return await reply(waitingFor: .hidden) { self.handle(.dragLeft(onPanel: false)); self.handle(.dragLeft(onPanel: true)) }
        case "simulate-drop":
            let files = PanelActionArguments.files(request.arguments)
            return await reply { self.drop(files) }
        case "configure-shortcut":
            let opened = await loop.perform { self.shortcut.configure() }
            return opened ? await reply {} : ControlResponse(failure: "This desktop has no dialog for changing the shortcut.", exitCode: 64)
        case "describe":
            return (try? ControlResponse(value: await loop.perform { self.describe() })) ?? ControlResponse(error: .storage)
        default:
            return await PanelActionArguments.invoke(action, request.arguments, on: self)
        }
    }

    /// `panel.show`: opens the panel focused if it is hidden or shown without the keyboard
    /// (hover, drag). A focused panel stays as it is, also one waiting for the system's
    /// shortcut question, and the panel is never hidden. Answers with the UI state once the
    /// panel it opened has the keyboard, or after two seconds with whatever state it is in.
    private func showPanel() async -> ControlResponse {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            GLib.idle { [self] in
                let before = machine.mode
                ensureFocused()
                guard before != .focused, machine.mode == .focused, !stopped,
                      gtk_window_is_active(view.window.cast()) == 0 else { return done.resume() }
                nextWaiter += 1
                let id = nextWaiter
                var resumed = false
                let finish = { if !resumed { resumed = true; done.resume() } }
                keyboardWaiters.append((id, finish))
                _ = GLib.timeout(milliseconds: 2000) { [weak self] in
                    self?.keyboardWaiters.removeAll { $0.id == id }
                    finish()
                }
            }
        }
        return (try? ControlResponse(value: await loop.perform { self.state() })) ?? ControlResponse(error: .storage)
    }

    /// Runs `body` on the GTK thread, then answers with the UI state. With `mode`, answers once
    /// the panel reaches it, or after two seconds with whatever state it is in.
    func reply(waitingFor mode: PanelMode? = nil, _ body: @escaping @Sendable () -> Void) async -> ControlResponse {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            GLib.idle { [self] in
                body()
                guard let mode, machine.mode != mode, !stopped else { return done.resume() }
                nextWaiter += 1
                let id = nextWaiter
                var resumed = false
                let finish = { if !resumed { resumed = true; done.resume() } }
                waiters.append((id, mode, finish))
                _ = GLib.timeout(milliseconds: 2000) { [weak self] in
                    self?.waiters.removeAll { $0.id == id }
                    finish()
                }
            }
        }
        return (try? ControlResponse(value: await loop.perform { self.state() })) ?? ControlResponse(error: .storage)
    }

    /// Shows the panel again, focused, after the system file picker closes.
    func returnFromDialog() {
        guard machine.mode == .focused, !stopped else { return }
        host.present(view.window, mode: .focused, display: machine.display)
        extras.focusDefault()
        publish()
    }

    /// The transfer behind a history row, whose id is `<device>/<transfer id>`.
    func record(for row: PanelRow) -> TransferRecord? {
        guard row.source == .history else { return nil }
        return records.first { $0.deviceID + "/" + $0.id == row.id }
    }

    /// Opens the panel focused if it is not, for actions that need the keyboard.
    func ensureFocused(from origin: String = "top") {
        if machine.mode != .focused {
            open(from: origin)
            handle(.hotkey(display: machine.display))
        }
    }
}

extension PanelController: PanelActions {
    /// Return or the send button, to the device the panel shows. Nothing goes until the agent's
    /// own list says that device is still paired; when the list cannot be read, nothing is
    /// sent and the panel says so, as for a `ui invoke` send.
    func send(_ payload: PanelPayload, to device: PanelDevice, keep: Bool) {
        let runtime = runtime, loop = loop
        track(Task { [weak self] in
            let outcome = await PanelActionArguments.target(device.id, runtime: runtime, selected: device,
                                                             missing: "No paired device has that id.")
            await loop.perform { [weak self] in
                guard let self, !stopped else { return }
                switch outcome {
                case .success(let paired): sender.send(payload, to: paired, keep: keep)
                case .failure(let refusal): extras.setMessage(refusal.message)
                }
            }
        })
    }

    func attach() { extras.pickFiles() }

    func openSettings() { extras.show(page: extras.page == "settings" ? "main" : "settings") }

    func setPaused(_ paused: Bool) {
        let runtime = runtime
        track(Task { [weak self] in
            _ = await runtime.handle(ControlRequest("clip.pause", arguments: ["paused": paused ? "true" : "false"]))
            await self?.loop.perform { [weak self] in self?.tray.update(paused: paused) }
        })
    }
}
