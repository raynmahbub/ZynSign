# Continuous Integration

The workflow definition lives at [`.github/workflows/01-build.yml`](../../.github/workflows/01-build.yml).
It first ran to green on hosted infrastructure on 2026-09-24: run
35992989870 on `main`, the merge of the packaging and application-pipeline
work, passed the hygiene job, the application build, and the full unit-test
target on an iPhone simulator. The opt-in Keychain integration suite skips
there by design, as it does everywhere without
`ZYNSIGN_RUN_KEYCHAIN_TESTS=1` in a signed iOS test host.

## Jobs

| Job | Runner | Steps |
| --- | --- | --- |
| Repository hygiene | `ubuntu-latest` | Refuse private-key material anywhere; refuse certificate text outside `Tests/`; refuse generated artifacts and machine state (`DerivedData/`, `xcuserdata/`, `*.xcresult`, `*.xcuserstate`, `.DS_Store`); check the release train is consistent; check the release metadata derivation (`release_meta.sh --self-test`); run the host vector scripts and the external validation harness self-test; **refuse a crash surface that disagrees with its baseline; refuse an accessibility finding in the sources; refuse a regression catalogue that names a test which does not exist; build and upload the hardening report** |
| Build and test (Xcode) | `macos-15` | Select the newest stable Xcode, record the toolchain versions, restore the Swift Package cache, then run `Scripts/ci/build.sh`: resolve packages, clean Derived Data, build every target, build the test targets, run the unit tests on a resolved iPhone simulator, annotate each failing case from the result bundle, and upload `build/logs/` on failure |
| Lint and format | `macos-15` | One Homebrew install of SwiftLint and SwiftFormat, then `Scripts/ci/lint.sh` (error-severity findings block) and `Scripts/ci/format.sh check` (the pinned `.swiftformat` rule set; the weekly maintenance run applies it) |
| External validation (Apple tooling) | `macos-15` | Run `ExternalValidationExportTests` with `TEST_RUNNER_ZYNSIGN_EXPORT_DIR` set, judge the exported artifacts with `Tests/Host/external_validation.py run` (`codesign`, `otool`, `ditto`, `unzip`, OpenSSL, ad hoc reference signing), publish the report to the job summary, upload the report and the exports as the `external-validation` artifact, and emit one notice per artifact |

The hygiene job's certificate rule has one deliberate exception: synthetic
certificate text appears in `Tests/ZynSignTests/` as rejection vectors for
the certificate parser, and those fixtures embed no private keys. Anything
matching outside `Tests/` fails the job.

## What CI Establishes

- Whether the application target compiles under the selected Xcode.
- Whether the unit-test target passes on a simulator, including the
  security regression suites listed in the
  [release security review](../security/release-review.md).
- Whether the host vector scripts still agree with the committed Swift
  fixtures about Mach-O layout, CodeDirectory bytes, page hashes, CMS
  binding, and nested-signing ordering, and whether the external validation
  harness's self-test passes.
- What Apple's desktop tooling says about the artifacts ZynSign signs, in
  the external validation report. That job is measurement, not a gate: it
  fails only when the harness cannot run, never because `codesign` rejects
  an artifact. See
  [external-validation.md](../architecture/external-validation.md).
- **That the crash surface still matches its inventory.** Every `try!`,
  `as!`, force unwrap, `fatalError`, `preconditionFailure`, `precondition`,
  `assertionFailure`, `unowned` and implicitly-unwrapped property in the
  application's sources must be absent or named in
  `CrashSurfaceBaseline.swift` with a reason. A new one fails the job.
- **That no hard-coded colour or undersized control was introduced.** The
  accessibility source audit runs with `--strict`, so a finding fails the
  job; a `review` item (text that may shrink below 0.75 scale) is reported
  and does not.
- **That every behaviour the regression catalogue freezes names a test that
  exists.** A name nobody keeps is worse than no name.
- **That the hardening report builds**, and is uploaded as an artifact. With
  no device report available on the runner, every device row is reported as
  not run rather than filled in.

## What CI Does Not Claim

- **No device results.** Simulated key storage, absence of hardware security,
  and differing document-picker behavior mean a simulator pass says nothing
  about the corresponding device behavior. The physical-device experiments in
  the feasibility record stay open regardless of CI.
- **No trust or platform acceptance.** The vectors confirm byte-level
  agreement with ZynSign's own format implementation; they are not Apple
  platform validation. `codesign` accepting an artifact in the external
  validation job is Apple's desktop verifier speaking, not iOS: no AMFI,
  CoreTrust, provisioning, or installation check runs there.
- **No secret scanning beyond the checked patterns.** The hygiene job refuses
  known-bad shapes (private keys, misplaced certificates, build products).
  It is not a substitute for the hosted secret-scanning and push-protection
  features the repository owner enables in the repository settings, which
  cannot be configured from this file.

## Running the Same Checks Locally

With Xcode installed:

