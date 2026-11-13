#!/usr/bin/env python3
"""Synthetic GTK4 client and independent Shell-observation driver."""
import hashlib
import json
import pathlib
import sys
import time
import gi

gi.require_version('Gtk', '4.0')
from gi.repository import Gtk, Gdk, Gio, GLib, GObject

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

def evaluate(code):
    result = bus.call_sync('org.gnome.Shell', '/org/gnome/Shell', 'org.gnome.Shell',
                           'Eval', GLib.Variant('(s)', (code,)), GLib.VariantType('(bs)'),
                           Gio.DBusCallFlags.NONE, 5000, None).unpack()
    if not result[0]:
        raise RuntimeError(result[1] or 'Shell Eval unavailable; extension may not have enabled')
    return json.loads(result[1]) if result[1] else None


def observe(expr):
    return evaluate(expr)


def settle(seconds=.4):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        while GLib.MainContext.default().iteration(False):
            pass
        time.sleep(.005)


class WatchedProvider(Gdk.ContentProvider):
    __gtype_name__ = 'CatflapWatchedProvider'
    def __init__(self, types):
        super().__init__()
        self.types = types
        self.requests = []
    def do_ref_formats(self):
        return Gdk.ContentFormats.new(self.types)
    def do_write_mime_type_async(self, mime, stream, priority, cancellable, callback, data):
        self.requests.append(mime)
        task = Gio.Task.new(self, cancellable, callback, data)
        task.return_boolean(False)
    def do_write_mime_type_finish(self, result):
        return result.propagate_boolean()


labels = ['extension loads and enables', 'clipboard change reports offered types within 1 s',
          'marked clipboard item is never read',
          'GTK4 placement above windows, absent from overview and Alt+Tab',
          'show without focus and focus on request', 'pointer dwell on top band',
          'registered shortcut reported']
results = {}
details = {}
evidence = pathlib.Path('spikes/gnome/evidence')
evidence.mkdir(exist_ok=True)


def check(index, fn):
    try:
        value = fn()
        results[index] = bool(value)
        details[labels[index]] = value
    except Exception as error:
        results[index] = False
        details[labels[index]] = str(error)


Gtk.init()
check(0, lambda: observe('global.catflapProbe.state.enabled') and
      observe('global.catflapProbe.Main.extensionManager.lookup("catflap-probe@localhost").state') == 1)
background = Gtk.Window(title='Other GTK4 window')
background.set_default_size(900, 500)
background.set_child(Gtk.Entry(placeholder_text='Previous keyboard focus'))
background.present()
settle(.8)
clipboard = Gdk.Display.get_default().get_clipboard()

TEXT_TYPE = 'text/plain;charset=utf-8'
MARKER = 'x-kde-passwordManagerHint'
FIXTURE = b'ordinary decision fixture'


def ordinary():
    initial_reads = observe('global.catflapProbe.state.reads')
    initial_clips = len(observe('global.catflapProbe.state.clips'))
    start = time.monotonic()
    clipboard.set_content(Gdk.ContentProvider.new_for_bytes(TEXT_TYPE, GLib.Bytes.new(FIXTURE)))
    while time.monotonic() - start < 1:
        settle(.02)
        clips = observe('global.catflapProbe.state.clips')
        if len(clips) > initial_clips and TEXT_TYPE in clips[-1]['types']:
            details.setdefault('clipboard_latency_ms', round((time.monotonic() - start) * 1000, 2))
            clip = clips[-1]
            if 'error' in clip:
                raise RuntimeError(clip['error'])
            if 'sha256' not in clip:
                continue
            reads = observe('global.catflapProbe.state.reads')
            details['ordinary_read'] = {'before': initial_reads, 'after': reads, 'clip': clip}
            return (not clip['marked'] and reads == initial_reads + 1
                    and clip['length'] == len(FIXTURE)
                    and clip['sha256'] == hashlib.sha256(FIXTURE).hexdigest())
    details['ordinary_timeout_clips'] = observe('global.catflapProbe.state.clips')
    return False
check(1, ordinary)
# An ordinary read failure is itself the decision finding; do not mask it with later cases.
if not results[1]:
    for index, label in enumerate(labels):
        print(('PASS' if results.get(index) else 'FAIL') + ' ' + label, flush=True)
    evidence.joinpath('results.json').write_text(json.dumps(details, indent=2) + '\n')
    sys.exit(1)


def marked():
    cases = []
    details['marked_cases'] = cases
    # GTK/Mutter reverses these raw format lists; assert the observed ordering too.
    for name, offered in [('marker-first', [MARKER, TEXT_TYPE]),
                          ('marker-after-text', [TEXT_TYPE, MARKER])]:
        initial_reads = observe('global.catflapProbe.state.reads')
        initial_clips = len(observe('global.catflapProbe.state.clips'))
        provider = WatchedProvider(list(reversed(offered)))
        clipboard.set_content(provider)
        settle(1.1)
        clips = observe('global.catflapProbe.state.clips')
        clip = clips[-1]
        active_reads = observe('global.catflapProbe.state.reads')
        # Control: block the actual owner-changed observer and make the same offer.
        evaluate("global.catflapProbe.GObject.signal_handler_block(global.catflapProbe.selection,global.catflapProbe.selectionId); ''")
        baseline = WatchedProvider(list(reversed(offered)))
        try:
            clipboard.set_content(baseline)
            settle(1.1)
        finally:
            evaluate("global.catflapProbe.GObject.signal_handler_unblock(global.catflapProbe.selection,global.catflapProbe.selectionId); ''")
        final_reads = observe('global.catflapProbe.state.reads')
        passed = (len(clips) == initial_clips + 1 and clip['types'] == offered
                  and clip['marked'] and 'length' not in clip and 'sha256' not in clip
                  and 'error' not in clip and initial_reads == active_reads == final_reads
                  and provider.requests == baseline.requests)
        cases.append({'name': name, 'clip': clip, 'before_reads': initial_reads,
                      'after_reads': active_reads, 'baseline_reads': final_reads,
                      'provider_requests': provider.requests,
                      'requests_without_observer': baseline.requests, 'passed': passed})
    details['extension_transfer_calls'] = observe('global.catflapProbe.state.reads')
    details['clipboard_events'] = observe('global.catflapProbe.state.clips')
    return all(case['passed'] for case in cases)
