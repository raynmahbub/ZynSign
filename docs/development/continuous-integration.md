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
| Repository hygiene | `ubuntu-24.04` | On manual Build runs, refuse private-key material and certificate text outside `Tests/` and run the release-metadata self-test; on all Build events, refuse generated artifacts and machine state (`DerivedData/`, `xcuserdata/`, `*.xcresult`, `*.xcuserstate`, `.DS_Store`), **parse every workflow `run:` block with `bash -n` and refuse a backtick that two backslashes left unescaped** (`workflow_shell_check.py`), check the release verdict (`release_verdict.sh --self-test`), run the host vector scripts and external-validation harness self-test; **refuse a crash surface that disagrees with its baseline; refuse an accessibility finding in the sources; refuse a regression catalogue that names a test which does not exist; build and upload the hardening report** |
| Build and test (Xcode) | `macos-15` | Select the newest stable Xcode, record the toolchain versions, restore the Swift Package cache, then run `Scripts/ci/build.sh`: resolve packages, clean Derived Data, build every target, build the test targets, run the full unit-test suite on a resolved iPhone simulator, annotate each failing case from the result bundle, and record the Xcode version, simulator destination, and a concise XCTest summary. The job then uploads the native `.xcresult` and test logs on success and on failure as `xctest-results-<run-id>-<attempt>` (14 days). The manual `run_unit_tests: false` switch turns the run into a compile-only gate and does not produce a bundle |
| Lint and format | `ubuntu-24.04` | `Scripts/ci/lint.sh` (error-severity findings block) and `Scripts/ci/format.sh check` (the pinned `.swiftformat` rule set, repaired with `Scripts/ci/format.sh apply`). Neither tool needs Xcode: with no binary installed the scripts run SwiftLint and SwiftFormat from their published Linux images, so this job does not consume a macOS runner |
| External validation (Apple tooling) | `macos-15` | Run `ExternalValidationExportTests` with `TEST_RUNNER_ZYNSIGN_EXPORT_DIR` set, judge the exported artifacts with `Tests/Host/external_validation.py run` (`codesign`, `otool`, `ditto`, `unzip`, OpenSSL, ad hoc reference signing), publish the report to the job summary, upload the report and the exports as the `external-validation` artifact, and emit one notice per artifact |
| Private test IPA (manual, `mode: private-ipa`) | `macos-15` | Run `Scripts/ci/private_ipa.sh`: archive for a real device and **always** deliver an IPA — `ZynSign-{tag}-{config}-private.ipa`, a signed ad-hoc export, when the `TEAM_ID` secret is configured; otherwise `ZynSign-{tag}-{config}-private-unsigned.ipa`, the raw Payload package, which must be re-signed before installation. The artifact is a 7-day workflow artifact (`build/private/` with the IPA, its SHA-256 and the logs) — never a tag, never a release. A green job always contains an IPA; when none can be produced the job fails |

The Xcode Build workflow runs for pull requests and manual dispatches, not
branch pushes. Pull requests test the proposed merge commit, so a branch push
does not start a second Xcode build of the same work. The lightweight Quality
workflow still runs on pull requests and pushes to `main`/`develop`; it owns
the automatic source-tree secret and release-train checks. The source-tree
secret scan remains in manual Build dispatches, and the release-metadata
self-test there also exercises the train's current-stop validation.

The certificate rule has one deliberate exception: synthetic certificate
text appears in `Tests/ZynSignTests/` as rejection vectors for the certificate
parser, and those fixtures embed no private keys. Anything matching outside
`Tests/` fails the secret-policy check.

## Retrieving native XCTest evidence

The Build workflow's `build-and-test` job, and the Release workflow's
macOS build job, both run the full unit-test suite through
`Scripts/ci/build.sh`. After that step — whether it passed or failed — the
job uploads one artifact:

| | |
| --- | --- |
| Name | `xctest-results-<run-id>-<attempt>` |
| Retention | 14 days |
| Contents | `build/logs/*.log`, `xctest-context.txt`, `xctest-summary.txt`, `xctest-summary.json`, `xctest-summary.md`, and `build/logs/ZynSignTests.xcresult` when the suite ran |

14 days matches the previous failure-log window. Success now uploads the
bundle on every pull request, and a result bundle is large, so the artifact
does not use the 90-day repository default. A re-run increments
`github.run_attempt`, so each attempt keeps its own name and cannot overwrite
the previous bundle.

The upload step uses `if: always()` and `if-no-files-found: warn`. A
compile-only manual run (`run_unit_tests: false`), or a job that dies before
`xcodebuild` writes anything, does not fail again because the bundle is
missing. The step before the upload moves signing-material filenames
(`.p12`, `.pem`, `.key`, `.mobileprovision`, and the same family) out of the
top level of `build/logs/`. It does not open or rewrite the result bundle.
The upload path excludes those suffixes again anywhere under `build/logs/`,
so a nested attachment with one of those names is left out of the zip.
DerivedData, the private IPA, provisioning profiles, certificates, and
private keys are not in the artifact. Hidden files stay excluded, which is
the same default the previous failure-only upload used.

