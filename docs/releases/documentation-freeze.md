# Documentation freeze preparation

Documentation freezes when it describes what the build actually does. Until
then it is a wish list, and a wish list in a release candidate is how a user
ends up trusting a sentence nobody verified.

This is the freeze checklist for `1.0.0-rc.1`. Every document below was read
against the code in this build; the **State** column says what was found, and
the **Action** column says what still has to happen before the freeze.

## The rule

A document may describe:

- what the code does, verified by reading it or by running it;
- what the code deliberately does not do;
- a check, with its result and the environment it ran in.

A document may **not** describe:

- a feature that is not wired;
- a result nobody measured;
- a capability the platform does not give ZynSign;
- a number nobody can reproduce.

Where a claim depends on a device run, it is written as an instruction to run
the check, not as a result.

## User documentation

| Document | State | Action |
|---|---|---|
| `README.md` | Describes the build, the release train, and the honest limits | Update the release-train row and the hardening section each promotion |
| `docs/releases/notes-v0.1.0.md` | Historical, accurate for `0.1.0` | Leave as history |
| `docs/releases/notes-v1.0.0-rc.1.md` | Written for this candidate, with its limitations listed | Update with real device rows as they arrive |
| `docs/releases/version-strategy.md` | Matches the train | — |
| `docs/releases/private-testing.md` | Matches the private → public gate | — |
| `docs/releases/release-train.md` | Matches `ReleaseTrain.swift` after the `.rc1` promotion | Regenerate the table if the train changes |

## Onboarding

| Surface | State | Action |
|---|---|---|
| First-launch card | Present, and its completion is the only preference that records something the user did | Re-read after the RC: the wording must match the features `.rc1` exposes |
| Empty states | Every primary screen has one, and each says what to do next | — |
| Settings footers | Every section explains itself on its own page (enforced by a test) | — |
| Feature discovery | Sections reached from Settings (Files, App Store, Downloads, Presets) are described in their own footers | — |

## Troubleshooting

| Surface | State |
|---|---|
| `ErrorRecoveryAdvisor` | Every failure answers what happened, what was verified, and what to do next |
| `SigningDiagnosticsView` | Per-issue explanation, consequence, local check, what still depends on iOS, and a recommended next step; the platform boundary is stated on the screen |
| Settings → Recovery | Rebuild library index, reset preferences, and the maintenance actions, each with what it touches and what it never touches |
| Settings → Diagnostics | The technical log's contract, the export, and the guarantees; history carries status and codes only |

The advisor is tested against every case of every typed failure vocabulary, so
a new failure mode that has no advice still produces the category's answer
rather than a blank panel.

## Privacy

| Document | State |
|---|---|
| `SECURITY.md` | Matches the code: no analytics, no telemetry, no crash reporter, no endpoint; the Keychain boundary and the non-extractable key |
| `docs/architecture/analytics-policy.md` *(if present)* | `AnalyticsPolicy.isEnabled == false`, with a local journal the user clears in one tap |
| In-app: Settings → Security Center | Shows the guarantees with their own words |
| In-app: Settings → Diagnostics | Shows what the technical log holds and offers to clear it in one tap |

A privacy statement is a claim about data leaving a device. ZynSign has no
sender, so every one of these documents says so and none of them implies
otherwise.

## Release notes

| File | State |
|---|---|
| `docs/releases/notes-template.md` | The template every release note is written from |
| `docs/releases/notes-v1.0.0-rc.1.md` | Written from the template |
| `CHANGELOG.md` | Carries the same entry |

The template exists because a release note written from memory omits the
limitations. The template has a section for them, and it is not optional.

## Validation documentation

| Pack | State |
|---|---|
| `docs/hardening/` | Twelve documents, each describing what the Lab executes and what it does not |
| `docs/testing/README.md` | States the strategy, and — honestly — what has not been executed |
| `docs/development/continuous-integration.md` | Lists every job and what each establishes or refuses |

## Before the freeze

1. Run the Compatibility Lab on every device class and iOS version in the
   matrices; import the reports; fill the rows from evidence.
2. Run the human passes in `docs/hardening/accessibility-audit.md`,
   `docs/hardening/device-compatibility-matrix.md` and
   `docs/hardening/performance-verification.md`; record the results.
3. Re-read every document in this table against the code, and fix any sentence
   that describes something the build does not do.
4. Delete or rewrite any claim that cannot be reproduced from this repository.
5. Tag the release. The documentation freezes with it.
