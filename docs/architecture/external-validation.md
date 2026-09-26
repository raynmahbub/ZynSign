# External Validation (ZS-031)

Until ZS-031, only ZynSign had checked ZynSign's signatures: its own post-sign
verifiers, host scripts over committed vectors, and OpenSSL over one fixture's
CMS. This record describes the harness that hands ZynSign's output to Apple's
developer tooling, what each check establishes and what it does not, and the
known-divergence register that the first hosted runs populated.

It is measurement. Nothing here changes how ZynSign signs, and no verdict
recorded here is iOS platform acceptance, trust evaluation, or
installability. Using macOS tooling as an independent validator is the
developer-side validation tier that architecture Sections 2 and 16 accept;
it is never a runtime path. [Smart Diagnostics](smart-diagnostics.md) reads
signing *inputs* before a run; its score cannot resolve the output divergences
recorded below or substitute for independent validation.

## How it runs

1. **Export** — `Tests/ZynSignTests/ExternalValidationExportTests.swift`,
   iOS-gated and opt-in: every test skips unless `ZYNSIGN_EXPORT_DIR` names
   a directory (under `xcodebuild`, `TEST_RUNNER_ZYNSIGN_EXPORT_DIR`). It
   signs through the production use cases with a throwaway RSA-2048 key
   (`SecKeyCreateRandomKey`, not permanent, never exported) and verifies with
   the production `AppleSignatureVerifier`. The orchestration suites use a
   replay capability and an always-valid verifier instead, so this is the
   first place a real private-key signature passes through the application
   pipeline. The certificate is self-signed and shaped like a code-signing
   leaf (v3, digital signature, code-signing extended key usage, not a CA)
   so that verifiers judge the signature rather than the certificate's shape.
   Written, public material only:
   - `single/`: the ZS-026 synthetic executable signed twice (no metadata;
     XML entitlements), its unsigned input, damaged copies of each with
     ZynSign's own verdict, the certificate, and `manifest-single.json`;
   - `pipeline/`: the orchestration suite's nested-framework container plus
     one plain resource, unsigned, and `SignApplicationPipeline`'s signed
     output, the certificate, and `manifest-pipeline.json`.

   A signing refusal is recorded in the manifest as evidence; only a failure
   to write the export fails the test.
2. **Harness** — `Tests/Host/external_validation.py run`, on macOS with
   Xcode. For every artifact it runs `codesign --verify` (bundles also with
   `--deep --strict`), `codesign --display` with the requirements and the
   entitlements, `otool -l`, OpenSSL `cms -verify -noverify` over the CMS
   and the CodeDirectory, and `unzip -t` and `ditto` on the container. It
   evaluates the Apple-documented iOS format rules below, signs the same
   unsigned inputs ad hoc with `codesign` for a field-by-field reference
   comparison, compares ZynSign's and `codesign`'s verdicts on the damaged
   single images, and runs five bundle mutations through `codesign` alone.
   It writes `report.json` and `report.md`.
3. **CI** — the `external-validation` job (`macos-15`) runs both steps,
   publishes the report to the job summary, uploads the report and the
   exported artifacts as the `external-validation` workflow artifact, and
   emits one notice per artifact. It is not a gate: it fails only when the
   harness cannot do its job (a failed export, a missing manifest, artifact,
   or tool). `codesign` rejections are findings, not failures.
4. **Self-test** — `Tests/Host/external_validation.py self-test` runs in the
   hygiene job on any host: the signature parser against the committed
   ZS-026 vector, the rules, the tool-output parsers, the reference
   comparison, and the whole analysis and rendering path over synthetic
   exports with every tool unavailable. It exercises the harness, not Apple
   tooling.

Locally, with Xcode:

```
TEST_RUNNER_ZYNSIGN_EXPORT_DIR="$PWD/.external-validation/export" \
  xcodebuild test -project ZynSign.xcodeproj -scheme ZynSign \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:ZynSignTests/ExternalValidationExportTests
python3 Tests/Host/external_validation.py run \
  --export-dir .external-validation/export \
  --report-dir .external-validation/report
```

Keep the output directory out of version control; the exports are
regenerated on every run and are evidence, not fixtures.

## What each check establishes

