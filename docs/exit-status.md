# Exit status of `catflap` commands

Commands other than `catflap agent`, `catflap version` and `catflap erase-identity` ask the
running agent over its control channel, a Unix socket in the agent's data folder. With
`--json`, a failure prints one object on standard output,
`{"ok": false, "error": "<sentence>"}`; without it, the sentence goes to standard error. The
exit status is the same either way.

| Status | Meaning |
| --- | --- |
| 0 | Done. |
| 1 | The command failed. The sentence says why: the agent's own refusal, or "Cannot reach the agent control channel." when no agent runs for the folder, its socket refuses the connection or belongs to another account, or the connection closes before any reply. |
| 64 | The command line or its arguments are not valid, or the command is not available. |
| 69 | "The agent did not answer in time." The agent took the request but gave no reply within 60 seconds. It is running and may be busy; try the command again. 69 is `EX_UNAVAILABLE` in `sysexits.h`. |
| 75 | `catflap send`: at least one target device is away and the send waits for it at the door, with none failed. Catflap delivers it when the device answers, for up to 7 days; `catflap transfers list --waiting` lists it. `--now` and `--dont-keep` never wait, so they never give 75. 75 is `EX_TEMPFAIL` in `sysexits.h`. |

## How long a command waits

A command that cannot reach the agent fails at once. Once it has connected to an agent that
belongs to the same account, it waits up to 60 seconds for each next piece of the exchange:
for the agent to take more of the request, and for more of the reply. The agent answers every
command from memory or its local store and carries on with slow work, such as pairing or a
send, after it has replied, so an answer normally takes milliseconds. The wait is there for a
machine so busy that an answer takes seconds, and ends a command that would otherwise wait
for an agent that hangs.
