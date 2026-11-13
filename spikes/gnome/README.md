# GNOME decision probe

Run `ci/gnome/run.sh spikes/gnome/check.sh`. It launches an independent GTK4 client,
observes the real Shell, injects virtual pointer/keyboard input through Clutter, and
writes synthetic screenshots and measurements to `spikes/gnome/evidence/`.
Each requirement has one PASS/FAIL line; any failure exits nonzero.

The extension changes the GTK toplevel's compositor type to DOCK, hides it from
window lists, sticks it and makes it above. It is still the client's ordinary GTK4
window, not a panel drawn inside Shell. Its initial map does not activate it;
`Meta.Window.activate()` focuses it on request. Actual overview window clones and
the compositor's normal tab list are inspected, with a second GTK window as a
positive control.

The clipboard observer inspects the whole offered MIME list before choosing a
text type. An ordinary copy must cause exactly one instrumented `transfer_async`
call into a memory stream; the client verifies the recorded byte length and
SHA-256 against the independent fixture. Payload bytes never enter `results.json`.
Marked offers are tested in both actual orders (marker first and marker after
text): the transfer count must not change, and marked records must contain
neither length nor hash. Each marked provider also records all requests,
including compositor clipboard persistence. An identical offer with the observer
blocked is the control: its system request list must match. The positive ordinary
read prevents the marked-item check from passing merely because nothing is ever
read. This does not claim that GNOME itself never reads marked items, or implement
payload forwarding to an agent.

The test extension deliberately enables Shell's unsafe Eval endpoint and creates
virtual input devices. **Never install it in a personal session.** It is installed
only in the disposable container user's session. Production code must remove
Eval, virtual input, retained observations and the polling-based test driver.
The extension declares only Shell 51. No real-desktop, multi-display, accessibility
or production agent integration is claimed by this prototype.

`run.sh` uses named container-only volumes `catflap-gnome-51-swift` and
`catflap-gnome-51-native`; override the prefix with `CATFLAP_GNOME_CACHE` for an
independent cache. Neither the host `.build/` nor `build/` is exposed. Before Swift
build/test/run commands, the session builds its own pinned libtailcat. Commands
execute as the calling uid/gid, not root; root only initializes cache ownership.
The host mount-point directories are created as the caller before Docker starts,
including in a fresh checkout. The mounted repository remains writable for test artifacts. `GNOME_REBUILD=1`
rebuilds the image. Arch packages are rolling, while the Swift release is 6.2.1;
the version/extension checks fail rather than silently accepting an untested Shell.
