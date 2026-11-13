import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

// This probe enables Shell Eval only in the isolated test container.
export default class Probe extends Extension {
    enable() {
        global.context.unsafe_mode = true;
        this.state = {enabled: true, clips: [], reads: 0, dwell: 0, shortcut: 0};
        global.catflapProbe = this;
        this.Gio = Gio;
        this.GObject = GObject;
        this.GLib = GLib;
        this.Main = Main;
        this.Meta = Meta;
        this.Shell = Shell;
        this.Clutter = Clutter;
        Main.overview.hide();
        this.selection = global.display.get_selection();
        this.transfer = this.selection.transfer_async;
        this.selection.transfer_async = (...args) => {
            this.state.reads++;
            return this.transfer.call(this.selection, ...args);
        };
        this.selectionId = this.selection.connect('owner-changed', (_s, type) => {
            if (type !== Meta.SelectionType.SELECTION_CLIPBOARD)
                return;
            const types = this.selection.get_mimetypes(type);
            const marked = types.includes('x-kde-passwordManagerHint');
            const clip = {types, marked, time: GLib.get_monotonic_time()};
            this.state.clips.push(clip);
            // Inspect the whole offer before choosing a type, regardless of order.
            if (marked)
                return;
            const text = types.find(t => t === 'text/plain;charset=utf-8' || t === 'text/plain');
            if (!text)
                return;
            const stream = Gio.MemoryOutputStream.new_resizable();
            this.selection.transfer_async(type, text, 4 * 1024 * 1024, stream, null, (selection, result) => {
                try {
                    selection.transfer_finish(result);
                    stream.close(null);
                    const bytes = stream.steal_as_bytes();
                    clip.length = bytes.get_size();
                    clip.sha256 = GLib.compute_checksum_for_bytes(GLib.ChecksumType.SHA256, bytes);
                } catch (error) {
                    clip.error = error.message;
                }
            });
        });
        this.windowId = global.display.connect('window-created', (_d, w) => {
            const configure = () => {
                if (w.get_title() !== 'Catflap probe' || this.window === w)
                    return;
                this.window = w;
                w.set_type(Meta.WindowType.DOCK);
                w.hide_from_window_list();
                w.make_above();
                w.stick();
                GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, () => {
                    this.place();
                    return GLib.SOURCE_REMOVE;
                });
            };
            w.connect('notify::title', configure);
            configure();
        });
        this.action = global.display.grab_accelerator('<Control><Alt>space', Meta.KeyBindingFlags.NONE);
        Main.wm.allowKeybinding(Meta.external_binding_name_for_action(this.action), Shell.ActionMode.ALL);
        this.keyId = global.display.connect('accelerator-activated', (_d, action) => {
            if (action === this.action) this.state.shortcut++;
        });
        let entered = 0;
        this.timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 25, () => {
            const [x, y] = global.get_pointer();
            const m = Main.layoutManager.primaryMonitor;
            const inside = x >= m.x + m.width / 2 - 100 && x <= m.x + m.width / 2 + 100 && y < m.y + 4;
            if (!inside) entered = 0;
            else if (!entered) entered = GLib.get_monotonic_time();
            else if (entered > 0 && GLib.get_monotonic_time() - entered >= 200000) {
                this.state.dwell++;
                entered = -1;
            }
            return GLib.SOURCE_CONTINUE;
        });
        this.pointer = global.stage.get_context().get_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
        this.keyboard = global.stage.get_context().get_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    }
    place() {
        const w = this.window;
        const area = Main.layoutManager.getWorkAreaForMonitor(0);
        const r = w.get_frame_rect();
        w.move_frame(false, Math.round(area.x + (area.width - r.width) / 2), area.y);
    }
    focus() { this.window.activate(global.get_current_time()); }
    disable() {
        GLib.source_remove(this.timer);
        this.selection.disconnect(this.selectionId);
        this.selection.transfer_async = this.transfer;
        global.display.disconnect(this.windowId);
        global.display.disconnect(this.keyId);
        global.display.ungrab_accelerator(this.action);
        this.pointer.run_dispose();
        this.keyboard.run_dispose();
        delete global.catflapProbe;
        global.context.unsafe_mode = false;
    }
}
