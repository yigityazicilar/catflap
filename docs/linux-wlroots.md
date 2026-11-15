# Wayland compositors

Catflap uses layer-shell for the panel and hover band. Clipboard history uses
`ext_data_control_manager_v1` when available, otherwise
`zwlr_data_control_manager_v1`. Selection happens after registry discovery, so
ext wins regardless of advertisement order. No data-control means clipboard
capture is unavailable; Catflap does not substitute a focused-only GTK watcher.
Password-manager markers are checked in the raw offered types before any body
request. PRIMARY is not clipboard history.

The GlobalShortcuts portal is independent of these protocols. If it is absent or
its backend fails, the panel shortcut is `unavailable`, not a permission refusal.
Catflap keeps running and exposes instructions to bind these exact commands:

- `catflap toggle` — show or hide the panel, with keyboard focus when opened.
- `catflap clip send --latest` — send the newest copy to the selected device.

Catflap does not edit compositor configuration. Choose unused chords yourself.
Portal cancellation remains the established `declined` backend state (a person's
refusal); it is distinct from `unavailable`. A working portal keeps its existing
system-managed binding and configuration dialog.

## Binding examples

A newly attached keyboard can send leave/enter for the same panel surface without
an outside click. The wlroots host does not close on that temporary keyboard loss;
it uses foreign-toplevel activation for outside clicks. KDE and X11 retain their
normal keyboard-focus-loss rule.

Foreign-toplevel `done` events may combine an activation and deactivation in one
batch. The listener remembers a rising activation edge until `done`, even when the
window is no longer active by that point, and then clears the remembered edge.

These are configuration examples, not claims that all compositors were run.
Only Ubuntu 24.04 Sway 1.9 is exercised by the mandatory headless CI rig. Its wlr-only
data-control path is intentional; newer Sway also supports ext. The separate KDE
suite continues to exercise ext under nested KWin.

### Sway — exercised in the headless rig

Add to your Sway configuration:

```sway
bindsym Ctrl+Mod1+space exec catflap toggle
bindsym Ctrl+Mod1+s exec catflap clip send --latest
```

The rig injects Ctrl+Alt+Space via `wtype` and runs the real toggle command.
It first checks that an ordinary GTK window gets keyboard focus in that same seat,
then checks the layer-shell panel. On failure it prints the committed keyboard
mode and Sway's seat/tree focus. Released Sway drops on-demand layer focus, so the
wlroots policy keeps the focused panel's keyboard mode `exclusive`. A separate
`zwlr_foreign_toplevel_manager_v1` connection observes another window becoming
activated and sends the existing focus-loss event to close the panel. The click
continues to reach that window; it is not swallowed by an input backdrop.

`ui invoke describe` reports `placement.outside_click` as `foreign-toplevel` when
that global is available, otherwise `escape-or-hotkey`: without it, use Escape or
the hotkey to close the panel. Catflap does not claim general outside-click support
in that case. File pickers use the existing withdraw/return path. Pending Catflap
portal questions release the exclusive keyboard and their completion restores it.
KDE is recognized from its advertised Plasma globals and keeps its existing
on-demand policy; no desktop-name environment variable selects this behavior.
The send binding is an example, not a two-device delivery test.

### Hyprland — documented example, not exercised

A working `xdg-desktop-portal-hyprland` can supply GlobalShortcuts. Alternatively:

```ini
bind = CTRL ALT, SPACE, exec, catflap toggle
bind = CTRL ALT, S, exec, catflap clip send --latest
```

### labwc — documented example, not exercised

Inside the `<keyboard>` section of `rc.xml`:

```xml
<keybind key="C-A-space"><action name="Execute" command="catflap toggle"/></keybind>
<keybind key="C-A-s"><action name="Execute" command="catflap clip send --latest"/></keybind>
```

### river — external window manager required, not exercised

River 0.5 separates the compositor and window manager. The chosen external window
manager must implement river's layer-shell support and own the key bindings.
Bind Ctrl+Alt+Space to `catflap toggle` and Ctrl+Alt+S to
`catflap clip send --latest` in that window manager. There is no universal river
0.5 bind line: an old `riverctl map` example does not configure every new river WM.
An advertised layer-shell global alone does not establish that the panel works.

### niri — documented example, not exercised

Inside `binds`:

```kdl
Ctrl+Alt+Space { spawn "catflap" "toggle"; }
Ctrl+Alt+S { spawn "catflap" "clip" "send" "--latest"; }
```

Stable niri 26.04 has no usable GlobalShortcuts route, even if a GNOME portal
advertises the interface. The newer niri-git implementation is distinct from that
stable release; a backend failure still uses the manual binding path.

### Wayfire — documented example, not exercised

Enable the `command` plugin and add these entries in its section:

```ini
[command]
binding_catflap_toggle = <ctrl> <alt> KEY_SPACE
command_catflap_toggle = catflap toggle
binding_catflap_send = <ctrl> <alt> KEY_S
command_catflap_send = catflap clip send --latest
```

Wayfire 0.11 offers ext as well as wlr data-control. The stock wlr portal does not
provide GlobalShortcuts.

### COSMIC — settings recipe, not exercised

In Settings → Input devices → Keyboard → Keyboard shortcuts → Custom shortcuts,
create Ctrl+Alt+Space with command `catflap toggle`, and Ctrl+Alt+S with command
`catflap clip send --latest`. COSMIC's portal does not provide GlobalShortcuts.
These are custom-shortcut command fields, not a configuration-file syntax.

## Reproduce the isolated rig

```sh
DOCKER_BUILDKIT=0 docker build -t catflap-wlroots ci/wlroots
docker run --rm --user "$(id -u):$(id -g)" \
  --tmpfs /work:exec,uid=$(id -u),gid=$(id -g),mode=0700 \
  -e TMPDIR=/work -v "$PWD:/src:ro" catflap-wlroots
```

No host display, session bus, input device, graphics device or home is mounted.
The rig builds a separate source copy with Swift 6.2.1, creates private Sway and
D-Bus instances per test, uses pixman/headless rendering and removes its tree.
`CATFLAP_WLROOTS_TESTS=1` opts in; without it only the desktop tests skip. Shortcut
state tests run normally everywhere on Linux. Package versions are printed.

The marked-copy fixture is an instrumented wlr data source offering both raw text
and `x-kde-passwordManagerHint`; Ubuntu 24.04's wl-copy lacks `--sensitive`.
The following ordinary copy is the processing barrier. Both client protocol trace
and owner-side payload-request log must show no body request for the marked offer.
A relay also fragments real Sway event traffic at Wayland message boundaries,
waiting for each message to be read before forwarding the next. This exercises
introduced-offer lifetime and marker screening across separate dispatches without
substituting a simulated compositor.

## References

- [Sway bindings](https://man.archlinux.org/man/sway.5.en)
- [Hyprland bindings](https://wiki.hypr.land/Configuring/Binds/)
- [labwc configuration](https://labwc.github.io/labwc-config.5.html)
- [niri configuration](https://github.com/niri-wm/niri/blob/main/resources/default-config.kdl)
- [Wayfire command plugin](https://github.com/WayfireWM/wayfire/wiki/Configuration)
- [GlobalShortcuts portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html)
