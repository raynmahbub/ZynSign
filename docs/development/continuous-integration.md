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
| Build and test (Xcode) | `macos-15` | Select the newest stable Xcode, record the toolchain versions, build the application target for the generic iOS Simulator platform into a job-local derived-data directory, run the `ZynSign` scheme's unit-test target on an iPhone simulator, package the built `ZynSign.app` with `ditto` (round-trip checked), and upload the zip as the `ZynSign-simulator` artifact (30-day retention) |
| Unsigned IPA (device build) | `macos-15` | Build the application target for the generic iOS platform with `CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`, fail if the build output carries any code signature (`codesign -d`), assemble `Payload/ZynSign.app` into `ZynSign-unsigned.ipa`, verify the zip and its `Info.plist` entry, and upload it as the `ZynSign-unsigned-ipa` artifact (30-day retention) |
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
- That the built simulator application packages into a zip that reopens
  as `ZynSign.app`, and that the zip is downloadable from the run as the
  `ZynSign-simulator` artifact.
- That a device-architecture build succeeds with code signing disabled
  end to end, that its output carries no code signature, and that the
  assembled `ZynSign-unsigned.ipa` is a readable zip holding
  `Payload/ZynSign.app` — downloadable as the `ZynSign-unsigned-ipa`
  artifact.
- Whether the host vector scripts still agree with the committed Swift
  fixtures about Mach-O layout, CodeDirectory bytes, page hashes, CMS
  binding, and nested-signing ordering, and whether the external validation
  harness's self-test passes.
- What Apple's desktop tooling says about the artifacts ZynSign signs, in
  the external validation report. That job is measurement, not a gate: it
  fails only when the harness cannot run, never because `codesign` rejects
  an artifact. See
  [external-validation.md](../architecture/external-validation.md).

## What CI Does Not Claim

- **No device results.** Simulated key storage, absence of hardware security,
  and differing document-picker behavior mean a simulator pass says nothing
  about the corresponding device behavior. The physical-device experiments in
  the feasibility record stay open regardless of CI.
- **No IPA, no device installation, no release.** The `ZynSign-simulator`
  artifact is an iOS Simulator `.app` inside a zip. It runs only on a
  simulator (for example `xcrun simctl install booted ZynSign.app` after
  unzipping); it is not signed for a device, is not an `.ipa`, and is not
  a distributed release. There is still no release process; see
  [release documentation](../releases/README.md).
- **The unsigned IPA is not installable as-is.** `ZynSign-unsigned.ipa`
  is a device build with no signature, no provisioning profile, and no
  trust chain — iOS will refuse to install it unchanged. It exists so a
  developer can sign it afterwards with their own certificate and tool.
  CI holds no Apple credentials (see [SECURITY.md](../../SECURITY.md)),
  and the job proves absence of a signature, never presence of trust.
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
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData
xcodebuild test -project ZynSign.xcodeproj -scheme ZynSign \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath build/DerivedData
ditto -c -k --sequesterRsrc --keepParent \
  build/DerivedData/Build/Products/Debug-iphonesimulator/ZynSign.app \
  ZynSign-simulator.zip
```

Keep `build/` out of version control; the zip is a regenerated build
product, not a fixture.

The unsigned device IPA job's steps, with Xcode (no Apple developer
account required — signing is disabled):

```
xcodebuild build -project ZynSign.xcodeproj -scheme ZynSign \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
codesign -d build/DerivedData/Build/Products/Release-iphoneos/ZynSign.app
mkdir -p build/ipa/Payload
ditto build/DerivedData/Build/Products/Release-iphoneos/ZynSign.app \
  build/ipa/Payload/ZynSign.app
(cd build/ipa && zip -qry ../ZynSign-unsigned.ipa Payload)
unzip -t build/ZynSign-unsigned.ipa
```

The last `codesign -d` must fail: the build is expected to carry no
signature. The resulting `.ipa` is unsigned by design and cannot be
installed until signed with your own certificate and tool.

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

Without Xcode, only the host vectors, the harness self-test, and the
hygiene greps apply:

```
python3 Tests/Host/verify_macho_signing_vector.py
python3 Tests/Host/verify_nested_code_signing_vector.py
python3 Tests/Host/verify_zip_writer_vectors.py
python3 Tests/Host/external_validation.py self-test
```

A clean exit from the host scripts is not an executed test run of the Swift
suites. Report it as what it is.