check(2, marked)

# An ordinary GTK4 toplevel is created by a client outside Shell.
prior_focus = observe('global.display.focus_window?.get_title()')
panel = Gtk.Window(title='Catflap probe')
panel.set_default_size(420, 240)
panel.set_child(Gtk.Entry(placeholder_text='Catflap decision prototype'))
panel.set_visible(True)
settle(1)


def screenshot(name):
    path = '/repo/spikes/gnome/evidence/' + name + '.png'
    evaluate("(() => {const p=global.catflapProbe;const stream=p.Gio.File.new_for_path(" + json.dumps(path) + ").replace(null,false,p.Gio.FileCreateFlags.REPLACE_DESTINATION,null);new p.Shell.Screenshot().screenshot(false,stream).then(()=>stream.close(null));})(); ''")
    settle(.5)


def placement():
    before = observe('(() => {const w=global.catflapProbe.window;const r=w.get_frame_rect();const a=global.catflapProbe.Main.layoutManager.getWorkAreaForMonitor(0);return {x:r.x,y:r.y,width:r.width,area:{x:a.x,y:a.y,width:a.width},above:w.is_above(),sticky:w.is_on_all_workspaces(),skip:w.is_skip_taskbar(),tab:global.display.get_tab_list(global.catflapProbe.Meta.TabList.NORMAL_ALL,null).includes(w)}})()')
    details['placement'] = before
    screenshot('hover')
    evaluate("global.catflapProbe.Main.overview.show(); ''")
    settle(1)
    screenshot('overview')
    # Inspect the actual overview workspace window clones, not only the skip flag.
    clones = observe('(() => {const views=global.catflapProbe.Main.overview._overview.controls._workspacesDisplay._workspacesViews;return views.flatMap(v=>(v._workspaces??[]).flatMap(w=>(w._windows??[]).map(c=>c.metaWindow?.get_title()??c.meta_window?.get_title()??null)))})()')
    details['overview_clone_titles'] = clones
    evaluate("global.catflapProbe.Main.overview.hide(); ''")
    settle(.5)
    return (before['above'] and before['sticky'] and before['skip'] and not before['tab']
            and abs(before['x'] - (before['area']['x'] + (before['area']['width'] - before['width']) / 2)) <= 1
            and before['y'] == before['area']['y'] and 'Other GTK4 window' in clones and 'Catflap probe' not in clones)

# Capture focus before entering overview, which itself temporarily takes focus.
hover_focus = observe('global.display.focus_window?.get_title()')
check(3, placement)

def focus():
    evaluate("global.catflapProbe.focus(); ''")
    settle(.5)
    focused = observe('global.catflapProbe.window.has_focus()')
    details['focus'] = {'prior': prior_focus, 'hover': hover_focus, 'requested': focused}
    screenshot('focused')
    return prior_focus == 'Other GTK4 window' and hover_focus == prior_focus and focused
check(4, focus)

def dwell():
    evaluate("global.catflapProbe.pointer.notify_absolute_motion(global.catflapProbe.GLib.get_monotonic_time(),100,100); ''")
    settle(.1)
    before = observe('global.catflapProbe.state.dwell')
    evaluate("global.catflapProbe.pointer.notify_absolute_motion(global.catflapProbe.GLib.get_monotonic_time(),640,1); ''")
    start = time.monotonic()
    while time.monotonic() - start < 2:
        settle(.025)
        if observe('global.catflapProbe.state.dwell') > before:
            details['dwell_elapsed_ms'] = round((time.monotonic() - start) * 1000, 2)
            return True
    details['dwell_pointer'] = observe('global.get_pointer()')
    return False
check(5, dwell)

def shortcut():
    evaluate("(() => {let k=global.catflapProbe.keyboard; for (const key of [global.catflapProbe.Clutter.KEY_Control_L,global.catflapProbe.Clutter.KEY_Alt_L,global.catflapProbe.Clutter.KEY_space]) k.notify_keyval(global.catflapProbe.GLib.get_monotonic_time(),key,global.catflapProbe.Clutter.KeyState.PRESSED);})(); ''")
    settle(.1)
    evaluate("(() => {let k=global.catflapProbe.keyboard; for (const key of [global.catflapProbe.Clutter.KEY_space,global.catflapProbe.Clutter.KEY_Alt_L,global.catflapProbe.Clutter.KEY_Control_L]) k.notify_keyval(global.catflapProbe.GLib.get_monotonic_time(),key,global.catflapProbe.Clutter.KeyState.RELEASED);})(); ''")
    settle(.3)
    details['shortcut_action'] = observe('global.catflapProbe.action')
    return observe('global.catflapProbe.state.shortcut') > 0
check(6, shortcut)
for index, label in enumerate(labels):
    print(('PASS' if results.get(index) else 'FAIL') + ' ' + label, flush=True)
evidence.joinpath('results.json').write_text(json.dumps(details, indent=2) + '\n')
panel.destroy()
background.destroy()
sys.exit(0 if all(results.values()) and len(results) == len(labels) else 1)
