# Transfers

How Catflap moves text, files, images and folders between paired devices: waiting for a
device that is away, sending to several devices at once, folders, and resuming an
interrupted file. Plan v4 features 2, 5 and 6.

## Sending

```
catflap send --to <device> [--to <device> ...] --text <text>
catflap send --to <device> --file <path> [--file <path> ...]
catflap send --to <device> --folder <path> [--folder <path> ...]
catflap send --to <device> <path> [<path> ...]        # files and folders, as a file manager's %F passes them
catflap send --retry <id> [--to <device>]
```

- `--to` takes a paired device's id or its name (compared case-insensitively). Without it the
  most recently used device is the target. Up to 16 devices and 256 paths in one send.
- Paths given as arguments must be absolute: the agent does not share the command's working
  directory. A path that is a folder is sent as a folder.
- `--dont-keep` sends now and keeps nothing in history: no text, no file name, no hash.
- `--now` sends now or fails: a device that is away does not get a waiting delivery.
- One send gives one transfer per device and payload, each with its own id and outcome. They
  share a `send_id`. With a single device and payload the command prints that transfer; with
  more it prints the batch: `{"send_id", "transfers": [...], "refused": [...]}`.

Exit status (see `exit-status.md`): 0 when every transfer arrived, 75 when at least one waits
for a device that is away and none failed, 1 when any failed, was cancelled or expired. Without
`--json` a waiting transfer adds this line on standard error:

```
Waiting at the door: Device B is away. Catflap delivers it when Device B answers, for up to 7 days.
```

## Waiting deliveries

A kept send to a device that does not answer waits for it:

- The waiting queue lives in the store, so it survives a restart of the agent. A text waits
  as its history row; a file or folder waits by reference, with its size, modification time,
  device and inode, and its SHA-256 (a folder: its whole listing); a clipboard image waits as
  a private copy under the data folder.
- Before each attempt the agent pings the device (at least 3 s per ping). A device that
  answers gets its waiting items, oldest first, at most one attempt at a time per device.
- After a failed attempt the device's items wait 30 s, then 60 s, 120 s, 240 s and 300 s,
  each ±10 %, and stay at 5 minutes. Any sign of the device resets that: a session from it,
  a ping it answers, or a presence check that finds it.
- A file that changed or is gone when its turn comes fails with "The file changed after it
  was queued." or "The file is gone."; Catflap never sends other content than was queued.
- After 7 days a waiting item fails as `expired` ("Not delivered: Device B stayed away for 7
  days.") and the platform module is told, once.
- Refusals that will not change fail at once instead of waiting: too large, an unknown
  device, the wrong device at the address. Busy, no space and a version mismatch wait, with
  the reason in `error`.
- A device whose pairing was not yet confirmed by the other side keeps its items waiting, and
  a failed dial says: "Cannot reach Device B. If it does not list this device, the pairing
  finished on one side only: pair again."

## Folders

A folder is listed first (the row shows phase `preparing`), then offered with its entry count
and the SHA-256 of its listing. The receiver asks for the listing, checks it whole, and only
then accepts payload bytes: the files follow as one stream in listing order.

Limits, checked on both sides: 10,000 entries, 32 levels deep, 180 bytes per name, 1,024 bytes
per path, 4 MiB of listing, and the file size limit for the total. A folder over a limit
fails with the limit's sentence, before any payload.

- Symlinks, special files (FIFOs, sockets, devices) and unreadable entries are skipped. The
  sender's row lists them under `skipped`, each with `path` and `reason` (`symlink`,
  `special`, `unreadable`); the receiver gets none of them.
