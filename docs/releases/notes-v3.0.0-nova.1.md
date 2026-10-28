## [3.0.0-nova.1] — the last staged feature, switched on

Market `3.0.0` build `11` (`CFBundleShortVersionString 3.0.0`,
`CFBundleVersion 11`), tag `v3.0.0-nova.1`. Release train `.nova1`.

This stop carries **eighteen of eighteen** staged features. The one that was
still waiting — the **Nova Assistant**, staged since `v1.0.0` — is visible here.
The stop the train scheduled between `1.0.0` and this one (`v2.0.0`, "depth and
fixes") introduces no `ReleaseFeature` of its own, so crossing it holds nothing
back.

The three *never* rows are **not** part of that count and are unchanged by this
release: in-app installation, pairing/JIT/mux, and off-device measurement are
recorded platform limits, not work this stop finished.

Nothing here is a claim about a device. The candidate record in
`docs/releases/private-testing.md` has no row for build 11, and the tag waits
for the private matrix to be run on real hardware.

### Added

- **Nova Assistant** *(visible from `.nova1`)* — `NovaAdvisor` turns the facts
  the stores already hold into at most six suggestions, urgent first and then by
  title. The rules, exactly as the source states them:

  | Suggestion | Severity | The fact behind it |
  |---|---|---|
  | An identity has expired | urgent | `expiresAt` is in the past |
  | An identity expires in *n* days | urgent ≤ 3 days, else attention | inside the 14-day window |
  | No signing identity yet | attention | the library has applications, the identity store has none |
  | A profile has expired | urgent | `expiresAt` is in the past |
  | A profile expires in *n* days | urgent ≤ 3 days, else attention | inside the 14-day window |
  | No provisioning profile yet | attention | identities exist, no profile does |
  | Two applications share a bundle identifier | attention | grouped by `CFBundleIdentifier`, count > 1 |
  | No profile covers an application | attention | no unexpired profile's App ID pattern matches the bundle |
  | A matching profile exists | info | a valid profile's pattern matches |
  | An application was signed successfully before | info | the journal holds a successful run for it |
  | Backup recommended | info | the last backup is seven days old or more |

  Every suggestion carries a destination — certificates, profiles, signing,
  library, or backup — and the Smart Workspace opens the screen that owns the
  work. The advisor is pure and deterministic: same facts and clock, same list
  in the same order. It never signs, never edits, never schedules, and never
  applies anything; the ceiling of six is a design decision, not a backlog. No
  model, no network client, and no telemetry are involved — the facts it reads
  never leave the process.

- **A two-week refresh calendar in the studio.** Each lease is projected onto
  the day it should be signed again — its expiry minus the lead its own account
  implies — and drawn as fourteen cells, empty days included. Late work lands on
  today, work past the window is counted rather than squeezed in, and a run with
  no expiry is listed instead of being given a deadline nobody agreed to. The
  window copies as plain text: app, day to re-sign by, the expiry behind it, and
  the account that signed it.

- **DER entitlements are decoded.** A signature that carries only Apple's DER
  slot (7) now reports its claims instead of "unknown, not empty": the decoder
  parses the grammar the serializer writes, refuses malformed encodings instead
  of returning a partial set, and the Studio names which slot it read. Decoding
  is data, not authorization.

- **Refresh reminders, off until you ask.** One local notification per build on
  the day it should be signed again, nine in the morning, twelve at most. Work
  already due gets none; a run with no expiry gets none; a refusal is accepted
  silently and the countdowns stay. Nothing is transmitted.

- **Zeus**, **the Sideload Studio**, and the **sideloading package work** —
  written since `1.0.0` and released here (their full descriptions are in
  `CHANGELOG.md`). In short: the violet theme a new install opens on; one
  studio screen that derives a lease per signed application from the signing
  journal — the earlier of the profile's and the certificate's expiry — and
  publishes the account limits the studio plans with (a free personal team's
  seven-day profile, three apps installed at once, ten new App IDs a week, and
  the eight services a personal profile cannot carry: Push Notifications,
  iCloud, App Groups, HealthKit, HomeKit, Wallet, CarPlay, NFC); and the
  package editor, the device-bridge protocol, and the in-process guest
  container. Reachable from `Settings → Devices → Sideloading → Sideload Studio`
  and from Home.

### Changed

- **The train crosses `v2.0.0`.** With `3.0.0-nova.1` in the tree every staged
  gate is on: `python3 Scripts/ci/version_claims.py` reports
  `18 staged · 18 on · 0 ahead · 3 never`. The promotion landed in the same
  commit as every claim about it — `CHANGELOG.md`,
  `ZynSign/Application/VersionHistoryCatalog.swift`, the product pages, and the
  `docs/README.md` badge — so no page describes a build that does not exist.

- **`VersionHistoryCatalog` has a newest entry.** `v3.0.0-nova.1`, build 11,
  released 2026-10-28, with the five highlights a person would actually read.
  Build numbers still strictly decrease down the list, and `isCurrent` is
  derived from the train rather than written into the entry.

### Limits — unchanged, and deliberately so

- **In-app installation is not offered.** Stock iOS has no API that installs an
  arbitrary IPA into the system. The Installation Workspace and the delivery
  hand-off hand the person a signed artifact and the materials to install it;
  neither calls a private installer hook, and no row claims one.

- **Pairing, JIT, and mux stay recorded.** A device transport exists as a
  protocol with no implementation in this build. `PairingCapability` composes a
  pairing session only behind an entitled transport, so on a stock device the
  screen reports the missing local-tunnel entitlement instead of failing
  anonymously. JIT is refused where the platform refuses it and mux is not
  attempted. See `docs/architecture/pairing-jit-mux-feasibility.md`.

- **No cloud sync and no off-device measurement.** `AnalyticsPolicy.isEnabled`
  is `false` on every path, the endpoint is `nil`, and the sent-event count is
  zero.

- **No trust claim.** Verification says an artifact is internally coherent — not
  that Apple authorized it, notarized it, or will install it.

### Testing

This change adds no test. The surfaces it makes visible are already covered by
tests that ship in the same binary, and **their verdict belongs to CI** — the
`Build and test (Xcode)` job is the judge:

| Test file | What it pins |
|---|---|
| `Tests/ZynSignTests/NovaTests.swift` | the advisor's expiry window, ordering and limit, its silence with nothing to say, the first-steps nudge, App ID pattern matching, and stable recommendation identity |
| `Tests/ZynSignTests/SideloadLedgerTests.swift` | lease derivation from the journal |
| `Tests/ZynSignTests/SideloadAccountTests.swift` | the account limits the studio plans with |
| `Tests/ZynSignTests/SideloadStudioModelTests.swift` | the studio's own projection |
| `Tests/ZynSignTests/ReleaseTrainTests.swift` | that the gate, the catalogue, and the train agree — including that every `ReleaseFeature` is visible at `.nova1` |

Host audits, run on the machine that produced this note:

| Audit | Result |
|---|---|
| `Scripts/ci/version_claims.py` | `v3.0.0-nova.1 · build 11 · 18 of 18 staged features · 3 never` |

Device rows: **none.** No device class or iOS version has run the Compatibility
Lab, the studio, or the Nova Assistant against this build. No row is filled in
from a simulator run or from a wish.
