# Catflap on macOS

Catflap runs as one background app on macOS 26 or later, on Apple silicon. It has no Dock
icon and no window of its own until you call its panel. Its menu bar item opens the panel
too, and takes files dropped on it.

## Build and install

You need Xcode 26 (its Swift 6.2 toolchain) and Go, for libtailcat.

```sh
scripts/build-libtailcat.sh
packaging/macos/bundle.sh
```

`bundle.sh` makes a release build and writes `build/Catflap.app`:

- `Contents/MacOS/catflap`, the agent and the command line in one executable;
- `Contents/Frameworks/libtailcat.dylib`; the executable finds it there and nowhere else, so the
  app keeps working after the source folder is moved or deleted;
- `Contents/Library/LaunchAgents/io.github.yigityazicilar.Catflap.agent.plist`, used for
  start at login;
- an `Info.plist` for an agent app (no Dock entry) with a "Send with Catflap" Services item.

Copy `Catflap.app` to `/Applications`. Options: `--binary PATH` bundles an executable you built
already, `--output DIR` writes somewhere else, `--configuration debug` makes a debug build.

### Signing and the Keychain

Catflap keeps its device keys in your login keychain (service `Catflap.identity.v1`). macOS
lets only the program that stored them read them back, and it recognises that program by its
signature.

- Set `CATFLAP_SIGN_IDENTITY` to a signing identity from
  `security find-identity -v -p codesigning` before running `bundle.sh`. An Apple Development
  or Developer ID identity keeps the same signature across rebuilds, so a new build reads the
  keys the old one stored.
- Without it the app is signed ad hoc, and `bundle.sh` warns that Keychain access will not
  survive the next rebuild. The next ad-hoc build cannot read the keys.

Catflap never shows a Keychain dialog. A copy that macOS refuses stops with "Cannot access the
device identity.", status -25293 and a sentence explaining why. If that happens after an update
and the old build is gone, open Keychain Access, delete the item named `Catflap.identity.v1`,
start Catflap again and pair your devices again. It makes a new device identity, so the other
devices have to remove the old one.

### First start

Catflap is not notarised. The first time you open it, macOS says it cannot check the app for
malicious software. Open System Settings, Privacy & Security, and choose Open Anyway for
Catflap, or Control-click the app in Finder and choose Open.

Open Catflap.app from Finder (or `open /Applications/Catflap.app`): opened with no arguments,
the app runs the agent. Then switch on Start Catflap at login in its settings (below), and it
starts by itself from then on. The bare executable run with no arguments from Terminal prints
its help instead; `catflap agent` runs the agent there. While the agent runs, opening the app
again (from Finder, Spotlight or `open`) opens its panel with the keyboard in its field; no
second agent starts.

macOS asks once whether Catflap may show notifications, and may ask whether Catflap may read
the clipboard. Clipboard history needs that; without it everything else works.

## The panel

Ctrl+Option+Command+Space (⌃⌥⌘Space) opens the panel at the top centre of the screen with the
keyboard in its field. Resting the pointer on the top edge of the screen opens it without the
keyboard, and dragging a file to the top edge opens it to take the file. Esc, the shortcut again
or a click outside closes it.

- **Send text.** Type and press Return. Typing also filters the list.
- **Send a row.** Arrow keys select a row of the clipboard or history list; Return sends it.
  The send button always says what goes where, for example `Send "meeting notes…" to studio`.
- **Attach files.** The paperclip (⌘O) opens the file picker. ⌘V with files on the clipboard
  attaches them, and so does dropping files on the panel or on the menu bar item. Return sends
  them to the selected device; the first device is the one you sent to last. A file that
  cannot be sent (moved or deleted since, unreadable, too large) does not stop the others: the
  panel's line names it and says why, and it alone stays attached, so Return sends it again.
- **Don't keep** (⌘D): the next sends are recorded in history on both sides without their
  content. A received text that was not kept can be copied for ten minutes. That copy is marked
  concealed on the clipboard, so clipboard managers, Catflap's own history included, leave it
  out; so is the one Put received text on the clipboard makes.
- **Pause** (⌘⇧P): clipboard history records nothing until you resume it.
- **Copy** and **Delete** are on every row of both lists. With a row selected, ⌘C copies it
  and ⌘⌫ deletes it; with no row selected they act on the field as usual. Deleting a history row
  removes the row only: a received file stays in its folder.
- **Retry** and **Reveal** appear on history rows that failed or that hold a received file.
- VoiceOver reads each row's buttons with the row they act on ("Copy meeting notes…"), and
  offers them as actions on the row.