- Each name component is cleaned on its own; `.`, `..`, empty names, `/`, `\` and NUL are
  refused, control characters are dropped, and names that clash on a case-insensitive disk get
  a number. Nothing is ever overwritten.
- The receiver builds the folder in a hidden staging folder (`.catflap-<recovery id>.staging`)
  with modes 0700 for folders and 0600 for files, checks every file's SHA-256, and publishes
  the folder under its name only when all of it has arrived.

## Resume

A file or folder cut off after some bytes keeps a hidden part in the inbox,
`.catflap-<32 hex digits>.part` (mode 0600), named by an opaque recovery id: a don't-keep
file's name never reaches the database. The receiver syncs the part every 16 MiB and records
how far it got.

When the same device offers the same transfer again (same id, kind, size and SHA-256), the
receiver accepts at the offset it has on disk, hashes what it holds, and the sender sends only
the rest. The whole file is checked at the end; a damaged prefix fails as corrupt and the part
is removed. A part is never continued for another device or other content: that offer starts
from nothing. A part finishes in the inbox it started in, even after the inbox setting
changed. Parts expire after 7 days (`expired`); a sender that cancels or gives up tells the
receiver with `forget`, which removes that device's parts only.

## States

Sent: `sending` (phases `preparing`, `connecting`, `streaming`, `resuming`, `verifying`),
`waiting`, `ok`, `failed`, `unconfirmed` (the end of the send was not acknowledged; it may
have arrived, and Retry never makes a second copy), `cancelled`, `expired`.

Received: `receiving`, `interrupted` (a part is kept for a resume), `ok`, `failed`,
`cancelled`, `expired`.

`can_retry` is true for sent rows that failed, are unconfirmed, cancelled or expired;
`can_cancel` for sent rows that are sending or waiting, and received rows that are
interrupted.

## Listing, cancelling, retrying

```
catflap transfers list [--waiting | --active | --all] [--to <device>] [--search <text>] [--limit <n>]
catflap transfers show <id> [--to <device>]
catflap transfers cancel <id> [--to <device>]
catflap transfers cancel --send <send id>
catflap transfers retry <id> [--to <device>]          # a waiting transfer is tried now
catflap inbox [--set <folder>]
catflap devices
```

Lists carry previews (at most 200 characters of a text), never bodies; `show` gives one
transfer whole. A new inbox applies to the next transfer at once, no restart. An existing folder
chosen as inbox keeps its mode, but must belong to the person and not be writable by group or
others; a folder Catflap creates gets 0700.

`catflap devices` prints one line per paired device, for example `Device B — here · direct ·
12 ms`, `Device B — here · via relay fra · 40 ms`, `Device B — away`, and says when the other
device runs another Catflap or has not confirmed the pairing. With `--json` each device has
`peer_state` (`ok`, `update_peer`, `update_this_device`, `wrong_device`), `confirmed`, and
`presence`. Never an address or endpoint.

A new pairing is `confirmed` only after an authenticated session with the other device, which
only a device that stored the pairing can open or answer. A ping answer does not confirm it: the
other device also answers a key that is only pending during a pairing it may never finish.

## Control commands

All payloads are snake_case with ISO-8601 times. Multi-value arguments are newline-separated.

| Command | Arguments | Reply |
| --- | --- | --- |
| `transfers.send` | `device_ids`, one of `text` / `files` / `folders` / `clip_id`; `keep`, `wait` (`true`/`false`), `intent` (`deliver`, `open`) | `{send_id, transfers, refused}` |
| `transfers.list` | `status` (`waiting`, `active`, `done`, `all`, comma-separated), `device_id`, `direction`, `search`, `limit` (1–500), `before` | `{items, next_before}`, items with `preview` in place of `text` |
| `transfers.get` | `device_id`, `id` | one transfer, whole |
| `transfers.cancel` | `device_id` and `id`, or `send_id` | `{cancelled, not_cancelled}` |
| `transfers.retry` | `device_id`, `id` | the transfer |
| `inbox` | — | `{directory, is_default, exists}` |
| `inbox.set` | `directory` (absolute) | the same |
| `devices` | — | paired devices with `peer_state`, `confirmed`, `presence` |
| `status` | — | includes `schema_version` |

The older `send` and `send.status` commands stay for the panels until they move to
`transfers.send` and `transfers.get`; `send` never waits.

## Wire protocol 3

A connection starts with Open: `hello` → `challenge` → `auth` → `ok`, where `ok` carries the
accepter's own proof of the pairing secret, so the dialer never hands a transfer to another
device holding the address. Peers of another protocol version get `mismatch` with their
version and build, and the message names the side to update ("Update Catflap on Device B", or
"Update Catflap on this device: Device A runs a newer Catflap").

A transfer is: `forget`? → `offer` → `hold`* → (`want_manifest`, `manifest`*, `manifest_end`
for a folder) → `accept {offset}` or `reject {reason}` → payload from the offset → `done` or
`abort` → `ack` or `reject`. Every change to a frame's fields bumps `WireProtocol.version`; a
test pins each version's frame shapes.

## Storage

Store schema 2 adds, to schema 1: history columns `send_id`, `mime`, `intent`, `clip_kind`,
`recovery_id`, `error`, `entries`, `skipped`, `updated_at`; the tables `queue` (waiting items),
`parts` (parts of interrupted receives), `device_state` (`peer_state`, `confirmed`) and the
ids to `forget`. A schema 1 store migrates on open and keeps every row.

`catflap audit` scans part files and staged folders in every inbox that holds one, kept image
copies under `sent-images/`, and folder listings under `outbox/`; a part folder it cannot read
makes the audit incomplete, not clean.
