# Clipboard follow and links

Follow is opt-in and has two independent choices: a sender chooses **Follow my copies to**
one paired device (or off), and each receiver permits that sender to set its clipboard.
Normal sends remain ordinary deliveries. Follow and Open use wire protocol 3's existing
`intent` and `clip_kind`; there is no second transfer protocol.

## Commands

All commands accept `--data-dir` and `--json`. Device arguments accept an id or an
unambiguous, case-insensitive paired-device name.

```sh
catflap follow                         # current target
catflap follow --to <device>
catflap follow --off
catflap follow --device <device>       # target, sender permission and link policy
catflap follow --device <device> --permission unset
catflap follow --device <device> --permission allowed
catflap follow --device <device> --permission refused
catflap follow --device <device> --open-links ask
catflap follow --device <device> --open-links always
catflap follow --pending
catflap follow --answer <prompt-id> --allow
catflap follow --answer <prompt-id> --refuse
catflap open --from <sender> <received-item-id>
catflap open --to <device> --url https://example.org/
catflap open --to <device> --url https://example.org/ --dont-keep
catflap clip filter
catflap clip filter --on
catflap clip filter --off
```

`open --to` starts a normal transfer with the Open intent and prints its batch. It does
not wait for someone to answer the receiver's question. Inspect the transfer with
`transfers show`. Follow does not enqueue a backlog of copies for an absent device.

## Capture, privacy and loops

The default `clipboard.filter_secrets` setting is on. Its settings label is **Skip things
that look like secrets**, with **Password managers' copies are always skipped.** underneath.
Off skips only the content detector. Password-manager markers, frontmost-password-manager,
pause and size gates still precede the content reader. A marked copy is never read,
recorded or offered Keep, regardless of this setting.

Known provider formats are checked before exemptions. Whole one-case hex digests of 40,
64 or 128 digits (optionally their matching `sha1:`, `sha256:` or `sha512:` prefix), UUIDs,
version strings and word-like versioned/acronym identifiers are not treated as secrets just
for their entropy. This is best-effort detection, not a promise that all keys are found.
An unmarked filtered item can still be explicitly kept.

`ClipboardFilterWorker` uses a serial utility queue, not the store actor or the cooperative
executor, with one running detector and one replaceable newest pending job. Superseded work
cannot commit or become the pending Keep item. A generation gate and the persisted pause
and filter policy are checked inside the same store transaction as the content write.
A skipped item leaves no body or identifier in the database or a temporary file. The newest
copy is pending while read/filter work runs; Send Latest never falls back to an older row.

A recorded local copy calls the follow handler only after all capture gates and the commit.
A platform origin marker suppresses onward follow even if its payload is malformed or its
sender is unknown. This also blocks forwarding to a third device, not just back to the sender.
Known origins appear as `followed_from` in clipboard results/items and survive history reads
through the additive `clipboard_origins` metadata table, created by the schema-v3 migration.
Fresh stores and v1/v2 stores finish at v3; existing rows and settings are preserved, and
`status.schema_version` reports 3. Corrupt and future-schema stores are refused. There is no
destructive down-migration for this unreleased product. An origin's `keep:false` never
places its body in clipboard history. Keep on a filtered origin copy also never follows it on.
Origin is loop metadata, never authentication or permission.

## Receiver permissions

Permission is `unset` by default, independently per sender. Unset holds only the newest
verified body for that sender in memory, with a ten-minute deadline starting at the first
question; replacement does not extend the deadline. There is one question per sender per
agent lifetime until answered; explicitly resetting permission to `unset` re-arms the
question for a later copy. Receipt metadata can exist in transfer history while held,
but neither a held text body nor a held image reaches SQLite or disk. A restart forgets it.
There are at most 32 pending sender/intent entries.

Allowed writes through the platform hook with an origin marker. Refused records receipt
but never writes the clipboard. Answering either way retains the body only when Keep was
selected; otherwise the ordinary memory-only received-copy lifetime applies. Expired or
replaced unanswered bodies are not retroactively recovered. Explicitly choosing allowed
when no held item remains applies to subsequent copies.

## URLs

