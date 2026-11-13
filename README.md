# Catflap

Quick transfers between your own machines, without another window getting in the way.

Catflap is a planned Swift app for macOS and Linux, using
[tailcat](https://github.com/tailscale/tailcat) to move text, images, and files
between paired devices.

## Status

Early design and architecture review. There is no application build or release yet.
The features below describe the intended product, not functionality available today.

## Direction

- A small panel summoned with a keyboard shortcut or an optional screen-edge hover.
- Send text, images, and files to a paired machine.
- Searchable, device-local history of sent and received items.
- Optional clipboard history for quickly selecting something to send.
- Native macOS UI following Apple's design guidance, with a Linux desktop interface.
- A shared Swift core and platform-specific desktop integration.

## Privacy goals

Transfers are explicit. Clipboard and transfer histories are intended to stay on
each device, without cloud history sync or telemetry.

Clipboard capture should respect sensitive-content markers and exclude recognized
secrets. Unmarked passwords cannot be identified reliably; capture defaults,
retention, and storage protections are still under review.

Tailcat provides end-to-end encrypted transport, but can use external rendezvous
and relay servers. LAN-only operation and permitted relay use are unresolved design
choices, not guarantees of this repository.

## License

A project license has not been selected yet.
