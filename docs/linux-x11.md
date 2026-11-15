# Catflap on X11 desktops

On an X11 session (Xfce, MATE, Cinnamon, i3, Openbox and other window managers that follow
the EWMH conventions) Catflap shows the same panel, hover band, tray icon, notifications and
clipboard history as on a Wayland desktop with layer-shell. Install and start it as
`docs/linux.md` describes; the X11 tier needs nothing more at run time than GTK 4 on X11,
which every distribution ships. Building it needs the Xlib and XFixes headers (`libx11-dev`
and `libxfixes-dev` on Debian and Ubuntu, `libx11` and `libxfixes` on Arch).

Xfce, MATE and Cinnamon start the agent at login from the autostart entry the install puts
in place. i3 and Openbox do not read autostart entries by themselves: add
`exec --no-startup-id catflap agent` to the i3 configuration, or `catflap agent &` to
Openbox's `autostart` file.

## Which tier runs

Catflap looks at the display the session gives it, never at the desktop's name:

| The session offers | Panel and hover band | Clipboard history | Shortcuts |
| --- | --- | --- | --- |
| A Wayland display with layer-shell | layer-shell | Wayland data-control | the desktop portal |
| A Wayland display without layer-shell | none | data-control if offered | none |
| An X display and no Wayland display | X11 (below) | XFixes | X key grabs |
| Neither | none | none | none |

A Wayland session that also offers an X display for older programs (XWayland) is a Wayland
session: Catflap never uses that X display, so it never draws a panel there or grabs keys from
it. `catflap status` reports the tier as `desktop`: `layer-shell`, `x11` or `unsupported`.

## The panel

The panel is an undecorated window of the utility type. It opens at the top centre of the
monitor the pointer is on, below a panel that reserves the top edge, and asks the window
manager to keep it above other windows and out of the taskbar and the pager. Tiling window
managers such as i3 float utility windows, so the panel is not tiled.

- **Hotkey** (Ctrl+Alt+Space) opens it with the keyboard in the field, also under xfwm4's
  focus-stealing prevention: the panel asks for focus with the timestamp of the key press.
  Esc closes it and the window manager gives the keyboard back to the window that had it.
- **Hover**: resting the pointer at the top centre opens it without the keyboard; it closes
  when the pointer leaves. The band is a 420 by 3 pixel input-only window, one per monitor,
  which draws nothing. Over a full-screen window the band does nothing.
- **File drag**: dropping files on the open panel attaches them, but dragging a file onto the
  band does not open the panel on X11 (the band does not take part in X drag and drop).
- **Tray**: the tray icon opens the panel at the top centre, not in a corner.

## Shortcuts

Catflap grabs its two shortcuts on the root window, the way X desktops bind application
hotkeys:

| Shortcut | Does |
| --- | --- |
| Ctrl+Alt+Space | Shows or hides the panel. |
| Ctrl+Alt+Shift+Space | Sends the newest copy to the device you sent to last. |

They work with Caps Lock, Num Lock and Scroll Lock on, and are grabbed again when the
keyboard layout changes. While the panel has the keyboard, both are grabbed on the panel's
own window instead of the whole screen, so the send shortcut sends from the open panel and
leaves it open. There is no dialog to change them. If another program already holds
one of them, the X server refuses Catflap's grab: `catflap ui state` then reports `shortcut`
as `conflict` (`send_clipboard_shortcut` in `ui invoke describe` for the second one), and
Catflap holds no part of that combination. Free it in the other program, or bind a key of your
own in the window manager to one of these commands:

```sh
catflap toggle                # show or hide the panel
catflap clip send --latest    # send the newest copy
```

For i3, for example:

```
bindsym Ctrl+Mod1+space exec --no-startup-id catflap toggle
bindsym Ctrl+Mod1+Shift+space exec --no-startup-id catflap clip send --latest
```

Only the grabs themselves are tested (see below); the i3 lines are not.

## Clipboard history

XFixes tells Catflap each time another program takes the clipboard, also while Catflap has
no window open. Catflap then asks that program for its list of formats only, and reads the
copy only if none of them is a password manager's marker (`x-kde-passwordManagerHint` and
the other markers Catflap knows). A marked copy is never read or recorded. GTK's own X11
clipboard is not used for this, because it hides that marker from the formats it lists.

The middle-click selection (PRIMARY) is not recorded. On X11, when the program you copied from
quits, the copy goes with it unless a clipboard manager keeps it; Catflap's history still has
it.

X11 lets any program on the display read the clipboard and send input, Catflap included.
That is the X11 security model, not something Catflap can change.

## What is tested

The workflow `.github/workflows/x11.yml` runs `Tests/CatflapLinuxTests/X11` through
`ci/x11/run.sh`, in the image `ci/x11/Dockerfile` builds (Ubuntu 24.04, Swift 6.2.1). Each test
starts its own Xvfb, xfwm4 with focus-stealing prevention on and a session bus, and types and
moves the pointer through XTEST (`xdotool`):

- the hotkey opens the panel focused, kept above, out of the taskbar and pager, at the top
  centre; Esc closes it and the keyboard goes back to the previous window;
- the hotkey still works with Num Lock and Caps Lock on;
- resting on the band opens the panel unfocused, and it closes when the pointer leaves;
- a key combination another program holds is reported as `conflict`;
- a second launch's `panel.show` opens the panel focused, and `ui state` names a list the
  panel could not read;
- a copy in another program is recorded; a copy offered beside the password-manager marker
  is never read (its owner is asked for its formats and nothing else) and not recorded;
- an X display alone gives the `x11` tier, and an X display beside a Wayland display is not
  used.

Run them on your own machine with Docker (no root, nothing written to the checkout):

```sh
DOCKER_BUILDKIT=0 docker build -t catflap-x11-test ci/x11
ci/x11/run.sh
```

On a machine without Xvfb, xfwm4 and xdotool, `swift test` skips these tests; with
`CATFLAP_X11_REQUIRED=1` it fails instead.

Only xfwm4 is exercised. MATE (Marco), Cinnamon (Muffin), i3 and Openbox follow the same EWMH
requests, but their focus and placement rules were not run.
