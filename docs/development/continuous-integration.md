# Continuous Integration

The workflow definition lives at [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml).
It first ran to green on hosted infrastructure on 2026-09-24: run
35992989870 on `main`, the merge of the packaging and application-pipeline
work, passed the hygiene job, the application build, and the full unit-test
target on an iPhone simulator. The opt-in Keychain integration suite skips
there by design, as it does everywhere without
`ZYNSIGN_RUN_KEYCHAIN_TESTS=1` in a signed iOS test host.

## Jobs

| Job | Runner | Steps |
| --- | --- | --- |
| Repository hygiene | `ubuntu-latest` | Refuse private-key material anywhere; refuse certificate text outside `Tests/`; refuse generated artifacts and machine state (`DerivedData/`, `xcuserdata/`, `*.xcresult`, `*.xcuserstate`, `.DS_Store`); run the host vector scripts and the external validation harness self-test |
| Build and test (Xcode) | `macos-15` | Select the newest stable Xcode, record the toolchain versions, build the application target for the generic iOS Simulator platform, run the `ZynSign` scheme's unit-test target on an iPhone simulator |
| External validation (Apple tooling) | `macos-15` | Run `ExternalValidationExportTests` with `TEST_RUNNER_ZYNSIGN_EXPORT_DIR` set, judge the exported artifacts with `Tests/Host/external_validation.py run` (`codesign`, `otool`, `ditto`, `unzip`, OpenSSL, ad hoc reference signing), publish the report to the job summary, upload the report and the exports as the `external-validation` artifact, and emit one notice per artifact |
| Release gate | `ubuntu-latest` | Run `Scripts/release_gate.py` after hygiene and build-and-test are green: documentation set, version metadata consistency, static hygiene, the end-to-end validation matrix, the release checklist, and the release metadata sections. **No manual bypass** — a red gate blocks the release; `release.yml` runs the same script before publishing |

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
- Whether the release requirements hold: the **release gate** job refuses
  to go green until the build and test job has passed and the release
  checklist and validation matrix are complete
  ([release-lock-rc3.md](../releases/release-lock-rc3.md),
  [qa-signoff-1.0.0-rc.1.md](../releases/qa-signoff-1.0.0-rc.1.md)). It is
  the required check on the release-lock branch and runs again in
  `release.yml` before any tag is published. It has no bypass flag.

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

Without Xcode, only the host vectors, the harness self-test, the release
gate, and the hygiene greps apply:

```
python3 Tests/Host/verify_macho_signing_vector.py
python3 Tests/Host/verify_nested_code_signing_vector.py
python3 Tests/Host/verify_zip_writer_vectors.py
python3 Tests/Host/external_validation.py self-test
python3 Scripts/release_gate.py
```

A clean exit from the host scripts is not an executed test run of the Swift
suites. Report it as what it is.