`LinkNormalizer.normalize` is the only gateway to the opener. It accepts one absolute
HTTP or HTTPS URL, lowercases the scheme and host, and removes the default port. One
terminating LF from a shell copy is removed. Embedded whitespace, other controls (including
percent-encoded controls), userinfo, backslashes, absent hosts, invalid ports, other schemes,
multiple URLs and input over 8 KiB are refused. URLs handed to the platform are the core's
normalised URL, never the sender's unchecked text.

Received URL rows have `openable:true` in `transfers.get` and `transfers.list`, including
memory-only received text while available. Lists still contain previews, never bodies.
Open defaults to asking per device. `always` removes that question for future requests;
it is not a grant to open other schemes. A refusal or expired question never invokes the
opener. A new Open request supersedes the previous unanswered request from that sender,
with a new prompt id and its own displayed normalised URL.

## Desktop integration contract

The agent installs and provides `FollowService`. After the platform has started, retrieve
it with `await runtime.service(FollowService.self)` and call `await service.setPlatform(adapter)`.
The adapter implements the `Sendable` protocol `FollowPlatform`:

- `writeClipboard(_:origin:) async throws`: write the content and origin in the **same**
  clipboard offer. Respect `origin.keep` and existing don't-keep concealment policy.
- `requestPermission(_ prompt: FollowPrompt) async`: present the question and return promptly,
  **without waiting for the person's answer**. `kind` is `follow` or `open`; the prompt carries
  `id`, `device_id`, `expires_at`, and an Open question's normalised `url`. Resolve the device's
  display name using the paired-device summary, not the marker payload.
- `openURL(_ url: URL) async throws`: invoke the platform browser opener, never a shell command.

Return an answer through `FollowService.answer(id:allow:)` or `follow.answer`. A Follow answer
sets the sender's allowed/refused permission. An Open answer applies to that single question,
not the device's future policy. Clear the hook with `setPlatform(nil)` during platform teardown;
the agent calls `stop()` to discard held bodies and cancel expiry tasks at shutdown.

Attaching an adapter replays still-live questions, so replace questions by id rather than
stacking duplicate dialogs. Re-read `follow.prompts` when displaying or answering a question:
expired/superseded ids are rejected, and an Open replacement has a new id and URL. Detaching
an adapter does not grant permission or extend a deadline. Do not cache a prompt's body;
Follow questions intentionally contain no clipboard content. `stop()` is terminal for the
agent's lifecycle; do not use it as a panel-close action.

Origin marker types, containing UTF-8 JSON `{ "device_id": "…", "keep": true|false }`:

- macOS private pasteboard type: `org.catflap.clipboard-origin` (`ClipboardOrigin.macType`).
- Linux MIME type: `application/x-catflap-clipboard-origin` (`ClipboardOrigin.linuxType`).

Check raw offered password-manager marker types before reading **any** content or origin
payload. Decode origin metadata only for an otherwise readable offer, then pass all raw types
and `origin:` to `ClipboardHistory.ingest`. Even an undecodable origin marker must remain in
`offeredTypes`, so it still prevents a loop. Do not translate this marker into an ordinary
unmarked local copy.

Control requests have string arguments; responses use snake_case and ISO-8601 dates:

| Command | Arguments | Result |
| --- | --- | --- |
| `follow` | optional `device_id` | `target`, optional `device_id`, `permission`, `open_policy`, `last_failure` |
| `follow.set` | `device_id` **or** `off=true` | target settings |
| `follow.permission` | `device_id`, optional `permission=unset\|allowed\|refused` | device settings |
| `links.policy` | `device_id`, optional `policy=ask\|always` | device settings |
| `follow.prompts` | none | metadata-only array of live questions (Open includes URL) |
| `follow.answer` | `id`, `allow=true\|false` | `answered:true` |
| `open` | `device_id`, received transfer `id` | `requested:true` (may await a question, not a browser) |
| `clip.filter` | optional `filter_secrets=true\|false` | `filter_secrets` boolean |
| `transfers.send` | existing arguments, `intent=open` | existing transfer batch |

Platform failures do not undo verified receipt. `follow` exposes a fixed, content-free
`last_failure`; platform exception values are never copied into it. A headless test adapter is
available only when both `CATFLAP_PLATFORM=off` and `CATFLAP_TEST_FOLLOW_PLATFORM=1` are set.
It implements the same hooks, simulates an origin-marked watcher event, and records opener
calls without touching a clipboard or browser. This is integration evidence, not proof of
either desktop adapter: macOS and Linux implement and exercise those in their own suites.