```
xcodebuild build -project ZynSign.xcodeproj -scheme ZynSign \
  -destination 'generic/platform=iOS Simulator'
xcodebuild test -project ZynSign.xcodeproj -scheme ZynSign \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

The external validation job's two steps, with Xcode:

```
TEST_RUNNER_ZYNSIGN_EXPORT_DIR="$PWD/.external-validation/export" \
  xcodebuild test -project ZynSign.xcodeproj -scheme ZynSign \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:ZynSignTests/ExternalValidationExportTests
python3 Tests/Host/external_validation.py run \
  --export-dir .external-validation/export \
  --report-dir .external-validation/report
```

Without Xcode, only the host vectors, the harness self-test, the RC audits,
and the hygiene greps apply:

```
python3 Tests/Host/verify_macho_signing_vector.py
python3 Tests/Host/verify_nested_code_signing_vector.py
python3 Tests/Host/verify_zip_writer_vectors.py
python3 Tests/Host/external_validation.py self-test

python3 Scripts/release_train.py check
Scripts/ci/release_meta.sh --self-test
python3 Scripts/audit_crash_surface.py
python3 Scripts/audit_accessibility.py --strict
python3 Scripts/audit_navigation_stack.py
python3 Scripts/audit_identity_stability.py
python3 Scripts/audit_regression_coverage.py
python3 Scripts/generate_hardening_report.py --output build/hardening/index.html
```

A clean exit from the host scripts is not an executed test run of the Swift
suites. Report it as what it is.

The RC audits have a `--json` flag each for a machine-readable result, and
`audit_accessibility.py` can write a Compatibility Lab overlay with
`--overlay-out`. The crash-surface audit takes `--list` to show every line it
matched. See the Compatibility Lab (Settings → Compatibility Lab) and [private-testing.md](../releases/private-testing.md).

## The engineering suite

Five workflows, no duplicated gates: every job calls a reusable script in
`Scripts/ci/`, so CI logic never lives in YAML and never appears twice.
Failing unit tests are surfaced as check annotations by
`Scripts/ci/annotate_test_failures.sh`, which reads the run's result
bundle so the failing suites are readable without opening a raw log.

The suite is split by what it needs, which is what keeps the macOS bill
down — macOS minutes cost roughly ten times ubuntu minutes, so only the
jobs that genuinely need Xcode run on macOS:

| Workflow | Trigger | Jobs | Gate type |
| --- | --- | --- | --- |
| `01-build.yml` · 🔨 Build | PR + every push; manual (`mode: private-ipa`) | `hygiene` (ubuntu) · `build-and-test` · `lint-and-format` · `external-validation` (macOS); on a PR also `pr-title` · `commitlint` · `label-pr` (ubuntu) · `danger` (macOS); on demand `private-ipa` | blocking, except external validation (measures) and Danger (advises) |
| `02-quality.yml` · 🛡 Quality | PR + push to main | 8 ubuntu jobs: `architecture-guard` · `dependency-validation` · `docs-check` · `secret-policy` · `gitleaks` · `complexity-check` · `engineering-summary` · `readme-check` | blocking, except complexity and the summary |
| `03-release.yml` · 🚀 Release | tag `v*` + manual (`version`, `dry_run`) | `meta` → quality gate → build/test → assets → publish → verdict; `dry_run: true` is the full rehearsal and publishes nothing | blocking |
| `99-command-center.yml` · ⚙ Command Center | weekly + manual (`mode: report` default, `mode: repair`) | always `reports` · `regression-check`; only in repair mode `publish` · `autoformat` · `readme-sync` · `label-sync` · `stale` | automation, never blocks a PR; the scheduled run writes nothing to the repository |
| `release-drafter.yml` | push to main, PR, manual | `update-release-draft` — drafts the train's current stop | automation |

Scripts behind the gates:

| Script | What it establishes |
| --- | --- |
| `build.sh` | packages, clean, build every target, build the test targets, run the unit tests, annotate failures |
| `lint.sh` / `format.sh check` | `.swiftlint.yml` two-tier rules (errors block) · the pinned `.swiftformat` rule set |
| `architecture_guard.sh` | 8 layer rules + the ratcheted baseline |
| `dependency_check.sh` | the allowlist — dependency-free by design |
| `security_scan.sh` + Gitleaks | the repository's secret policy on this tree, and over the full history |
| `docs_check.sh` | links and images block; orphans and markdown quality warn |
| `update_readme.py --check` | README agrees with `MARKETING_VERSION` and `WHAT_DOES_NOT_EXIST.md` |
| `complexity_check.sh` | function 80 / file 800 / nesting 4 — advisory |
| `dead_code_scan.sh` | Periphery, weekly, never deletes |
| `metrics_report.sh` | the Engineering Command Center per PR, dashboards weekly |
| `release_meta.sh` | version derivation; fails a non-current train stop in the first job |
| `release_validate.sh` | train stage, `MARKETING_VERSION`, build number, changelog, notes |

The architecture guard protects the layered contract documented in
[../architecture/architecture.md](../architecture/architecture.md);
its known grandfathered crossings are frozen in
`Scripts/ci/architecture-baseline.txt`. Release behaviour is described
in [../releases/release-automation.md](../releases/release-automation.md);
recommended branch protection lives in
[branch-protection.md](branch-protection.md).