- Under the send button a line says how the last send went: Sending to studio…, Sent to studio.,
  or Not sent to studio. with the reason, in orange.
- The footer says whether the selected device answered when the panel opened: Reachable, Not
  reachable or Checking…. It cannot say whether the connection is direct or relayed: the
  tailcat library Catflap uses does not report the path.

From Finder, select files and choose Services, Send with Catflap: the panel opens with the files
attached and the device you used last selected.

### Send the clipboard

Ctrl+Option+Shift+Command+Space (⌃⌥⇧⌘Space) sends the last thing you copied to the device you
used last, without opening the panel. It sends only a copy clipboard history recorded: right after Catflap starts,
after a copy it skipped as a password, or while history is paused, it sends nothing and a
notification says why. A send that does not arrive raises a notification with Retry.

## Pairing

Open the panel's settings (⌘,) and choose Pair a Device, or use Pair a device in an empty panel.

1. On one device choose Show a Code, then Copy Code. Bring the code to the other device by any
   channel you trust; it is long, and it works once, for ten minutes.
2. On the other device paste it into Pair a Device and choose Join. On Linux,
   `catflap pair join <code>` does the same.
3. Both devices show six digits and the other device's name. If they match, choose They Match on
   both. If they differ, choose They Don't Match: someone else may hold the code.

To remove a device, choose Remove next to it in settings. It is cut off at once.

## Settings

| Setting | Kept in |
| --- | --- |
| The panel's shortcut and the send-clipboard shortcut (record, or Delete to remove) | Catflap's preferences |
| Open the panel on hover, and also over full-screen apps | Catflap's data |
| Put received text on the clipboard (off by default) | Catflap's data |
| Folder for received files (default `Downloads/Catflap`; a change applies from the next start) | Catflap's data |
| Start Catflap at login | macOS, under System Settings, General, Login Items |

All of them survive a restart. Catflap's data lives in `~/Library/Application Support/Catflap/`.

### Shortcuts

The defaults are ⌃⌥⌘Space for the panel and ⌃⌥⇧⌘Space to send the clipboard. Earlier versions
used ⌃⌥Space, which macOS itself uses for Select next source in Input menu once a second input
source is added; a shortcut recorded with an earlier version still applies.

Catflap registers its shortcuts with macOS itself. A combination that one of macOS's own
enabled shortcuts uses (System Settings, Keyboard, Keyboard Shortcuts), or that another app or
Catflap's other shortcut already holds, is not taken: settings show the shortcut in orange as
doing nothing, and `catflap ui state --json` reports it as `conflict` (`shortcut` for the panel,
`send_shortcut` for the other, and `panel_shortcut_state` and `send_shortcut_state` under
`settings`), never as `bound`. Everything else keeps working. Record another combination, or
switch the macOS shortcut off and record this one again, and it works.

## The menu bar item

| Glyph | When |
| --- | --- |
| `cf-idle` | Nothing happening |
| `cf-moving` | A send or a receive is under way |
| `cf-arrived` | For 3 seconds after something arrives or a send gets there |
| `cf-problem` | A send failed; it stays until you next open the panel |
| `cf-paused` | Clipboard history is paused |

`catflap ui state --json` reports the current one as `glyph`, and the panel's line as
`send_line`.

## Notifications

Something arriving raises a notification without sound: Copy for text, Reveal for a file.
Received text goes on the clipboard only when you switch that on. A send that fails while the
panel is closed raises a notification with Retry; while the panel is open its line says it
instead.

## Command line

The app's executable is also the command line:

```sh
alias catflap=/Applications/Catflap.app/Contents/MacOS/catflap
catflap status
catflap version
```

`catflap ui state --json` reports the panel, and `catflap ui invoke <action>` does what a
control in it does: `type`, `select`, `send-text`, `send-clip`, `send`, `send-latest`,
`attach`, `paste`, `copy`, `delete`, `retry`, `reveal`, `dont-keep`, `pause`, `pair`,
`pair-start`, `pair-join`, `pair-copy-code`, `pair-confirm`, `pair-decline`, `settings`, `set`,
`remove`, besides the panel's own `toggle`, `hide` and `simulate-*`. `press` clicks one of the
panel's controls by name (`control`, and `id` for a row's Copy, Delete, Retry or Reveal), and
`simulate-key` presses a key equivalent in the open panel (`key`, `modifiers`). Without arguments an action
uses what the panel shows; scripts that need arguments (`text`, `id`, `files`, `key`, `value`)
send them over the control socket.
