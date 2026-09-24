# Continuous Integration

The workflow definition lives at [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml).
It has not yet run to green on hosted infrastructure: until it has, no claim
is made about hosted CI results, and every check below must be read as
"defined", not "passing".

## Jobs

| Job | Runner | Steps |
| --- | --- | --- |
| Repository hygiene | `ubuntu-latest` | Refuse private-key material anywhere; refuse certificate text outside `Tests/`; refuse generated artifacts and machine state (`DerivedData/`, `xcuserdata/`, `*.xcresult`, `*.xcuserstate`, `.DS_Store`); run the host vector scripts |
| Build and test (Xcode) | `macos-15` | Select the newest stable Xcode, record the toolchain versions, build the application target for the generic iOS Simulator platform, run the `ZynSign` scheme's unit-test target on an iPhone simulator |

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
  binding, and nested-signing ordering.

## What CI Does Not Claim

- **No device results.** Simulated key storage, absence of hardware security,
  and differing document-picker behavior mean a simulator pass says nothing
  about the corresponding device behavior. The physical-device experiments in
  the feasibility record stay open regardless of CI.
- **No trust or platform acceptance.** The vectors confirm byte-level
  agreement with ZynSign's own format implementation; they are not Apple
  platform validation.
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

Without Xcode, only the host vectors and the hygiene greps apply:

```
python3 Tests/Host/verify_macho_signing_vector.py
python3 Tests/Host/verify_nested_code_signing_vector.py
python3 Tests/Host/verify_zip_writer_vectors.py
```

A clean exit from the host scripts is not an executed test run of the Swift
suites. Report it as what it is.