The job log and the run's Summary page record the Xcode version, the
simulator destination (`platform=iOS Simulator,name=…,OS=latest`), and a
concise count (passed, failed, skipped, total). Failed test names are listed
there; the assertion text is in the bundle.

Download it from the run page (Actions → the run → Artifacts), or:

```sh
gh run download <run-id> --name xctest-results-<run-id>-<attempt>
```

On a Mac, open the bundle in Xcode:

```sh
open build/logs/ZynSignTests.xcresult
```

`Tests/Host/test_xctest_evidence.py` checks this contract on the host: the
upload condition, the artifact name, the retention, the path allowlist, and
the summary formatter. It does not execute XCTest and it does not open a
result bundle. A green host check is not a simulator pass. Only a macOS job
with Xcode produces the bundle.

## What CI Establishes

- Whether the application target compiles under the selected Xcode.
- Whether the unit-test target passes on a simulator, including the
  security regression suites listed in the
  [release security review](../security/release-review.md). The native
  `.xcresult` from that run is retained for 14 days on success and on
  failure; see [Retrieving native XCTest evidence](#retrieving-native-xctest-evidence).
- Whether the host vector scripts still agree with the committed Swift
  fixtures about Mach-O layout, CodeDirectory bytes, page hashes, CMS
  binding, and nested-signing ordering, and whether the external validation
  harness's self-test passes.
- What Apple's desktop tooling says about the artifacts ZynSign signs, in
  the external validation report. The job fails when the harness itself
  cannot run; `codesign`/`otool` verdicts are recorded findings in the
  report, because macOS desktop verification is not iOS platform
  acceptance. See
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

- **No device results.** The retained `.xcresult` is the simulator XCTest
  bundle, not a device run. Simulated key storage, absence of hardware security,
  and differing document-picker behavior mean a simulator pass says nothing
  about the corresponding device behavior. The physical-device experiments in
  the feasibility record stay open regardless of CI.
- **No trust or platform acceptance.** The vectors confirm byte-level
  agreement with ZynSign's own format implementation; they are not Apple
  platform validation. `codesign` accepting an artifact in the external
  validation job is Apple's desktop verifier speaking, not iOS: no AMFI,
  CoreTrust, provisioning, or installation check runs there.
- **No secret scanning beyond the checked patterns.** `02-quality.yml` runs
  the repository's source-tree secret policy and Gitleaks over full history;
  these checks still have false-negative limits. They are not substitutes
  for the hosted secret-scanning and push-protection features the repository
  owner enables in repository settings, which cannot be configured from this
  file.

## When a job never got a runner

A hosted-runner shortage is not a finding. GitHub reports it as a failed job
whose annotation reads *"The job was not acquired by Runner of type hosted
even after multiple attempts"*, with no runner assigned and **no step having
run** — so nothing was compiled, linted, or validated, and nothing was
disproved either. The two are easy to confuse in a run list that shows one
red check beside a green build.

Read the shape of the failure before you read the code:

1. Open the job. A red job with failing steps is a real verdict; a red job
   with zero failing steps and no runner is capacity.
2. Confirm on the run summary — capacity failures arrive within minutes,
   not at the end of a normal job's duration.
3. **Re-run the failed jobs** on the same commit (`gh run rerun <run-id>
   --failed`, or *Re-run failed jobs* in the UI). A re-run keeps the same
   commit and the same artefacts; nothing needs to be rebuilt or re-pushed,
   and no source change is warranted by capacity alone.
4. Never record a capacity failure as a test result, a device result, or a
   reason to loosen a gate. The commit's verdict is whatever the gates say
   when they actually run.

The structural mitigation is the split in the section above: only jobs that
need Xcode hold a macOS runner, and `lint-and-format` — which needs a Swift
toolchain but not a Mac — runs its tools from their published Linux images on
`ubuntu-24.04`. That does not remove the shortage; it keeps the two jobs that
cannot avoid the macOS pool from queuing behind a third that can.

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
Scripts/ci/release_verdict.sh --self-test
python3 Scripts/audit_crash_surface.py
python3 Scripts/audit_accessibility.py --strict
python3 Scripts/audit_navigation_stack.py
python3 Scripts/audit_identity_stability.py
python3 Scripts/audit_regression_coverage.py
python3 Scripts/generate_hardening_report.py --output build/hardening/index.html
python3 -m unittest Tests.Host.test_xctest_evidence -v
bash -n Scripts/ci/build.sh
python3 Scripts/ci/workflow_shell_check.py
```

A clean exit from the host scripts is not an executed test run of the Swift
suites. `test_xctest_evidence` checks the upload contract and the summary
formatter only. Report it as what it is.

The RC audits have a `--json` flag each for a machine-readable result, and
`audit_accessibility.py` can write a Compatibility Lab overlay with
`--overlay-out`. The crash-surface audit takes `--list` to show every line it
matched. See the Compatibility Lab (Settings → Compatibility Lab) and [private-testing.md](../releases/private-testing.md).

## The engineering suite

Three gate workflows and one weekly sweep, no duplicated gates: every job
calls a reusable script in `Scripts/ci/`, so CI logic never lives in YAML
and never appears twice.
Failing unit tests are surfaced as check annotations by
`Scripts/ci/annotate_test_failures.sh`, which reads the run's result
bundle so the failing suites are readable without opening a raw log.
The same bundle is uploaded on success and on failure; retrieval is in
[Retrieving native XCTest evidence](#retrieving-native-xctest-evidence).

The suite is split by what it needs, which is what keeps the macOS bill
down — macOS minutes cost roughly ten times ubuntu minutes, so only the
jobs that genuinely need Xcode run on macOS. (It is also a reliability
matter: GitHub's hosted macOS pool is capacity-limited, so every job that
does not need a Mac is one less chance that a run ends red without a
single step having failed — see [When a job never got a
runner](#when-a-job-never-got-a-runner).)

| Workflow | Trigger | Jobs | Gate type |
| --- | --- | --- | --- |
| `01-build.yml` · 🔨 Build | PR + manual (`mode: build \| private-ipa`, plus `configuration`, `run_unit_tests`, `note`); branch pushes do not start an Xcode build | `hygiene` · `lint-and-format` (ubuntu) · `build-and-test` · `external-validation` (macOS); on a PR also `pr-title` · `commitlint` · `label-pr` (ubuntu) · `danger` (macOS); on demand `private-ipa` | blocking, except external validation (measures) and Danger (advises) |
| `02-quality.yml` · 🛡 Quality | PR + push to `main`/`develop` + manual | 9 ubuntu jobs: `architecture-guard` · `dependency-validation` · `docs-check` · `secret-policy` · `gitleaks` · `release-train` · `complexity-check` · `engineering-summary` · `readme-check` | blocking, except complexity and the summary |
| `03-release.yml` · 🚀 Release | tag `v*` + manual (`version`, `dry_run`) | `meta` → quality gate → build/test → assets → publish → verdict; `dry_run: true` is the full rehearsal and publishes nothing | blocking |
| `04-maintenance.yml` · 🧹 Maintenance | Monday 03:23 UTC + manual (`repair`) | one macOS sweep: full metrics (Periphery), `format.sh apply`, `update_readme.py`, then one repair PR (staged on a branch with a warning when Actions may not open PRs) | advisory — nothing requires it |

Scripts behind the gates:

| Script | What it establishes |
| --- | --- |
| `build.sh` | packages, clean, build every target, build the test targets, run the full unit-test suite, annotate failures, record the Xcode version, simulator destination, and XCTest summary |
| `lint.sh` / `format.sh check` | `.swiftlint.yml` two-tier rules (errors block) · the pinned `.swiftformat` rule set (`format.sh apply` repairs drift) |
| `architecture_guard.sh` | 8 layer rules + the ratcheted baseline |
| `dependency_check.sh` | the allowlist — dependency-free by design |
| `security_scan.sh` + Gitleaks | the repository's secret policy on this tree, and over the full history |
| `docs_check.sh` | links and images block; orphans and markdown quality warn |
| `update_readme.py --check` | README agrees with `MARKETING_VERSION` and `WHAT_DOES_NOT_EXIST.md` |
| `complexity_check.sh` | function 80 / file 800 / nesting 4 — advisory |
| `dead_code_scan.sh` | Periphery, on demand (the quick metrics run skips it), never deletes |
| `metrics_report.sh` | the per-PR Engineering Command Center aggregates each Quality job's result and metrics artifact without rerunning its gates; full dashboards in the weekly sweep |
| `private_ipa.sh` | the device archive and its IPA: signed ad-hoc export with `TEAM_ID`, unsigned Payload package without — always an IPA |
| `release_meta.sh` | version derivation; its self-test validates the current train stop in the Quality `release-train` job (and manual Build runs) |
| `release_validate.sh` | train stage, `MARKETING_VERSION`, build number, changelog, notes |
| `release_verdict.sh` | the final release card: names the job that stopped a run and tells a gate failure from a runner GitHub never acquired (re-run), never calls a failed dry run a rehearsal; a failed build points at `xctest-results-<run-id>-<attempt>` |
| `xctest_evidence.py` | concise XCTest summary from xcresulttool JSON or the xcodebuild log; quarantines signing-material filenames before the evidence upload |

The architecture guard protects the layered contract documented in
[../architecture/architecture.md](../architecture/architecture.md);
its known grandfathered crossings are frozen in
`Scripts/ci/architecture-baseline.txt`. Release behaviour is described
in [../releases/release-automation.md](../releases/release-automation.md);
recommended branch protection lives in
[branch-protection.md](branch-protection.md).
