# Install Catflap

## Linux packages

Packages target x86-64 Arch Linux, Ubuntu 26.04 LTS, Debian 13 and Fedora 45.
Ubuntu and Debian packages are built separately against each distribution's
libraries; do not install the Ubuntu build on Debian or an older Ubuntu release.
These recipes and CI artifacts are not a published AUR entry or stable release.
No package is automatically published by the package workflow.

All Linux packages are built with **Swift 6.4.2**, inside their target distro.
Its official Ubuntu 26.04 and Debian 13 toolchains support these distributions;
Fedora uses the official Fedora 41 build, and Arch uses AUR `swift-bin` 6.4.2.
Older Swift 6.2.1 toolchains require native library ABIs absent on newer targets.
The application's regular test CI remains on Swift 6.2.1, matching macOS; package
builds use 6.4.2 consistently and are checked separately in clean runtime images.
The Fedora toolchain's legacy XML provider is a build-only dependency, not a
Catflap runtime requirement.

Package builds select `--build-system native`, which is **deprecated in Swift
6.4.2**. Controlled builds with the same official archive showed the default
build system resolving `swiftc` against the source directory when the toolchain
was outside `/usr`; calling `swift-build` directly or setting `SWIFT_EXEC` did
not help. The native build system succeeded without modifying the toolchain or
putting a compiler symlink in the source tree. This is a deliberate temporary
workaround, to revisit when the default build system handles that layout.

Download the artifact matching your distribution from a successful **Linux
packages** workflow run, extract it, then install with your package manager:

```sh
# Ubuntu 26.04 LTS or Debian 13: use that distribution's artifact
sudo apt install ./catflap_0.1.0_amd64.deb
# Fedora 45
sudo dnf install ./catflap-0.1.0-1*.x86_64.rpm
# Arch, from the verified makepkg artifact
sudo pacman -U ./catflap-0.1.0-1-x86_64.pkg.tar.zst
```

The runtime dependency floor is **gtk4-layer-shell 1.0.4**. GTK 4, libadwaita,
Wayland, X11/Xfixes and SQLite come from your distribution, not bundled copies.
Swift is needed to build, **not to install or run**. Swift runtime libraries and
libtailcat are private to `/usr/lib/catflap`; their runpaths use `$ORIGIN`, not a
build directory or toolchain path. libtailcat is dynamically linked and built
from pinned commit `e00cdde6ff787f801361ff85ed085775c775d4c5`.
`/usr/bin/catflap` is a launcher accepting both `--version` and `version`.

Start the agent with `catflap agent`; `catflap status` checks its control socket.
The system packages do not enable a background service or login startup. Enable
login startup explicitly in your desktop or use the per-user installer below.
See [X11](linux-x11.md) and [wlroots](linux-wlroots.md) for session-specific
capabilities and compositor shortcut bindings. GNOME integration is deferred.

Remove the package using `sudo apt purge catflap`, `sudo dnf remove catflap`, or
`sudo pacman -R catflap`. Stop your agent first. Package removal deletes the
installed payload but deliberately does not erase your history or pairing data.

### Ubuntu 24.04

Ubuntu 24.04 is **not packaged**: its standard repositories do not provide
GTK 4's gtk4-layer-shell. Use the source installation below after providing
compatible native development dependencies, including gtk4-layer-shell >= 1.0.4.
The source installer does not fetch or build these native dependencies for you.
Do not substitute GTK 3's gtk-layer-shell package.

## Build from source

Install Swift >= 6.2, Go >= 1.27.2, Git, a C/C++ toolchain, pkg-config and native
development packages for SQLite, GTK 4, libadwaita, gtk4-layer-shell >= 1.0.4,
Wayland, X11 and Xfixes. Then:

```sh
scripts/build-libtailcat.sh
bash packaging/linux/install.sh
# Later, remove installed application files (not personal data):
bash packaging/linux/install.sh --uninstall
```

The default prefix is `~/.local`. `--prefix DIR`, `--binary PATH` and
`--no-autostart` retain their per-user installer behavior. A source build needs
network access for the pinned tailcat revision and Swift/Go dependencies.

## Build the packages

Docker and Python 3 are required on the build host. Each invocation builds in a
new distro container as the invoking user, then installs in a different clean
container with no Swift compiler. Use an empty output directory for each target:

```sh
python3 scripts/package/run.py arch --output build/packages/arch
python3 scripts/package/run.py ubuntu --output build/packages/ubuntu
python3 scripts/package/run.py debian --output build/packages/debian
python3 scripts/package/run.py fedora --output build/packages/fedora
```

The Arch invocation runs `makepkg` against a checksum-verified source tarball.
For a future release-tarball build of `packaging/aur/PKGBUILD`, set
`CATFLAP_SOURCE_SHA256` to the independently reviewed archive checksum; optionally
set `CATFLAP_SOURCE_URL` for a mirror. No release archive checksum is invented
before a release exists. CI supplies the actual snapshot archive and checksum.

All recipes stage the payload through `packaging/linux/install.sh --destdir DIR
--prefix /usr --binary PATH`. The matching `--list` invocation emits the one
installed-file manifest; package tests compare it against staged files and check
every path after removal. Add future file-manager drop-ins to the installer's
payload function once, not to individual package recipes. Dolphin's menu is not
package-owned: the agent generates it per user and rewrites it as devices change.

## Per-user files after package removal

Stop the agent before removing the package. Package managers do not remove files
created later inside your home directory. If present, remove these Catflap files
after uninstalling:

```sh
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/kio/servicemenus/io.github.yigityazicilar.Catflap.desktop"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/io.github.yigityazicilar.Catflap.desktop"
```

The first is Dolphin's dynamic per-device service menu. The second is the login
startup entry, written if you switch autostart on in Settings (or use the default
source installer). Disabling autostart in Settings before removal also removes
that entry. These commands leave history and pairing data untouched.
