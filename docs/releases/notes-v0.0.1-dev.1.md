## [0.0.1-dev.1] — Development · the first build

Market `0.0.1` build `1` (`CFBundleShortVersionString 0.0.1`,
`CFBundleVersion 1`), tag `v0.0.1-dev.1`. Release train `.dev1`: switches on
**no** staged feature.

ZynSign is an on-device iOS signing app: import an application package, inspect
it, sign it with your own certificate and profile, and hand off the result —
inside the app sandbox, with no desktop helper, no remote service, and no
analytics.

A Release build of this stop shows the core — Files, Import (`ipa`/`tipa`),
Library, Bundle Explorer, Home and Settings. Everything else is already compiled
into the binary and stays hidden until the stop that introduces it; a Debug
build exposes all of it, and `-ZynSignReleaseStage <stage>` previews any later
stop. That is the job of a development stop: prove the release machinery against
a real tag before a single feature is offered publicly.

### Added

- **The core surfaces** *(visible in `v0.0.1-dev.1`)* — `Files · Library · Home
  · App Store · Downloads · Settings`, `ipa`/`tipa` import (bounded,
  security-scoped, SHA-256), a durable library that survives relaunch, duplicate
  detection, a missing-artifact banner, a read-only bundle explorer, and a Files
  browser over ZynSign's own container.
- **Certificate Studio** *(built · visible from the stop that introduces it)* —
  `.p12`/`.pfx` import (≤ 10 MiB) through `SecPKCS12Import` into
  `SecureIdentityStore` (`WhenUnlockedThisDeviceOnly`, non-extractable,
  duplicate SHA-256 rejected), detail view with subject / issuer / serial /
  SHA-256 / validity, and a public-metadata JSON export that never touches the
  private key.
- **Smart Sign** *(built · hidden at this stop)* — the nine-stage pipeline behind
  one validated call: isolated working copy, inner-first nested signing,
  independent re-read verification of the signed copy, packaging, and a container
  verification before anything reaches `Documents/Signed`. Refusals name the
  stage, the reason and the recovery facts; Discard reports what it reclaimed.
- **Compatibility Lab** *(Debug and internal builds)* — the validation dashboard:
  it builds synthetic packages, exercises the pipeline and reports what it found,
  with every row stating what was verified and what next.
- **The engineering system** *(no user-visible behaviour)* — five workflows
  (🔨 Build, 🛡 Quality, 🚀 Release, ⚙ Command Center, Release Drafter), one tag
  publishing a version-stamped asset set derived from that tag
  (`ZynSign-v{tag}-unsigned.ipa`, `-SHA256.txt`, `BuildPassport-v{tag}.json`,
  `MANIFEST.md`, `ReleaseNotes.md`), and `dry_run: true` to rehearse the whole
  release without publishing.

### Known limitations

Carried in `docs/product/WHAT_DOES_NOT_EXIST.md` (`10 wired · 3 never`):

- **In-app installation is unavailable.** *(Accepted — no supported mechanism
  exists for an iOS/iPadOS app to install an arbitrary IPA. ZynSign builds the
  OTA manifest, the `itms-services://` link and a QR for a host you control, and
  states plainly that it never installs.)* See
  `docs/architecture/installation-compatibility.md`.
- **Pairing / JIT / Mux is never claimed.** *(Accepted — see
  `docs/architecture/pairing-jit-mux-feasibility.md`.)*
- **Off-device measurement is never claimed.** *(Accepted — the activity journal
  is on-device and cannot transmit.)*
- **External validation does not accept the pipeline's bundles.** Apple's desktop
  verifier accepts ZynSign's single-image signatures but rejects the pipeline's
  bundles, and the signature format fails the requirements Apple documents for
  iOS 15 and later. *(Open — see `docs/architecture/external-validation.md`.)*
- **This stop exposes no staged feature.** *(By design, not a defect — the gate
  is the point of a development stop. Debug builds expose all of them, so no
  development or UI work is blocked.)*

### What this release deliberately does not claim

- **No device evidence.** Nothing here comes from a real iPhone or iPad. The
  private matrix in `docs/releases/private-testing.md` has not been run for this
  stop, and no device row below is filled in.
- **No test result.** The unit and host-vector suites are judged by the
  `Build and test (Xcode)` and `External validation (Apple tooling)` jobs in CI,
  and this note claims nothing about their verdict until those jobs have run.
- **Not an App Store submission, and not signed.** CI never signs; the artifact
  is named `unsigned` because it is.
- **No install, no "it worked on my device", no performance figure.** Nobody
  measured one for this tag.
- **No claim that the hidden features are absent.** They are in the binary and
  gated, not deleted.

### Testing

Host audits, run on the Linux host that produced this note — the same scripts CI
runs, but **not** a Mac and **not** a simulator:

| Audit | Result |
|---|---|
| `Scripts/audit_crash_surface.py` | 9 constructs, every one justified; matches its baseline |
| `Scripts/audit_accessibility.py` | `accessibility.touchTargets` passed; 6 rows need review at reduced Dynamic Type, 4 waived after review. VoiceOver, focus order and rendered contrast are **not** settled here |
| `Scripts/audit_regression_coverage.py` | 9 behaviours executed in the app, 2 deferred to CI; every named test type exists in `Tests/ZynSignTests` |
| `Scripts/audit_design_tokens.py` | checked against the token baseline |

Pipeline checks, run on the same host: `python3 Scripts/release_train.py check`
and `check --tag v0.0.1-dev.1` green; `Scripts/ci/release_meta.sh --self-test`
green, and `release_meta.sh 0.0.1-dev.1` resolving to channel `development`,
pre-release `true`; `Scripts/ci/release_validate.sh 0.0.1-dev.1` passing every
check with no warnings; `release_assets.sh` producing all five assets with a
verifying SHA-256 and a passport recording what this tag actually contains.

Device rows: **none run.** No row is filled in from anything but a run.
