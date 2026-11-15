# Data-control client

The bundled `ext-data-control-v1.xml` is the protocol source of truth; its copyright and
permission notice are retained. Regenerate the checked-in C bindings from this directory:

```
wayland-scanner client-header ext-data-control-v1.xml ext-data-control-v1-client-protocol.h
wayland-scanner private-code ext-data-control-v1.xml ext-data-control-v1-protocol.c
```

The wrapper has one serial owner, except `cf_dc_cancel`, which only sets an atomic flag and
signals a wake pipe. Both selection waits and payload reads observe that pipe. Reads stop at
the core's limit plus one overflow sentinel byte, or a three-second deadline. No selection
body is requested until the Swift core has inspected the complete raw offered-type list.
Primary selections are not recorded. The first advertised seat supplies clipboard history.

An offer lives from its `data_offer` until the selection that names it is replaced; a primary
selection's offer is destroyed as soon as it is named. A read may end between `data_offer`,
its MIME types and the selection, so an offer no selection has named yet is kept across
dispatches, never pruned. `ClipboardSplitDeliveryTests` plays such split deliveries from a
scripted compositor of its own: each event reaches the client in a read of its own (the
compositor waits until its send queue is empty), for an ordinary offer and for one whose
password-manager marker arrives last. It needs no nested KWin and is never gated.

`LinuxClipboardE2E` launches an isolated headless KWin with a private runtime directory and
session bus. It never connects to the login session. `wl-copy --foreground --sensitive`
provides a real text offer alongside `x-kde-passwordManagerHint`; a client-side protocol
trace asserts the marked offer receives no request. Helpers and agents are stopped and their
temporary files removed, including on failure.

CI gate: when the explicit environment flag `CI=true` is set and `/usr/bin/kwin_wayland` is
not installed, `LinuxClipboardE2E` reports a skip rather than touching the live clipboard.
Without that flag, a missing nested compositor is a test failure. The unsupported-protocol
status test is never gated: it starts a real minimal Wayland server without data-control and
checks `catflap status --json`. It requires the C compiler and `libwayland-server` development
files already provided by the Linux build dependencies.
