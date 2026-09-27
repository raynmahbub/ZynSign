# Release blockers

## Severity policy

The classification exists so release decisions stay consistent: the action a
level demands is written once, and the Lab, the checklist and the release notes
all read the same answer.

| Severity | Action | Blocks |
|---|---|---|
| **Critical** | Block the release candidate | This candidate |
| **High** | Fix before RC 2 | The next candidate |
| **Medium** | Fix during the RC cycle | — |
| **Low** | Can wait for 1.0.x | — |

What qualifies, so two people classify alike:

- **Critical** — a core workflow cannot complete, data is lost or corrupted, or
  signing material is exposed.
- **High** — a major workflow fails or is unreachable, and no workaround
  completes it.
- **Medium** — a workflow completes but degrades, or a bounded edge case
  misbehaves.
- **Low** — cosmetic, rare, or a limitation ZynSign already documents honestly.

An accessibility issue that breaks a core workflow is `High` at minimum, and
`Critical` when there is no other route through the workflow.

## The registry

`ReleaseBlockerRecord.registry` — the records ZynSign ships with, shown in the
Lab under *Tracked limitations*. Every entry names what ZynSign does instead,
or what the user should do. An entry nobody has to discover twice is the point.

| Record | Severity | State | Disposition |
|---|---|---|---|
| In-app installation has no available mechanism | Low | Accepted | ZynSign builds the OTA manifest, the install link and the QR code and hands off; it never claims an install |
| Device and iOS matrices need physical-device confirmation | Medium | Open | The Lab executes on the device it runs on and records every other row as not run. Run it on each supported device class and iOS version, then import the reports |
| Signing scenarios stop at preparation without signing material | Medium | Open | Scenarios verify the reproducible preparation stages. Executing a real signature needs an identity and a profile on the device |
| Performance figures measured on a simulator are not device figures | Low | Accepted | The report names the device class it ran on; a simulator row is marked as such and never compared against a device benchmark |

## The checklist

Nothing enters RC 2 until every line is a pass or an accepted limitation. Each
item names the checks that settle it and what a failure would cost:

| Item | Severity if failing |
|---|---|
| Import works | Critical |
| Signing works | Critical |
| Verification works | Critical |
| Recovery works | Critical |
| Library works | High |
| Certificates work | High |
| Profiles work | High |
| Export works | High |
| Store works | High |
| Downloads work | High |
| Accessibility passes | High |
| Installation workspace works | Medium |
| Backups work | Medium |
| Performance passes | Medium |

An item is a pass when every check it depends on passed, a warning when the
worst it found was a warning, a failure when any check failed — and **not run**
when a check did not run, or when no check answered at all. The last case is
reported rather than treated as a pass: an item whose identifiers matched
nothing would otherwise be green forever.

## How the verdict is reached

```
Blocked     ← a critical failure is open
Incomplete  ← anything did not run
Ready       ← every checklist item settled
```

The order matters: a critical failure outranks an unrun check in the headline,
and an unrun check outranks a pass in the rollup. Nine passes can never hide
one check that never executed.

## The QA pass a person makes

The Lab executes what a device can execute. The rest is a person with a device,
and the Lab says so for each item rather than filling the gap:

1. Import a real package from Files; cancel one mid-import; import a duplicate
   and resolve it.
2. Sign with a real identity and profile; cancel one mid-run; verify the
   artifact afterwards and confirm the result is a re-read of what ZynSign
   produced.
3. Background ZynSign mid-signing and return; the operation either resumes or
   reports itself as interrupted.
4. Fill the device and confirm the refusal names what it needed; interrupt an
   import at each stage and confirm the library is untouched.
5. Walk every primary screen with VoiceOver at the largest Dynamic Type size.
6. Run the [device matrix](device-compatibility-matrix.md) pass and the
   [scrolling protocol](performance-verification.md).

Record each result as an overlay, in the release notes, or both — with the
device and iOS version it was made on.