| Check | Establishes | Does not establish |
| --- | --- | --- |
| `codesign --verify` | Apple's desktop static-code validation accepts the structure, page hashes, special slots, resource seal, and CMS signature, and the implicit or embedded designated requirement is satisfied | iOS acceptance (no AMFI, CoreTrust, or provisioning checks), trust: static validation accepts an untrusted chain as signed-but-untrusted |
| iOS format rules R1–R3 | The signature meets the format floor Apple documents for iOS 15 and later | Everything else a device enforces |
| OpenSSL `cms -verify -noverify` | The detached CMS signature verifies over the exact CodeDirectory bytes | Certificate trust (`-noverify`), Apple-specific attributes |
| `otool -l` layout checks (E5) | An independent Mach-O reader agrees on `LC_CODE_SIGNATURE` and `__LINKEDIT`; alignment and extents hold | Executability |
| Reference comparison | Where ZynSign's output differs from `codesign`'s own ad hoc signing of the same input | What an identity-signed Apple signature carries (CMS attributes, generated designated requirement), what a real iOS binary would get |
| Tamper parity | ZynSign's verifier and `codesign` reject the same damaged bytes | Detection of damage neither tool looks for |
| Bundle mutations | Whether `codesign` detects tampering in a ZynSign-signed bundle — only when the unmodified bundle is accepted | Anything, while the unmodified bundle is rejected |

Reference differences carry one of three labels. *Expected* differences
follow from ad hoc signing itself (the `CS_ADHOC` flag, no team identifier,
an empty CMS wrapper). *Input-dependent* differences follow from the input:
the synthetic executable declares no platform or minimum OS
(`LC_BUILD_VERSION` is absent), and `codesign` answers such input with
legacy-compatible choices, so those rows describe `codesign`'s reaction to
the input rather than ZynSign. Everything else is a *divergence*.

## Results

Hosted runs 36010725148 and 36011553668 (branch `arena/01a0d32d-zynsign`,
development commits `8855ad1` and `7442404`, since squashed) produced
identical verdicts. Environment: macOS 15.7.9 (runner image `macos15`
20260907.0337.1), Xcode 26.3 (17C529), OpenSSL 3.6.4.

| Artifact | ZynSign | `codesign` | iOS rules |
| --- | --- | --- | --- |
| `single-plain` | accepted | accepted — valid on disk; satisfies its Designated Requirement | R1 fail |
| `single-entitlements` | accepted | accepted — valid on disk; satisfies its Designated Requirement | R1 fail, R2 fail |
| `pipeline-ipa` (application) | accepted (stage 9) | rejected — code has no resources but signature indicates they must be present | R1 fail, R2 fail |
| `pipeline-ipa` `Frameworks/Test.framework` | — | rejected — code has no resources but signature indicates they must be present | R1 fail, R3 pass |

### Agreements

- **A1 — Apple's verifier accepts ZynSign's single-image signatures.**
  `codesign --verify` accepts both single images and reports the implicit
  designated requirement (`identifier "com.example.single" and certificate
  leaf = H"…"`) satisfied. The CodeDirectory (version `0x20200`, SHA-256,
  team identifier), the page hashes, the SuperBlob framing, the detached
  CMS with only content-type and message-digest signed attributes, and the
  XML entitlements blob — which `codesign` decodes and displays — are
  therefore accepted by Apple's desktop static-code validation. This is the
  first evidence from outside ZynSign that its signature construction is
  correct.
- **A2 — OpenSSL verifies every real-key CMS**, including the pipeline's
  main and nested executables.
- **A3 — Layout (E5) holds on all four binaries**: the signature offset is
  16-byte aligned, the region and `__LINKEDIT` end at the end of the file,
  the code limit equals the signature offset, and `otool` agrees on
  `LC_CODE_SIGNATURE` and `__LINKEDIT`.
- **A4 — Tamper parity is 9 of 9.** A flipped code byte, CodeDirectory
  byte, entitlements byte, or CMS signature byte, and a truncated
  signature, are rejected by both ZynSign and `codesign` on both images.
- **A5 — The container is accepted as a ZIP**: `unzip -t` passes and
  `ditto` extracts it.

### Known-divergence register

