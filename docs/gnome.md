# GNOME integration

This integration is **not ready for release**. The container has exercised a real
extension session, the shared GTK panel, ordinary clipboard capture and marked-copy
refusal. The end-to-end scenario currently fails when invoking the registered
shortcut after hiding the panel. Do not treat a loaded extension or connected
status as evidence that every desktop action works.

## Installation

The agent needs the same native Linux libraries as the KDE build, GNOME Shell 51,
and `wl-clipboard` for copies that need the password-manager marker. The extension
is JavaScript and needs no JavaScript build. The installer uses Python 3's standard
library to create its zip and `glib-compile-schemas` to compile the two GSettings
keys for Shell 51's schema loader; no additional Python packages are required.

```sh
packaging/linux/install.sh --prefix "$HOME/.local"
```

Only a GNOME session (`XDG_CURRENT_DESKTOP` containing `GNOME`) builds the zip and
installs `catflap@yigityazicilar.github.io` under
`$XDG_DATA_HOME/gnome-shell/extensions/` (default `~/.local/share`). The extension's
directory name equals its metadata UUID. The zip goes under `PREFIX/share/catflap`.
After a fresh login, enable Catflap in GNOME Extensions. The installer does not
silently change the running Shell's extension settings. `--uninstall` removes the
extension, zip and Catflap's own Nautilus scripts subfolder, leaving agent data and
unrelated scripts alone.

## How it works

The shared Linux panel has a `GnomeHost` instead of a layer-shell host. The Shell
extension places its ordinary GTK window above other windows, on all workspaces,
and outside the normal window lists. It gets the agent PID from socket peer
credentials and does not identify a panel by its title. A notification banner
moves the panel below the banner's bottom edge, with an eight-pixel gap; otherwise
the panel sits below the top bar. This banner-placement path has not yet completed
its end-to-end assertion.

The ordinary control socket remains one request per connection. A separate
`session.sock` in the agent's data directory is mode 0600 and verifies the peer's
UID. It carries newline-delimited JSON with request/reply `id` fields and push
`event` fields, without the control protocol's base64 envelope. Binary clipboard
representations use base64 within their content field. Frames and queued writes
are bounded to 40 MiB. Producers enqueue rather than performing socket I/O; a
session that stops reading is closed. A new connection replaces the old one.
The extension retries a missing socket with capped exponential backoff.
Its `hello` reports each shortcut's actual registration id. A connected session alone is
not a successful binding: a missing, malformed or NONE result is `unavailable`;
only a positive registration id is `bound`. Disconnecting clears those results.

`catflap status --json` exposes `desktop` and `extension` (`connected` or `missing`).
Without an extension the command-line engine remains available. Full Wayland
compositor restart, as distinct from extension disable/enable, remains unverified;
it also disconnects GTK's display connection, not just the session socket.

## Clipboard privacy

On each copy the extension inspects the complete raw MIME offer before asking for
content. A marked offer returns without requesting bytes. The agent's existing
clipboard gate must also authorize the read: pause, marker and size checks precede
the `clipboard-read` push. Allowed representations are text, URI lists, PNG and
JPEG. Reads are bounded to one byte beyond the relevant limit, allowing the agent
to reject oversize copies rather than store a truncated body. New offers cancel
old reads; no rejected content is logged or written by the extension.

GNOME itself keeps an in-memory copy of every clipboard item, marked or not, so it
survives its source application closing; Catflap does not read or store marked items.

Copy normally uses Mutter's native in-memory selection source. GJS cannot override
its asynchronous read virtual method, and that source advertises one MIME only.
A secret Copy therefore sends its bytes over stdin to `wl-copy --sensitive`, which
also advertises the marker; it never puts the bytes in arguments or a temporary
file. That secret-Copy path still needs end-to-end validation.

## Desktop controls and Files

Defaults are Ctrl+Alt+Space for the panel and Ctrl+Alt+Shift+Space for sending the
newest recorded copy. Shell registers both through `Main.wm.addKeybinding` using
the extension's local `org.gnome.shell.extensions.catflap` GSettings schema.
A top-bar button uses the same panel for either mouse
button, without its own menu. Each display has a top-centre hover band; the shared
panel state machine owns the dwell and leave delays. Shortcut rebinding and a
real external file drag into the band/top-bar button are not implemented in this
revision; the existing panel can still take file drops once open.

The agent maintains an owned `Nautilus/scripts/Catflap` subfolder under the XDG
data directory, with one script per device and `Choose in Catflap…`. The scripts
read `NAUTILUS_SCRIPT_SELECTED_FILE_PATHS`; Choose passes each path through the
CLI's repeatable `ui invoke attach --file` option. Device names are sanitized for
filenames, while shell arguments are quoted and sends address a device by id.
Those script actions have not yet completed their installed end-to-end check.

## Isolated verification

Never run these checks against a personal desktop. `ci/gnome/run.sh` starts a
disposable home, private buses and a headless Wayland Shell inside Docker. It uses
container-only Swift/native build volumes, never the host build caches. Its Arch
packages are pinned to the **2026-11-14 Arch Linux Archive snapshot**. The image
build completed with GNOME Shell **51.1**; metadata declares only major **51**.
Moving the snapshot requires retesting and changing the declared versions together.

```sh
DOCKER_BUILDKIT=0 docker build -t catflap-gnome-test:51 ci/gnome
ci/gnome/run.sh swift test --filter GnomeE2E
```

`GnomeE2E` skips unless `CATFLAP_GNOME_TEST=1`, which the isolated session sets.
Missing prerequisites inside that session fail rather than skip. A separate,
container-only helper extension provides observation and virtual input; it is not
included in the installed zip. Only that helper enables Shell Eval or instruments
read calls. The production extension has neither facility and stores no history.
Set `CATFLAP_GNOME_EVIDENCE` to an artifact directory to preserve compositor
screenshots. The test reports copy latency instead of failing on a two-second
wall-clock bound; twenty-second event waits guard against hangs.

The virtual keyboard positive control first types `a` into a focused independent
GTK entry and prints `KEYS-REACH-CLIENT yes|no`. On Shell 51.1 it reaches that
entry, but the previous raw accelerator registration did not receive the shortcut.
The current scenario retains real evdev-key injection with named Shell bindings;
it does not substitute a direct extension callback for keyboard delivery.

Current evidence: owner-only session/replacement/backpressure tests pass; the
production session and raw-marker clipboard checks pass in Shell 51.1; the full
GnomeE2E remains failing on the shortcut scenario. Send/Copy, extension-disabled
sending, reconnect and banner-placement assertions occur later in that scenario
and have not run to completion. Physical-desktop interaction and accessibility
review remain separate human checks.
