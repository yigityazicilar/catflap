import CGtk
import CGtkShim
import CatflapCore
import Foundation

/// What `catflap ui state` reports while the panel runs.
struct PanelDescription: Codable, Sendable {
    var visible: Bool
    var mode: String
    var hasFocus: Bool
    var display: String?
    var shortcut: String
    var shortcutTrigger: String?
    var desktop: String
    var placement: PanelPlacement
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
    enum CodingKeys: String, CodingKey {
        case visible, mode, display, shortcut, desktop, placement, bands, width, height, opaque, motion, list, rows
        case field, devices, connection, controls
        case hasFocus = "has_focus", shortcutTrigger = "shortcut_trigger", reducedMotion = "reduced_motion"
        case highContrast = "high_contrast", selectedRow = "selected_row", sendLabel = "send_label"
        case lastReturn = "last_return"
    }
}

/// The panel inside the agent: GTK on its own thread, a `PanelHost` that places it, the
/// state machine, the hover band, the hotkey, and lists read from the agent's own commands.
final class PanelApp: @unchecked Sendable {
    private let runtime: AgentRuntime
    private let loop: GtkLoop
    private let host: LayerShellHost
    private let dataDirectory: URL
    // Everything below is touched only on the GTK thread.
    private var machine = PanelMachine()
    private var view: PanelView!
    private let style = PanelStyle()
    private let shortcut = GlobalShortcut()
    private var timers: [PanelMachine.Timer: UInt32] = [:]
    private var waiters: [(id: Int, mode: PanelMode, resume: () -> Void)] = []
    private var nextWaiter = 0
    private var wasActive = false
    private var storeMonitor: OpaquePointer?
    private var refreshPending: UInt32 = 0
    private var tasks: [Task<Void, Never>] = []
    private var stopped = false
    private let snapshots = ProcessInfo.processInfo.environment["CATFLAP_PANEL_SNAPSHOT_DIR"]

    private init(runtime: AgentRuntime, loop: GtkLoop, host: LayerShellHost, dataDirectory: URL) {
        self.runtime = runtime; self.loop = loop; self.host = host; self.dataDirectory = dataDirectory
    }