| ID | Divergence | Evidence | Proposed |
| --- | --- | --- | --- |
| D1 | CodeDirectory version `0x20200` is below the `0x20400` floor Apple documents for iOS 15 and later | R1 fails on every binary | ZS-032 |
| D2 | XML entitlements (slot −5) without DER entitlements (slot −7), including the empty set the pipeline embeds | R2 fails on `single-entitlements` and the pipeline's main executable | ZS-032 |
| D3 | `codesign` does not recognize ZynSign's resource seal. ZynSign writes only `files2`; the reference writes `files`, `files2`, `rules`, and `rules2` | the application is rejected as having no resources, deep or not, and `codesign --display` prints no Sealed Resources line for it | ZS-032 |
| D4 | Info.plist is not bound: slot −1 is absent on the main and nested executables, and ZynSign seals `Info.plist` in `files2` instead. The reference binds slot −1 and omits `Info.plist` from the seal (`^Info\.plist$` omit) | `codesign --display`: Info.plist=not bound; reference comparison | ZS-032 |
| D5 | No requirements blob: slot −2 and the Requirements entry are absent, and `codesign` synthesizes an implicit designated requirement. The ad hoc reference embeds a requirements set (empty for ad hoc) | reference comparison, all binaries | ZS-032 |
| D6 | The nested framework carries no resource seal of its own; the reference gives it `_CodeSignature/CodeResources` and binds slots −1, −2, and −3 | `codesign` rejects the framework with the same "no resources" message; reference comparison | ZS-035 |
| D7 | Nested code is sealed as a `cdhash` entry on the framework's executable; the reference seal, whose `rules2` is the 10-rule set with no nested rule, lists the framework's executable, `Info.plist`, and `_CodeSignature/CodeResources` as ordinary files (`hash`, `hash2`) | reference comparison of the two seals | ZS-035 |
| D8 | `files2` entries carry `hash2` only; the reference also writes the SHA-1 `hash`. Unresolved whether this follows the same legacy digest choice as I1 | reference comparison | ZS-033 decides |

`codesign` reports the first failure it meets. D3 masks everything behind
it for the bundle; D4 and D6 come from the reference comparison, and they
are the likely next rejections once D3 is resolved.

### Input-dependent differences

- **I1** — For the synthetic executable, `codesign`'s reference is a
  version `0x20100` SHA-1 CodeDirectory with a SHA-256 alternate. The
  executable declares no platform or minimum OS, and this is `codesign`'s
  legacy-compatible answer to such input; it is not evidence about ZynSign.
  The version floor in D1 comes from Apple's documentation, not from this
  comparison. What `codesign` emits for a real iOS 17 binary needs a real
  binary, which the current signer refuses (ZS-033).

### Not measured

- **Bundle tamper detection.** All five bundle mutations were rejected by
  `codesign`, but so was the unmodified bundle, so they show nothing yet.
- **An identity-signed reference.** The reference is ad hoc, so Apple's CMS
  signed attributes and its generated designated requirement were not
  compared.
- **Real binaries.** Only the synthetic executable model is signed; real
  application binaries and framework libraries are refused by the signer.
- **The device.** Nothing here reaches iOS: no AMFI or CoreTrust, no
  provisioning enforcement, no installation. The physical-device parts of
  E6, E12, and E14 stay open.
- **Trust.** The certificate is self-signed; static validation accepted the
  untrusted chain, which is macOS desktop behavior and says nothing about
  iOS.

## Evidence discipline

- A run records the runner image, the Xcode and OpenSSL versions, the run,
  and the commit. A conclusion is cited with its run.
- `codesign` acceptance is desktop evidence. It is never presented as iOS
  acceptance, trust, or installability, including in interface copy.
- A reference difference is only a divergence once the input explains
  nothing about it. Differences caused by the synthetic input stay labeled
  as such until real binaries exist.
- The register changes when evidence changes: a divergence is closed by a
  run that shows it gone, never by an edit to this record alone.

## Non-goals

- No change to signing output or format, Mach-O admission, or signature
  replacement.
- No `codesign`, `otool`, `ditto`, or OpenSSL call in product code.
- No private key, `.p12`, real certificate, real profile, real IPA, or
  Apple credential in the repository or in CI secrets. The throwaway key
  lives only inside the test process.
- No gating on `codesign` verdicts yet: the job is measurement until the
  register is short enough for verdicts to become expectations.
