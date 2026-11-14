import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const MARKER = 'x-kde-passwordManagerHint';
const FRAME_LIMIT = 40 * 1024 * 1024;

export default class Catflap extends Extension {
    enable() {
        this._enabled = true;
        this._serial = 0;
        this._token = GLib.get_monotonic_time();
        this._pending = new Map();
        this._signals = [];
        this._actions = [];
        this._bindings = {};
        this._bands = [];
        this._mode = 'hidden';
        this._retryDelay = 250;
        this._selection = global.display.get_selection();
        this._connectSignal(this._selection, 'owner-changed', (_s, type) => {
            if (type === Meta.SelectionType.SELECTION_CLIPBOARD) this._offer();
        });
        this._connectSignal(global.display, 'window-created', (_d, window) => this._manage(window));
        this._connectSignal(Main.layoutManager, 'monitors-changed', () => this._rebuildBands());
        this._connectSignal(global.display, 'in-fullscreen-changed', () => this._rebuildBands());
        this._connectSignal(Main.messageTray._bannerBin, 'notify::visible', () => this._place());
        this._connectSignal(Main.messageTray._bannerBin, 'notify::height', () => this._place());
        this._button = new PanelMenu.Button(0.0, 'Catflap', true);
        this._button.add_child(new St.Icon({gicon: Gio.icon_new_for_string(`${this.path}/catflap-symbolic.svg`), style_class: 'system-status-icon'}));
        this._button.connect('button-press-event', () => {
            this._request('control', {command: 'toggle'}).catch(() => {});
            return Clutter.EVENT_STOP;
        });
        Main.panel.addToStatusArea(this.uuid, this._button);
        this._settings = this.getSettings();
        this._bind('catflap-toggle', 'toggle');
        this._bind('catflap-send-latest', 'send-latest');
        this._rebuildBands();
        this._connect();
    }
    _connectSignal(object, name, callback) {
        this._signals.push([object, object.connect(name, callback)]);
    }
    _bind(key, name) {
        const id = Main.wm.addKeybinding(key, this._settings, Meta.KeyBindingFlags.NONE, Shell.ActionMode.ALL, () => {
            console.log(`catflap keybinding ${this._bindings[name]} -> ${name}`);
            this._request('trigger', {action: name}).catch(() => {});
        });
        console.log(`catflap bind ${name} id=${id}`);
        this._bindings[name] = id;
        if (id !== Meta.KeyBindingAction.NONE) {
            this._actions.push({id, name, key});
        }
    }
    _connect() {
        if (!this._enabled) return;
        const path = GLib.build_filenamev([GLib.get_user_data_dir(), 'catflap', 'session.sock']);
        const client = new Gio.SocketClient();
        client.connect_async(new Gio.UnixSocketAddress({path}), null, (_client, result) => {
            if (!this._enabled) return;
            try {
                const connection = client.connect_finish(result);
                const credentials = connection.get_socket().get_credentials();
                if (credentials.get_unix_user() !== this._uid()) {
                    connection.close(null); throw new Error('owner');
                }
                this._pid = credentials.get_unix_pid();
                this._connection = connection;
                this._cancel = new Gio.Cancellable();
                this._input = new Gio.DataInputStream({base_stream: connection.get_input_stream()});
                this._output = connection.get_output_stream();
                this._queue = [];
                this._queueBytes = 0;
                this._writing = false;
                this._retryDelay = 250;
                this._read();
                this._request('hello', {bindings: JSON.stringify(this._bindings)}).then(() => {
                    for (const actor of global.get_window_actors()) this._manage(actor.meta_window);
                    this._offer();
                }).catch(() => this._lost());
            } catch (_error) { this._scheduleReconnect(); }
        });
    }
    _uid() { return new Gio.Credentials().get_unix_user(); }
    _scheduleReconnect() {
        if (!this._enabled || this._retry) return;
        this._retry = GLib.timeout_add(GLib.PRIORITY_DEFAULT, this._retryDelay, () => {
            this._retry = 0; this._connect(); return GLib.SOURCE_REMOVE;
        });
        this._retryDelay = Math.min(10000, this._retryDelay * 2);
    }
    _lost() {
        this._cancel?.cancel();
        try { this._connection?.close(null); } catch (_error) { /* Already closed. */ }
        this._connection = null;
        this._pid = null;
        this._forgetWindow();
        this._readCancel?.cancel();
        for (const entry of this._pending.values()) entry.reject(new Error('Disconnected'));
        this._pending.clear();
        this._scheduleReconnect();
    }
    _request(command, args = {}) {
        if (!this._connection) return Promise.reject(new Error('Disconnected'));
        const id = String(++this._serial);
        return new Promise((resolve, reject) => {
            this._pending.set(id, {resolve, reject});
            this._send({id, command, arguments: args});
        });
    }
    _send(object) {
        const bytes = new TextEncoder().encode(`${JSON.stringify(object)}\n`);
        if (bytes.length >= FRAME_LIMIT || this._queueBytes + bytes.length > FRAME_LIMIT) { this._lost(); return; }
        this._queue.push(bytes); this._queueBytes += bytes.length;
        this._flush();
    }
    _flush() {
        if (this._writing || !this._connection || !this._queue.length) return;
        this._writing = true;
        const bytes = this._queue.shift();
        const connection = this._connection;
        this._output.write_all_async(bytes, GLib.PRIORITY_DEFAULT, this._cancel, (stream, result) => {
            if (connection !== this._connection) return;
            this._writing = false; this._queueBytes -= bytes.length;
            try { stream.write_all_finish(result); this._flush(); } catch (_error) { this._lost(); }
        });
    }
    _read() {
        const connection = this._connection;
        this._input.read_line_async(GLib.PRIORITY_DEFAULT, this._cancel, (stream, result) => {
            if (connection !== this._connection) return;
            try {
                const [bytes] = stream.read_line_finish(result);
                if (!bytes || bytes.length >= FRAME_LIMIT) throw new Error('Frame');
                const message = JSON.parse(new TextDecoder().decode(bytes));
                if (message.id) {
                    const entry = this._pending.get(message.id);
                    this._pending.delete(message.id);
                    if (entry) message.ok ? entry.resolve(message.payload) : entry.reject(new Error('Request refused'));
                } else if (message.event) this._event(message.event, message.arguments ?? {});
                this._read();
            } catch (_error) { this._lost(); }
        });
    }
    _offer() {
        this._readCancel?.cancel();
        const token = String(++this._token);
        const types = this._selection.get_mimetypes(Meta.SelectionType.SELECTION_CLIPBOARD);
        this._offerTypes = types;
        // Inspect the complete raw offer before any content request, regardless of MIME order.
        if (types.includes(MARKER)) console.log('catflap clipboard marked: no content read');
        if (this._connection) this._request('clipboard.offer', {token, types: JSON.stringify(types)}).catch(() => {});
    }
    _event(event, args) {
        if (event === 'panel') {
            this._mode = args.mode;
            this._display = args.display;
            this._place();
        } else if (event === 'clipboard-read') {
            const types = this._selection.get_mimetypes(Meta.SelectionType.SELECTION_CLIPBOARD);
            if (args.token !== String(this._token) || types.includes(MARKER) || !types.includes(args.mime)) return;
            const limit = Number(args.limit);
            if (!Number.isSafeInteger(limit) || limit < 1 || limit > 20000000) return;
            const stream = Gio.MemoryOutputStream.new_resizable();
            this._readCancel = new Gio.Cancellable();
            console.log('catflap clipboard content read');
            // One extra byte distinguishes exact-limit content from a truncated oversized copy.
            this._selection.transfer_async(Meta.SelectionType.SELECTION_CLIPBOARD, args.mime, limit + 1, stream,
                this._readCancel, (selection, result) => {
                    try {
                        selection.transfer_finish(result); stream.close(null);
                        if (args.token !== String(this._token)) return;
                        this._request('clipboard.data', {token: args.token, content: GLib.base64_encode(stream.steal_as_bytes().get_data())}).catch(() => {});
                    } catch (_error) { this._request('clipboard.data', {token: args.token}).catch(() => {}); }
                });
        } else if (event === 'clipboard-set') {
            const allowed = ['text/plain;charset=utf-8', 'text/uri-list', 'image/png', 'image/jpeg'];
            if (!allowed.includes(args.mime)) return;
            const bytes = new GLib.Bytes(GLib.base64_decode(args.content));
            if (bytes.get_size() > (args.mime.startsWith('image/') ? 20000000 : 4 * 1024 * 1024)) return;
            this._copyProcess?.force_exit();
            this._copyProcess = null;
            if (args.secret === 'true') {
                // GJS cannot implement SelectionSource.read_async, and the native memory
                // source offers one MIME only. wl-copy supplies text plus the secret marker.
                this._copyProcess = Gio.Subprocess.new(['wl-copy', '--foreground', '--sensitive', '--type', args.mime],
                    Gio.SubprocessFlags.STDIN_PIPE | Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
                this._copyProcess.communicate_async(bytes, null, (process, result) => {
                    try { process.communicate_finish(result); } catch (_error) { /* Replaced clipboard owner. */ }
                });
            } else {
                this._source = Meta.SelectionSourceMemory.new(args.mime, bytes);
                this._selection.set_owner(Meta.SelectionType.SELECTION_CLIPBOARD, this._source);
            }
        }
    }
    _manage(window) {
        // The PID comes from the authenticated session socket, never a window title.
        if (!this._pid || window.get_pid() !== this._pid || this._window === window) return;
        if (this._window) return;
        this._window = window;
        window.set_type(Meta.WindowType.DOCK);
        window.hide_from_window_list(); window.make_above(); window.stick();
        const sizeId = window.connect('size-changed', () => this._place());
        const unmanagedId = window.connect('unmanaged', () => this._forgetWindow());
        this._windowSignals = [window, sizeId, unmanagedId];
        GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => { if (this._enabled) this._place(); return GLib.SOURCE_REMOVE; });
    }
    _forgetWindow() {
        if (this._windowSignals) {
            const [window, ...ids] = this._windowSignals;
            for (const id of ids) window.disconnect(id);
        }
        this._windowSignals = null;
        this._window = null;
    }
    _place() {
        const window = this._window;
        if (!window || this._mode === 'hidden') return;
        let monitor = Main.layoutManager.findMonitorForActor(global.stage);
        const pointer = global.get_pointer();
        monitor = Main.layoutManager.monitors.find(m => pointer[0] >= m.x && pointer[0] < m.x + m.width && pointer[1] >= m.y && pointer[1] < m.y + m.height) ?? Main.layoutManager.primaryMonitor;
        const area = Main.layoutManager.getWorkAreaForMonitor(monitor.index);
        const frame = window.get_frame_rect();
        const banner = Main.messageTray._bannerBin;
        const [, bannerY] = banner.get_transformed_position();
        const [, bannerHeight] = banner.get_transformed_size();
        const y = banner.visible ? Math.max(area.y, Math.ceil(bannerY + bannerHeight + 8)) : area.y;
        window.move_frame(false, Math.round(area.x + (area.width - frame.width) / 2), y);
        if (this._mode === 'focused' && !window.has_focus()) window.activate(global.get_current_time());
    }
    _rebuildBands() {
        for (const band of this._bands) { Main.layoutManager.removeChrome(band); band.destroy(); }
        this._bands = [];
        for (const monitor of Main.layoutManager.monitors) {
            const band = new St.Widget({reactive: true, width: 420, height: 3,
                x: Math.round(monitor.x + (monitor.width - 420) / 2), y: monitor.y,
                visible: !monitor.inFullscreen, style: 'background-color: rgba(0,0,0,0.01);'});
            band.connect('enter-event', () => {
                this._request('trigger', {action: 'band-enter', display: String(monitor.index)}).catch(() => {});
                return Clutter.EVENT_PROPAGATE;
            });
            band.connect('leave-event', () => {
                this._request('trigger', {action: 'band-leave'}).catch(() => {});
                return Clutter.EVENT_PROPAGATE;
            });
            Main.layoutManager.addChrome(band, {affectsStruts: false, trackFullscreen: true});
            this._bands.push(band);
        }
    }
    disable() {
        this._enabled = false;
        if (this._retry) { GLib.source_remove(this._retry); this._retry = 0; }
        this._lost();
        for (const [object, id] of this._signals) object.disconnect(id);
        this._signals = [];
        for (const binding of this._actions) Main.wm.removeKeybinding(binding.key);
        this._settings = null;
        for (const band of this._bands) { Main.layoutManager.removeChrome(band); band.destroy(); }
        this._bands = [];
        this._button.destroy();
        // The selection owner must remain valid until another client replaces it.
        this._source = null;
        this._copyProcess?.force_exit();
        this._copyProcess = null;
    }
}
