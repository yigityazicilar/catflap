#!/usr/bin/env python3
"""Real agents, production extension and an independent GTK clipboard client, container only."""
import base64
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import gi

gi.require_version('Gtk', '4.0')
from gi.repository import Gtk, Gdk, Gio, GLib

assert os.environ.get('CATFLAP_GNOME_TEST') == '1', 'Isolated session required'
EXE = sys.argv[1]
UUID = 'catflap@yigityazicilar.github.io'
root = Path(tempfile.mkdtemp(prefix='gnome-e2e-', dir=os.environ['XDG_RUNTIME_DIR']))
data = Path(os.environ['XDG_DATA_HOME']) / 'catflap'
peer = root / 'peer'
children = []
logs = []
Gtk.init()
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def settle(seconds=.03):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        while GLib.MainContext.default().iteration(False):
            pass
        time.sleep(.003)


def eventually(condition, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        settle()
        value = condition()
        if value:
            return value
    raise AssertionError('Expected state did not arrive before the hang guard')


def evaluate(code):
    ok, result = bus.call_sync('org.gnome.Shell', '/org/gnome/Shell', 'org.gnome.Shell', 'Eval',
        GLib.Variant('(s)', (code,)), GLib.VariantType('(bs)'), Gio.DBusCallFlags.NONE, 20000, None).unpack()
    if not ok:
        raise AssertionError('Test observer evaluation failed: ' + result)
    return json.loads(result) if result else None


def control(command, args=None, target=data):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(20)
        client.connect(str(target / 'control.sock'))
        client.sendall(json.dumps({'command': command, 'arguments': args or {}}).encode() + b'\n')
        result = b''
        while not result.endswith(b'\n'):
            block = client.recv(65536)
            assert block, 'Control socket ended before replying'
            result += block
    envelope = json.loads(result)
    assert envelope['ok'], envelope.get('error', 'Control refusal')
    return json.loads(base64.b64decode(envelope['payload']))


def cli(args, target=data, seconds=60):
    result = subprocess.run([EXE, *args, '--data-dir', str(target), '--json'], capture_output=True, timeout=seconds)
    assert result.returncode == 0, f'CLI {args[0]} exited {result.returncode}'
    return json.loads(result.stdout)


def start(target, desktop):
    env = os.environ.copy()
    env['CATFLAP_PLATFORM'] = 'on' if desktop else 'off'
    env['CATFLAP_PANEL_SNAPSHOT_DIR'] = str(root)
    if not desktop:
        for key in ('WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'DISPLAY', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(key, None)
    log = (root / ('agent.log' if desktop else 'peer.log')).open('wb')
    logs.append(log)
    child = subprocess.Popen([EXE, 'agent', '--data-dir', str(target)], env=env, stdout=log, stderr=log)
    children.append(child)
    eventually(lambda: child.poll() is None and (target / 'control.sock').exists())
    return child


def state():
    return cli(['ui', 'state'])


def invoke(action, **arguments):
    return control('ui.invoke', dict(action=action, **arguments))


def snapshot(name):
    folder = Path('/evidence') if Path('/evidence').is_dir() else root
    path = folder / ('t14-panel-' + name + '.png')
    evaluate("(() => {const p=global.catflapTest;const s=p.Gio.File.new_for_path(" + json.dumps(str(path)) +
             ").replace(null,false,p.Gio.FileCreateFlags.REPLACE_DESTINATION,null);new p.Shell.Screenshot().screenshot(false,s).then(()=>s.close(null));})(); ''")
    eventually(lambda: path.exists() and path.stat().st_size > 0)


def extension(enabled):
    bus.call_sync('org.gnome.Shell.Extensions', '/org/gnome/Shell/Extensions', 'org.gnome.Shell.Extensions',
        'EnableExtension' if enabled else 'DisableExtension', GLib.Variant('(s)', (UUID,)), None,
        Gio.DBusCallFlags.NONE, 20000, None)


try:
    eventually(lambda: evaluate('Boolean(global.catflapTest)'))
    agent = start(data, True)
    status = eventually(lambda: (s if (s := cli(['status'])).get('extension') == 'connected' and s['desktop'] == 'gnome' else None))
    eventually(lambda: state()['shortcut'] == 'bound')
    print('PASS status desktop=gnome extension=connected', flush=True)

    background = Gtk.Window(title='Independent clipboard client')
    background.set_default_size(800, 400)
    entry = Gtk.Entry()
    key_states = []
    key_controller = Gtk.EventControllerKey()
    key_controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
    def on_key_pressed(_controller, keyval, _keycode, modifiers):
        if keyval in (Gdk.KEY_a, Gdk.KEY_A):
            key_states.append({'control': bool(modifiers & Gdk.ModifierType.CONTROL_MASK),
                               'alt': bool(modifiers & Gdk.ModifierType.ALT_MASK)})
        return False
    key_controller.connect('key-pressed', on_key_pressed)
    entry.add_controller(key_controller)
    background.set_child(entry)
    background.present()
    entry.grab_focus()
    eventually(lambda: background.is_active() and background.get_focus() is not None and
               (background.get_focus() is entry or background.get_focus().is_ancestor(entry)))
    eventually(lambda: evaluate(f'global.display.focus_window?.get_pid() === {os.getpid()}'))
    evaluate("global.catflapTest.keyboard.notify_key(global.catflapTest.GLib.get_monotonic_time(),30,global.catflapTest.Clutter.KeyState.PRESSED); ''")
    settle(.05)
    evaluate("global.catflapTest.keyboard.notify_key(global.catflapTest.GLib.get_monotonic_time(),30,global.catflapTest.Clutter.KeyState.RELEASED); ''")
    try:
        eventually(lambda: entry.get_text() == 'a')
        keys_reach_client = True
    except AssertionError:
        keys_reach_client = False
    print('KEYS-REACH-CLIENT ' + ('yes' if keys_reach_client else 'no'), flush=True)
    for label, keys in (('Ctrl+A', [29, 30]), ('Ctrl+Alt+A', [29, 56, 30])):
        key_states.clear()
        evaluate("(() => {const p=global.catflapTest;for(const k of " + json.dumps(keys) + ") p.keyboard.notify_key(p.GLib.get_monotonic_time(),k,p.Clutter.KeyState.PRESSED);})(); ''")
        settle(.05)
        evaluate("(() => {const p=global.catflapTest;for(const k of " + json.dumps(list(reversed(keys))) + ") p.keyboard.notify_key(p.GLib.get_monotonic_time(),k,p.Clutter.KeyState.RELEASED);})(); ''")
        eventually(lambda: key_states)
        observed = key_states[-1]
        print('CLIENT-MODIFIERS chord=' + label + ' control=' + ('yes' if observed['control'] else 'no') +
              ' alt=' + ('yes' if observed['alt'] else 'no'), flush=True)
    clipboard = Gdk.Display.get_default().get_clipboard()
    ordinary = b'an ordinary clipboard line from another client'
    before = evaluate('global.catflapTest.reads')
    began = time.monotonic()
    clipboard.set_content(Gdk.ContentProvider.new_for_bytes('text/plain;charset=utf-8', GLib.Bytes.new(ordinary)))
    eventually(lambda: any(base64.b64decode(row['content']) == ordinary for row in cli(['clip', 'list'])))
    elapsed = (time.monotonic() - began) * 1000
    assert evaluate('global.catflapTest.reads') == before + 1, 'Ordinary positive control must read once'
    print(f'PASS ordinary copy listing latency_ms={elapsed:.2f}', flush=True)

    for marker_first in (True, False):
        before = evaluate('global.catflapTest.reads')
        count = len(cli(['clip', 'list']))
        providers = [Gdk.ContentProvider.new_for_bytes('x-kde-passwordManagerHint', GLib.Bytes.new(b'secret')),
                     Gdk.ContentProvider.new_for_bytes('text/plain;charset=utf-8', GLib.Bytes.new(b'marked synthetic copy'))]
        clipboard.set_content(Gdk.ContentProvider.new_union(providers if marker_first else list(reversed(providers))))
        # A subsequent control request plus observed Shell log supplies an event barrier.
        log = Path(os.environ['XDG_RUNTIME_DIR']) / 'shell.log'
        eventually(lambda: 'catflap clipboard marked: no content read' in log.read_text(errors='replace'))
        settle(.2)
        assert evaluate('global.catflapTest.reads') == before, 'Marked content read'
        assert len(cli(['clip', 'list'])) == count, 'Marked content stored'
    print('PASS marked copies unread and unstored in both MIME orders', flush=True)

    cli(['toggle'])
    eventually(lambda: state()['mode'] == 'focused' and state()['has_focus'])
    snapshot('focused')
    cli(['toggle'])
    eventually(lambda: state()['mode'] == 'hidden')
    # Linux evdev KEY_LEFTCTRL, KEY_LEFTALT, KEY_SPACE reach Mutter's keybinding path.
    evaluate("(() => {const p=global.catflapTest;for(const k of [29,56,57]) p.keyboard.notify_key(p.GLib.get_monotonic_time(),k,p.Clutter.KeyState.PRESSED);})(); ''")
    settle(.05)
    evaluate("(() => {const p=global.catflapTest;for(const k of [57,56,29]) p.keyboard.notify_key(p.GLib.get_monotonic_time(),k,p.Clutter.KeyState.RELEASED);})(); ''")
    try:
        eventually(lambda: state()['mode'] == 'focused' and state()['has_focus'])
    except AssertionError:
        observed = state()
        print('FOCUS-FAIL agent=' + json.dumps({key: observed[key] for key in ('mode', 'visible', 'has_focus')}, sort_keys=True), flush=True)
        print('FOCUS-FAIL shell=' + json.dumps(evaluate(f'global.catflapTest.focusState({agent.pid})'), sort_keys=True), flush=True)
        raise
    print('PASS Shell shortcut reopened focused with keyboard focus', flush=True)
    invoke('hide')
    cli(['ui', 'invoke', 'simulate-hover'])
    eventually(lambda: state()['mode'] == 'hover' and not state()['has_focus'])
    snapshot('hover')
    invoke('hide')
    evaluate("global.catflapTest.pointer.notify_absolute_motion(global.catflapTest.GLib.get_monotonic_time(),100,100); ''")
    settle(.05)
    evaluate("global.catflapTest.pointer.notify_absolute_motion(global.catflapTest.GLib.get_monotonic_time(),640,1); ''")
    eventually(lambda: state()['mode'] == 'hover' and not state()['has_focus'])
    invoke('simulate-drag')
    eventually(lambda: state()['mode'] == 'drag' and not state()['has_focus'])
    snapshot('drag')
    invoke('hide')
    print('PASS toggle and Shell shortcut focused; simulated and real dwell hover without focus', flush=True)

    window = f'global.get_window_actors().map(a=>a.meta_window).find(w=>w.get_pid()==={agent.pid})'
    cli(['toggle'])
    eventually(lambda: state()['has_focus'])
    placement = evaluate(f'(() => {{const w={window};return {{above:w.is_above(),sticky:w.is_on_all_workspaces(),skip:w.is_skip_taskbar(),tab:global.display.get_tab_list(global.catflapTest.Meta.TabList.NORMAL_ALL,null).includes(w)}}}})()')
    assert placement == {'above': True, 'sticky': True, 'skip': True, 'tab': False}, placement
    # Real notification banner: the panel moves below it instead of being covered.
    bus.call_sync('org.freedesktop.Notifications', '/org/freedesktop/Notifications', 'org.freedesktop.Notifications', 'Notify',
        GLib.Variant('(susssasa{sv}i)', ('Fixture', 0, '', 'Synthetic banner', 'Placement fixture', [], {}, 10000)), None,
        Gio.DBusCallFlags.NONE, 20000, None)
    eventually(lambda: evaluate('global.catflapTest.Main.messageTray._bannerBin.visible'))
    eventually(lambda: evaluate(f'(() => {{const b=global.catflapTest.Main.messageTray._bannerBin;return ({window}).get_frame_rect().y>=b.get_transformed_position()[1]+b.get_transformed_size()[1]}})()'))
    snapshot('banner')
    print('PASS authenticated window above, sticky, outside Alt+Tab; panel below notification banner', flush=True)
    invoke('hide')

    start(peer, False)
    code = cli(['pair', 'start'])['code']
    cli(['pair', 'join', code], peer)
    eventually(lambda: cli(['pair', 'status'])['state'] == 'confirm', 60)
    eventually(lambda: cli(['pair', 'status'], peer)['state'] == 'confirm', 60)
    cli(['pair', 'confirm'])
    cli(['pair', 'confirm'], peer)
    eventually(lambda: len(cli(['devices'])) == 1 and len(cli(['devices'], peer)) == 1, 60)
    text = 'sent through the GNOME panel action'
    invoke('send-text', text=text)
    eventually(lambda: any(row.get('text') == text and row['status'] == 'ok' for row in cli(['history'], peer)), 60)
    invoke('copy')
    pasted = []
    clipboard.read_text_async(None, lambda source, result: pasted.append(source.read_text_finish(result)))
    eventually(lambda: pasted)
    assert pasted[0] == text, 'Copy through extension did not reach independent client'
    print('PASS UI send-text reaches peer; Copy through session reaches independent client', flush=True)

    extension(False)
    eventually(lambda: cli(['status']).get('extension') == 'missing')
    cli(['send', '--text', 'send without an extension'])
    eventually(lambda: any(row.get('text') == 'send without an extension' and row['status'] == 'ok' for row in cli(['history'], peer)), 60)
    print('PASS disabled extension reports missing; CLI send still works', flush=True)
    extension(True)
    eventually(lambda: cli(['status']).get('extension') == 'connected')
    assert agent.poll() is None
    print('PASS extension session reconnects after disable/enable', flush=True)
    # A real competing Shell grab must not be reported as a bound Catflap shortcut.
    extension(False)
    eventually(lambda: cli(['status']).get('extension') == 'missing')
    blocker = evaluate("global.display.grab_accelerator('<Control><Alt>space', global.catflapTest.Meta.KeyBindingFlags.NONE)")
    assert blocker != evaluate('global.catflapTest.Meta.KeyBindingAction.NONE'), 'Competing grab must succeed'
    try:
        extension(True)
        eventually(lambda: cli(['status']).get('extension') == 'connected')
        eventually(lambda: state()['shortcut'] == 'unavailable')
        print('PASS failed Shell grab reports unavailable despite connected session', flush=True)
        extension(False)
        eventually(lambda: cli(['status']).get('extension') == 'missing')
    finally:
        evaluate(f"global.display.ungrab_accelerator({blocker}); ''")
    extension(True)
    eventually(lambda: cli(['status']).get('extension') == 'connected' and state()['shortcut'] == 'bound')
    version = subprocess.check_output(['gnome-shell', '--version'], text=True).split()[-1]
    declared = json.loads(Path('gnome-extension/metadata.json').read_text())['shell-version']
    assert declared == [version.split('.')[0]], 'Metadata must declare exactly tested major versions'
    print('PASS declared Shell versions=' + ','.join(declared) + ' tested=' + version, flush=True)
    background.destroy()
except BaseException:
    shell_log = Path(os.environ['XDG_RUNTIME_DIR']) / 'shell.log'
    shell_lines = shell_log.read_text(errors='replace').splitlines() if shell_log.exists() else []
    for prefix in ('catflap bind ', 'catflap accelerator ', 'catflap keybinding '):
        observed = [line[line.index(prefix):] for line in shell_lines if prefix in line]
        print('SHELL-TRACE ' + prefix.strip() + ' count=' + str(len(observed)), flush=True)
        for line in observed:
            print('SHELL-TRACE ' + line, flush=True)
    agent_log = root / 'agent.log'
    agent_lines = agent_log.read_text(errors='replace').splitlines() if agent_log.exists() else []
    for prefix in ('catflap trigger ', 'catflap shortcut activation '):
        observed = [line for line in agent_lines if line.startswith(prefix)]
        print('AGENT-TRACE ' + prefix.strip() + ' count=' + str(len(observed)), flush=True)
        for line in observed:
            print('AGENT-TRACE ' + line, flush=True)
    raise
finally:
    for child in reversed(children):
        if child.poll() is None:
            child.send_signal(signal.SIGTERM)
            try:
                child.wait(timeout=7)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait(timeout=5)
                raise AssertionError('Agent did not stop within seven seconds')
        assert child.returncode == 0, 'Agent failed while running the scenario'
    for log in logs:
        log.close()
    # The entire home/runtime is disposable, but the scenario also cleans its own directories.
    import shutil
    shutil.rmtree(root)
    shutil.rmtree(data, ignore_errors=True)
