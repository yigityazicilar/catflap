import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

// Only ci/gnome/session.sh installs this helper, into a disposable container home.
export default class Observer extends Extension {
    enable() {
        global.context.unsafe_mode = true;
        this.Gio = Gio; this.GLib = GLib; this.Meta = Meta; this.Shell = Shell; this.Main = Main; this.Clutter = Clutter;
        this.reads = 0;
        this.selection = global.display.get_selection();
        this.transfer = this.selection.transfer_async;
        this.selection.transfer_async = (...args) => { this.reads++; return this.transfer.call(this.selection, ...args); };
        this.pointer = global.stage.get_context().get_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
        this.keyboard = global.stage.get_context().get_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        global.catflapTest = this;
        Main.overview.hide();
    }
    focusState(pid) {
        const window = global.get_window_actors().map(actor => actor.meta_window).find(w => w.get_pid() === pid);
        const actor = window?.get_compositor_private();
        const focus = global.display.focus_window;
        return {
            panel_exists: Boolean(window),
            panel_showing: Boolean(window && window.showing_on_its_workspace() && actor?.visible),
            panel_mapped: Boolean(actor?.mapped),
            panel_wm_class: window?.get_wm_class() ?? null,
            panel_app_id: window?.get_gtk_application_id() ?? null,
            panel_shell_app_id: window ? Shell.WindowTracker.get_default().get_window_app(window)?.get_id() ?? null : null,
            focus_wm_class: focus?.get_wm_class() ?? null,
            focus_app_id: focus?.get_gtk_application_id() ?? null,
            demands_attention: window?.demands_attention ?? null,
            urgent: window?.urgent ?? null,
        };
    }
    disable() {
        this.selection.transfer_async = this.transfer;
        this.pointer.run_dispose(); this.keyboard.run_dispose();
        delete global.catflapTest;
        global.context.unsafe_mode = false;
    }
}