    /// Starts the panel if this session has a Wayland display whose compositor offers
    /// layer-shell. Nil otherwise; the agent then goes on without a panel.
    static func start(on runtime: AgentRuntime) async -> PanelApp? {
        let environment = ProcessInfo.processInfo.environment
        // Only the display the agent was given: without one there is no desktop to show on.
        guard let display = environment["WAYLAND_DISPLAY"], !display.isEmpty, environment["CATFLAP_PANEL"] != "off" else {
            return nil
        }
        // The panel is one small surface in an agent that runs all day: software rendering
        // keeps a GPU context out of the process and works on compositors that cannot
        // import GPU buffers. A renderer the person chose still wins.
        setenv("GSK_RENDERER", "cairo", 0)
        guard let loop = await GtkLoop.start() else { return nil }
        // The agent began to stop while GTK was starting.
        if Task.isCancelled {
            await loop.stop()
            return nil
        }
        guard await loop.perform({ LayerShellHost.isSupported }) else {
            await loop.stop()
            return nil
        }
        let directory = await runtime.store.paths.directory
        let app = PanelApp(runtime: runtime, loop: loop, host: LayerShellHost(), dataDirectory: directory)
        await loop.perform { app.build() }
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
            shortcut.stop()
            host.stopTriggers()
            if let storeMonitor {
                g_file_monitor_cancel(storeMonitor.cast())
                g_object_unref(UnsafeMutableRawPointer(storeMonitor))
            }
            storeMonitor = nil
            gtk_window_destroy(view.window.cast())
            return tasks
        }
        for task in pending { task.cancel() }
        await loop.stop()
    }

    // MARK: Building, on the GTK thread

    private func build() {
        style.install()
        view = PanelView()
        view.actions = self
        view.onEscape = { [weak self] selected in self?.handle(.escape(hasSelection: selected)) }
        style.onChange = { [weak self] in
            guard let self else { return }
            style.apply(to: view.window, surface: view.surfaceWidget, blurAvailable: host.blurAvailable)
        }
        host.adopt(view.window)
        host.onDrop = { [weak self] files in self?.drop(files) }
        connectWindow()
        host.startTriggers { [weak self] event in self?.handle(event) }
        shortcut.start(onChange: { [weak self] in self?.publish() },
                       onActivated: { [weak self] in self?.handle(.hotkey(display: nil)) })
        watchStore()
        publish()
    }

    private func connectWindow() {
        let window = view.window
        GLib.connect(window, "notify::is-active", Int32(CF_SHAPE_NOTIFY)) { [weak self] _ in
            guard let self else { return }
            let active = gtk_window_is_active(window.cast()) != 0
            defer { wasActive = active; publish() }
            // On Wayland a click outside shows up as the panel losing keyboard focus.
            if wasActive && !active { handle(.focusLost) }
        }
        GLib.connect(window, "map", Int32(CF_SHAPE_VOID)) { [weak self] _ in
            guard let self else { return }
            style.apply(to: window, surface: view.surfaceWidget, blurAvailable: host.blurAvailable)
            // GTK picks a first focus widget when a window maps.
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
    }

    private func drop(_ files: [String]) {
        if !files.isEmpty { view.attach(files) }
        handle(.dropped)
    }

    /// Lists follow the store: a change to the database while the panel is shown refreshes
    /// them. File events, not a timer, so a hidden panel costs nothing.
    private func watchStore() {
        let directory = g_file_new_for_path(dataDirectory.path)
        defer { g_object_unref(UnsafeMutableRawPointer(directory)) }
        guard let monitor = g_file_monitor_directory(directory, GFileMonitorFlags(rawValue: 0), nil, nil) else { return }
        storeMonitor = OpaquePointer(monitor)
        GLib.connect(OpaquePointer(monitor), "changed", Int32(CF_SHAPE_FILE)) { [weak self] event in
            guard let self, machine.mode != .hidden,
                  let name = event.pointee.text.map({ String(cString: $0) }), name.hasPrefix("store.sqlite") else { return }
            guard refreshPending == 0 else { return }
            refreshPending = GLib.timeout(milliseconds: 150) { [weak self] in
                self?.refreshPending = 0
                self?.refresh()
            }
        }
    }

    // MARK: Events and effects, on the GTK thread

    private func handle(_ event: PanelMachine.Event) {
        guard !stopped else { return }
        let before = machine.mode
        for effect in machine.handle(event) { apply(effect) }
        if machine.mode != before { modeChanged() }
        publish()
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
            if !wasVisible { style.enter(view.surfaceWidget) }
            host.present(view.window, mode: mode, display: display)
            if mode == .focused { view.focusField() } else { view.clearFocus() }
            if !wasVisible {
                refresh()
                checkAvailability()
            }
        case .hide:
            host.withdraw(view.window)
            wasActive = false
            view.didHide()
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
                _ = cf_snapshot_png(view.window.cast(), snapshots + "/panel-\(mode.rawValue).png")
            }
        }
    }

    private func state() -> UIState {
        var state = UIState()
        let visible = gtk_widget_get_visible(view.window.cast()) != 0 && machine.mode != .hidden
        state.visible = visible
        state.mode = machine.mode.rawValue
        state.hasFocus = visible && gtk_window_is_active(view.window.cast()) != 0
        state.display = visible ? host.display(of: view.window) ?? machine.display : nil
        state.shortcut = shortcut.state
        return state
    }

    private func describe() -> PanelDescription {
        let state = state()
        return PanelDescription(
            visible: state.visible, mode: state.mode, hasFocus: state.hasFocus, display: state.display,
            shortcut: state.shortcut, shortcutTrigger: shortcut.trigger, desktop: host.desktop,
            placement: host.placement(of: view.window), bands: host.triggerDisplays,
            width: Int(gtk_widget_get_width(view.window.cast())), height: Int(gtk_widget_get_height(view.window.cast())),
            reducedMotion: style.reducedMotion, highContrast: style.highContrast, opaque: style.opaqueBackground,
            motion: style.motion, list: view.listMode.rawValue, rows: view.rowTitles, selectedRow: view.selectedIndex,
            field: view.fieldText, sendLabel: view.sendLabel, devices: view.deviceNames, connection: view.connection,
            lastReturn: view.lastReturn, controls: view.controls)
    }

    /// Keeps the agent's copy of the UI state current for anything that reads it there.
    private func publish() {
        let state = state()
        let runtime = runtime
        Task { await runtime.setUIState(state) }
    }

    // MARK: Lists from the agent

    private func refresh() {
        let runtime = runtime, loop = loop
        track(Task { [weak self] in
            async let devices = Self.request([DeviceSummary].self, "devices", runtime)
            async let clipboard = Self.request([ClipboardItem].self, "clip.list", runtime)
            async let history = Self.request([HistoryRecord].self, "history", runtime)
            async let pause = Self.request([String: Bool].self, "clip.pause", runtime)
            let list = (await devices ?? []).map { PanelDevice(id: $0.id, name: $0.name) }
            let items = await clipboard ?? [], records = await history ?? [], paused = await pause?["paused"] ?? false
            guard !Task.isCancelled else { return }
            await loop.perform { [weak self] in
                guard let self, !stopped else { return }
                view.update(devices: list, clipboard: items, history: records, paused: paused)
            }
        })
    }

    /// Device availability is checked when the panel opens, not on a timer.
    private func checkAvailability() {
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

    private func track(_ task: Task<Void, Never>) {
        tasks.removeAll { $0.isCancelled }
        tasks.append(task)
        if tasks.count > 8 { tasks.removeFirst().cancel() }
    }

    private static func request<T: Decodable>(_ type: T.Type, _ command: String, _ runtime: AgentRuntime) async -> T? {
        let response = await runtime.handle(ControlRequest(command))
        guard response.ok else { return nil }
        return try? response.decode(type)
    }

    // MARK: Control commands

    private func register() async {
        await runtime.register("ui.state") { [self] _ in try ControlResponse(value: await loop.perform { self.state() }) }
        await runtime.register("toggle") { [self] _ in
            try ControlResponse(value: await loop.perform { self.handle(.hotkey(display: nil)); return self.state() })
        }
        await runtime.register("ui.invoke") { [self] request in await invoke(request.arguments["action"] ?? "") }
    }

    private func invoke(_ action: String) async -> ControlResponse {
        switch action {
        case "toggle":
            return await reply { self.handle(.hotkey(display: nil)) }
        case "hide":
            return await reply { self.handle(.hide) }
        case "simulate-hover":
            // The pointer resting on the first display's band; answers once the dwell ran.
            return await reply(waitingFor: .hover) { self.handle(.bandEntered(display: self.host.triggerDisplays.first)) }
        case "simulate-leave":
            return await reply(waitingFor: .hidden) { self.handle(.bandLeft); self.handle(.panelLeft) }
        case "simulate-drag":
            return await reply { self.handle(.dragEntered(display: self.host.triggerDisplays.first, onPanel: false)) }
        case "simulate-drag-leave":
            return await reply(waitingFor: .hidden) { self.handle(.dragLeft(onPanel: false)); self.handle(.dragLeft(onPanel: true)) }
        case "simulate-drop":
            return await reply { self.drop([]) }
        case "configure-shortcut":
            let opened = await loop.perform { self.shortcut.configure() }
            return opened ? await reply {} : ControlResponse(failure: "This desktop has no dialog for changing the shortcut.", exitCode: 64)
        case "describe":
            return (try? ControlResponse(value: await loop.perform { self.describe() })) ?? ControlResponse(error: .storage)
        default:
            return ControlResponse(error: .unsupported, exitCode: 64)
        }
    }

    /// Runs `body` on the GTK thread, then answers with the UI state. With `mode`, answers once
    /// the panel reaches it, or after two seconds with whatever state it is in.
    private func reply(waitingFor mode: PanelMode? = nil, _ body: @escaping @Sendable () -> Void) async -> ControlResponse {
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
}

extension PanelApp: PanelActions {
    func send(_ payload: PanelPayload, to device: PanelDevice, keep: Bool) {}
    func attach() {}
    func openSettings() {}

    func setPaused(_ paused: Bool) {
        let runtime = runtime
        track(Task { _ = await runtime.handle(ControlRequest("clip.pause", arguments: ["paused": paused ? "true" : "false"])) })
    }
}
