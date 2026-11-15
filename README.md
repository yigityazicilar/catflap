# Catflap

Catflap is currently a Swift package skeleton, **not a usable transfer app**.
The only implemented command is `catflap version`, which queries the loaded
tailcat C ABI. Tests are package-loading placeholders, not feature tests.

The intended platforms are macOS 26 or later on Apple silicon and Linux on
Wayland (KDE and GNOME). Pairing, transfers, history, clipboard capture, desktop
panels, and installation packages are not implemented yet.

## Build

Requires Swift 6.2 or later, Go 1.27.2 or later, Git, a C compiler, and the
system SQLite development headers. Linux additionally needs GTK4, libadwaita,
gtk4-layer-shell, Wayland client headers and pkg-config. See
[toolchains](docs/toolchains.md) for versions and CI details.

```sh
scripts/build-libtailcat.sh
swift build
swift run catflap version
swift test
```

The first command downloads and builds tailcat from the pinned commit
`e00cdde6ff787f801361ff85ed085775c775d4c5`. Network access is required for
that source and for Go and Swift dependencies. Repeated builds reuse the native
library when its build fingerprint is unchanged. No library-path environment
variable is needed when running in this checkout.

## License

Catflap is [BSD-3-Clause](LICENSE). The copied tailcat header retains its upstream
notice; its license is in [vendor/tailcat/LICENSE](vendor/tailcat/LICENSE).
Dependencies retain their own licenses.
