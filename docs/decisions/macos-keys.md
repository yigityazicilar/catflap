# macOS key storage decision

Decision id: T3. **The device keys stay in the macOS login keychain. The Mac build
is to be signed with a stable identity. A copy of `catflap` that macOS will not let
read the keys is refused at once and never raises a keychain dialog.** The first
two sentences are the project owner's decision; the third is what was built and
measured. All evidence is from GitHub's hosted macOS runner. Nothing here was
measured on a person's Mac.

## Question

The agent is a hidden background process. On macOS it keeps its two tailcat key
pairs in one generic-password item (service `Catflap.identity.v1`). macOS ties
such an item to the program that created it. A rebuilt or updated `catflap` that
is signed ad hoc is a different program to the keychain. What happens when it
reads the item?

## Measurements

Runner image `macos-26-arm64` version 20261028.624, macOS 26.7.2. The test creates
an identity with the built `catflap`, then starts copies of that binary as the
agent on the same data directory and asks each for `status`. The control copy is
the same file at another path. The re-signed copy is that file after
`codesign --force --sign - --identifier dev.catflap.resigned`. `SecurityAgent` is
the process macOS starts to show a keychain dialog; the test looks for it with
`pgrep -x SecurityAgent`. Lines are copied from the runs' logs.

**1. Another program sees the item and cannot delete it** (run 43461848750). The
test process queried and then tried to delete the item the agent had created:

```
test-process Keychain presence: success; found=true
test-process Keychain failure: SecItemDelete; OSStatus=-25244
```

**2. An unmodified copy works; a re-signed copy blocks** (run 43465423947):

```
control copy: started=true; exit=0; first stderr=<none>; OSStatus=none; seconds=0.397; last status exit=0; last status stderr=<none>; last status result=status decoded; SecurityAgent before=false (exit=1)
resigned copy: deadline diagnostics: control.sock=false; SecurityAgent before=false (exit=1); SecurityAgent deadline=true (exit=0)
resigned copy: started=false; exit=15; first stderr=<none>; OSStatus=none; seconds=10.137; last status exit=1; last status stderr=<none>; last status result=failed; SecurityAgent before=false (exit=1)
resigned outcome: blocked
```

A stack sample of the blocked process showed its main thread inside
`SecItemCopyMatching`, `SecItemCopyMatching_osx`, `SecKeychainItemCopyContent`.
Exit 15 is the test ending the process at its deadline.

**3. The query attribute does not prevent the dialog** (run 43467803935). Every
keychain call carried `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`:

```
resigned copy: started=false; exit=15; first stderr=<none>; OSStatus=none; seconds=5.393; last status exit=1; last status stderr=<none>; last status result=failed; control.sock=false; SecurityAgent before=false (exit=1); SecurityAgent after=true (exit=0)
```

**4. The process-wide switch does** (run 43469446445). The agent calls
`SecKeychainSetUserInteractionAllowed(false)` before its first keychain call:

```
resigned copy: started=false; exit=1; first stderr=Cannot access the device identity.; OSStatus=-25293; seconds=0.299; last status exit=1; last status stderr=<none>; last status result=failed; control.sock=false; SecurityAgent before=false (exit=1); SecurityAgent after=false (exit=1)
```

**5. The tree as committed** (run 43474408499). A fresh process that never used
the key store reads the switch while the control copy's agent runs and again after
the refused copy. `0 1` is status 0, interaction allowed. The reader's own control
sets the switch off first and must read `0 0`:

```
reader control: 0 0
fresh process, agent running: 0 1
control copy: started=true; exit=0; first stderr=<none>; OSStatus=none; seconds=0.515; last status exit=0; last status stderr=<none>; last status result=status decoded; control.sock=true; SecurityAgent before=false (exit=1); SecurityAgent after=false (exit=1)
resigned copy: started=false; exit=1; first stderr=Cannot access the device identity.; OSStatus=-25293; seconds=0.281; last status exit=1; last status stderr=<none>; last status result=failed; control.sock=false; SecurityAgent before=false (exit=1); SecurityAgent after=false (exit=1)
resigned copy: stderr: Cannot access the device identity.
resigned copy: stderr: -25293
resigned copy: stderr: macOS refused this copy of Catflap access to its stored keys. A copy signed differently from the one that stored them is refused this way.
fresh process, after refused copy: 0 1
original binary after refusal: same-id=true; cleanup exit=0; identity.json=false
```

A third approach, a time limit around the read on its own thread, was not needed
and was not built.

## What was built

- On macOS the identity store turns keychain dialogs off for its own process on
  first use. Any process that uses the store is switched, a test process included:
  in run 43472036945 the test process, which uses the store in other tests, read
  `test process Keychain interaction: status=0; allowed=false`.
- A refused read ends `catflap agent` with exit status 1 and the three lines
  above. The third line is printed for status -25293 only, the one status this
  cause was measured to produce.
- `catflap erase-identity --data-dir <dir>`, hidden from help, removes the stored
  keys through the program that created them. The end-to-end tests clean up with
  it, because measurement 1 shows a test process cannot.
- `testDifferentlySignedCopyIsRefusedWithoutDialog` runs measurement 5 on every
  macOS CI run.

## Not measured

- A real rebuild. The measured copy is the built binary re-signed ad hoc under a
  different identifier (`dev.catflap.resigned`). A rebuilt binary signed ad hoc
  under its own identifier was not tried.
- Which signing identities keep keychain access across a rebuild. Other projects
  report that an Apple-issued identity (Apple Development or Developer ID) does
  and that a self-signed certificate does not. CI has no signing identity, so
  this project has not measured either.
- A Mac with a logged-in desktop session, or an agent started at login.
- What `erase-identity` returns when a re-signed copy runs it, and so how a
  person recovers after a refusal without the original binary.
- Status -25308 was never observed. It gets the first two lines and no
  explanation.
- That the switch is per process is supported by measurement 5 and by Apple's
  published Security source, which keeps it in a per-process object. No other
  application's behaviour was observed.

## Risks

- `SecKeychainSetUserInteractionAllowed` is deprecated. The compiler says:
  `was deprecated in macOS 10.10: SecKeychain is deprecated`. It works on the
  runner image above. If a later macOS ignores it, the test fails by timing out.
- Until the Mac build is signed with a stable identity, a rebuild is expected to be
  treated like the re-signed copy: refused, with its paired devices unreachable
  from it. Expected from the measurements above, not itself measured.
