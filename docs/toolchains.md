# Toolchains and native libraries

## Versions

The package manifest requires Swift tools 6.2 and Swift 6 language mode, including
Tailcat and CatflapCore. Deployment is macOS 26 or later, Apple silicon; Linux
integration targets Wayland KDE and GNOME. This is a skeleton, not a claim that
those desktop integrations work yet.

Local skeleton verification uses Swift 6.4.2 and Go 1.27.3 on Linux x86_64.
The native development packages report GTK 4.24.1, libadwaita 1.10.0,
gtk4-layer-shell 1.3.0, wayland-client 1.26.0 and SQLite 3.54.1.

CI uses Swift 6.2.1 through swift-actions/setup-swift and Go 1.27.3 through
actions/setup-go (both versions observed in the CI logs). Third-party actions
are pinned to the immutable revisions fetched by the initial CI run.

| Job | Runner / architecture | Observed toolchains and native dependencies |
| --- | --- | --- |
| linux | Ubuntu 24.04 / x86_64 | Swift 6.2.1, Go 1.27.3, SQLite 3.45.1, GTK 4.14.5, libadwaita 1.5.0, gtk4-layer-shell 1.0.4, wayland-client 1.22.0 |
| macos | macos-26 / arm64 | Swift 6.2.1, Go 1.27.3, Xcode 26.6 (17F113), system SDK and SQLite |

Linux builds gtk4-layer-shell v1.0.4 from upstream. No GTK dependencies are
built on macOS. Each job prints its actual toolchain versions before building.
SwiftPM resolves all package pins on either host, but KeyboardShortcuts is a
dependency only of the macOS target and is never compiled on Linux.

## tailcat

Upstream: https://github.com/tailscale/tailcat

Pinned commit: `e00cdde6ff787f801361ff85ed085775c775d4c5`, C ABI 1.
Upstream's go.mod requires Go 1.27.2 or later.

`scripts/build-libtailcat.sh` extracts that exact commit into
`.build/tailcat-src`, checks the vendored header against it, and uses upstream's
`build-tags.txt` with `go build -buildmode=c-shared`. Outputs go into `build/lib`:
`libtailcat.so` on Linux or `libtailcat.dylib` on macOS. Both directories are
ignored. The script prints the pinned commit on success and reuses an existing
library when the commit, Go toolchain, target architecture and compiler flags
match its saved fingerprint. Delete `build/lib/build-fingerprint` to force a
rebuild. On macOS the script selects the default Apple C compiler with `xcrun`
and exports the macOS SDK as `SDKROOT` (respecting caller overrides). This keeps
Go's C compilation independent of the downloaded Swift toolchain's header search.
The SDK path is included in the build fingerprint. Builds require a working C
compiler and network access on first use.

The manifest adds `build/lib` as a linker search path and checkout-local runtime
rpath. macOS's dylib install name is changed to `@rpath/libtailcat.dylib`.
Consequently `swift build`, `swift run` and `swift test` need no caller-provided
library-path variable. These rpaths intentionally support development only;
staged installation and relocatable app bundles are not implemented yet.
`catflap version` calls `tc_abi_version()` from the loaded library, not a
hard-coded version constant. The C module's `tailcat.h` is copied unchanged
from the pinned source with its license header intact.

## Target layout

CTailcat and CSQLite expose the tailcat and system SQLite C APIs. SwiftPM accepts
one pkg-config module per system target, so the four Linux system modules are
CGtk, CAdwaita, CGtkLayerShell and CWayland, housed under `Sources/CGtk/`.
CDataControl and CGtkShim are real but empty C targets under `vendor/stubs/`;
their implementation tasks should replace those paths in the manifest when
adding the real C sources. CatflapCore, CatflapMac and CatflapLinux hold
Swift placeholders; Tailcat holds the wrapper described below. Only the host platform's UI module and UI tests are declared.
The executable and cross-platform test modules exist on both hosts.

Apart from TailcatTests, the tests are still trivial package-loading tests, not
network, transfer, UI or privacy verification. Linux CI and macOS CI each run the
native library build, `swift build`, `swift test`, and `swift run catflap version`,
checking for the exact `tailcat-abi 1` line.

## Tailcat wrapper and its tests

The `Tailcat` module runs every blocking C call on a thread of its own with a
fresh cancellation token. Cancelling the Swift task signals that token and the
caller resumes only after the C call has returned; a handle that arrives after
cancellation is closed by the wrapper. Every wrapper object has an async
`close()` that runs `tc_close` on a separate thread. Error text is scrubbed of
addresses, keys and IP literals before it is stored.

`swift test --filter TailcatTests` runs eight tests in one serialized suite (they
share test-only hooks). They open real tunnels through tailcat's public relays,
so they need internet access and take about 30 seconds; the unlisted-key case
waits for its 15-second dial timeout. They run unconditionally on the Linux and
macOS CI jobs: no environment flag skips them.

In repeated dials between a server and a client in one process, meeting through
the public relays, some dials went unanswered until their deadline: between
none and five in a thousand, depending on the run. It also happened when calling
the C API directly, without this wrapper. The cause is not known. Relay
throttling, a switch from a relayed to a direct path, and both ends sharing one
host have not been ruled out, and no measurement used two separate machines.
Test setup retries such a dial, and callers of `dial` should use a finite
timeout and retry.
