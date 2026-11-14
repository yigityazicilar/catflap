# Catflap on Linux

Catflap runs as one agent per machine. On a Wayland desktop whose compositor offers
layer-shell (KDE Plasma 6 is the tested one) the agent also shows the panel, a tray icon,
notifications and the file manager's "Send with Catflap" menu. GNOME needs the Catflap Shell
extension; see `docs/gnome.md`.

## Install

Requirements on the machine that runs it: GTK 4.14 or later, libadwaita 1.5 or later,
gtk4-layer-shell 1.0 or later, SQLite 3, and a Wayland session. To build it you also need the
Swift toolchain (6.2 or later) and Go, as `docs/toolchains.md` describes.

```sh
scripts/build-libtailcat.sh            # once per checkout
packaging/linux/install.sh             # builds a release and installs into ~/.local
```

The script needs no root. It puts the executable, `libtailcat.so` and the Swift runtime
libraries it was linked against into `PREFIX/lib/catflap/`, links `PREFIX/bin/catflap` to it,
and installs `io.github.yigityazicilar.Catflap.desktop` and the icons under `PREFIX/share`.
The installed build finds its libraries beside itself, so it runs with the checkout gone and
no library path set.

| Option | Meaning |
| --- | --- |
| `--prefix DIR` | Install somewhere other than `~/.local`. |
| `--binary PATH` | Install a `catflap` you already built instead of building a release. |
| `--no-autostart` | Do not start Catflap at login. Settings can switch it on later. |
| `--uninstall` | Remove what the install put in the prefix, the autostart entry and the Dolphin menu. History, settings and keys in the data folder stay. |

If `PREFIX/bin` is not on your `PATH`, call `PREFIX/bin/catflap` by its full path. The
desktop entry already does.

The desktop entry matters beyond the menu: the desktop portal binds global shortcuts only for
an application whose desktop file it finds, and it reads the app id
`io.github.yigityazicilar.Catflap` from it.

## Start

Log out and back in, or run `catflap agent`. On first start Plasma asks once whether Catflap
may use its two shortcuts:

| Shortcut | Does |
| --- | --- |
| Ctrl+Alt+Space | Shows or hides the panel, at the top centre, with the keyboard in the field. |
| Ctrl+Alt+Shift+Space | Sends the newest copy to the device you sent to last. |

Change either in Settings, or in System Settings under Shortcuts.

## The panel

Typing filters the list and is also the text to send. The arrow keys select a row. Return
sends the selected row if there is one, otherwise the text; the send button names what it
will send and to which device. Esc clears a selection, then closes the panel.

- **Attach…** opens the system file picker; the files appear under the field. You can also
  drop files on the panel, or paste files you copied in the file manager (Ctrl+V). Return or
  the send button sends them. A dropped file leaves the panel open with the file attached.
- **The row actions** below the list act on the selected row: Copy, Delete, Retry for a send
  that did not arrive, and Show in folder for a file. Ctrl+C (with the field empty) and Delete
  do the same from the keyboard. Deleting a history row leaves a received file in the inbox.
- **Don't keep**, in the footer, sends without either device keeping the text or file name in
  history. The other device holds the text in memory for ten minutes so it can still be
  copied.
- **Pause** stops clipboard history from recording copies.
- **Settings** is the gear in the footer.

Resting the pointer for a moment at the top centre of the screen opens the panel without
taking the keyboard; it closes again when the pointer leaves. Dragging a file there opens it
too. The tray icon opens it in the lower right corner, above Plasma's panel; left and right
click do the same.

The tray icon shows the state: idle, moving (sending or receiving), arrived, paused, and a
problem that needs your attention. Opening the panel sets it back to idle.

## Pairing

Pair each pair of machines once. In the panel open Settings, then **Pair a device…**.

1. On one machine choose **Show a code**, then **Copy code**. The code is several hundred
   characters long; nobody types it. It goes to the clipboard marked as a secret, so
   clipboard histories (Catflap's and Klipper's) skip it.
2. Get the code to the other machine by a channel you already trust, and there choose
   **Enter a code** and paste it. The other machine can be on the command line:
   `catflap pair join <code>`.
3. Both machines show the same six digits in large type, with the other machine's name.
   Choose **They match** on both. If the digits differ, choose **They differ**: nothing is
   stored.

The code works once and for ten minutes.

To remove a device, open Settings, choose **Remove…** beside it and confirm. It can no longer
send to this machine. The other machine still lists this one until it is removed there too;
a send from it then fails with "Cannot reach …", and the panel offers to remove it.

## Receiving

Each arrival raises a quiet notification (low urgency, no sound): Copy for text, Show in
folder for a file. Received text goes on the clipboard only if you switch that on in
Settings. Files land in the inbox folder, `~/Downloads/Catflap` unless Settings names
another.

A send that fails raises a notification that says why, with Retry. This includes sends from
the send-clipboard shortcut and from the file manager. A send from the panel says so in the
panel instead while the panel is open.

The send-clipboard shortcut sends only a copy that clipboard history recorded. If the last
copy was skipped (marked by a password manager, filtered as a likely secret, too large), if
nothing has been copied since Catflap started, or if history is paused, it sends nothing and
the notification gives the reason.

## Sending from Dolphin

Right-click files and choose **Send with Catflap**: one entry per paired device sends each
selected file to it; **Choose in Catflap…** opens the panel with the files attached. Folders
are not sent. The agent writes this menu to
`$XDG_DATA_HOME/kio/servicemenus/io.github.yigityazicilar.Catflap.desktop` and rewrites it
when a device is paired, renamed or removed.

## Settings

| Setting | Default | Kept in |
| --- | --- | --- |
| Show or hide Catflap, Send the newest copy | Ctrl+Alt+Space, Ctrl+Alt+Shift+Space | the desktop's shortcut settings |
| Open from the top edge (hover band) | on | the agent's settings |
| Start at login | on after `install.sh` | `$XDG_CONFIG_HOME/autostart/io.github.yigityazicilar.Catflap.desktop` |
| Put received text on the clipboard | off | the agent's settings |
| Inbox folder | `~/Downloads/Catflap` | the agent's settings; used from the next start |
| Private relay | none | the agent's settings; stored, not yet used (see below) |

**Quit Catflap** at the bottom of Settings stops the agent.

## From the command line

Everything the panel does can be driven with `catflap ui invoke <action>` while the agent
runs, which is how the tests check it:

| Action | Does |
| --- | --- |
| `send-text` | Sends the text in the field. |
| `send-clip` | Sends the selected clipboard row, or the newest. |
| `send` | Presses the send button. |
| `attach` | Opens the file picker. |
| `copy`, `delete` | Act on the selected row; `copy` without a selection copies the newest history row. |
| `pair`, `settings` | Open those pages. |
| `describe` | Prints what the panel shows, as JSON. |

The control channel also takes arguments for these actions (`text`, `files`, `id`, `device`,
`keep`, `code`, `key`, `value`); the command line passes only the action name so far.

## Known limits

- The footer shows whether the selected device answers (Reachable, Not reachable,
  Checking…), not whether the path is direct or relayed: the tailcat library Catflap is built
  on reports no path information.
- The private relay setting is saved but the engine does not use it yet.
- Changing the inbox takes effect when the agent next starts.
- X11 sessions are not supported.
