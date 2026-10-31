# Phase 1 DER entitlement corrections — review record

**Scope:** bounded correction of confirmed Phase 1 validation, test, and documentation defects. This is not Phase 2 and does not enable DER in the application signing pipeline.
**Review status:** changes are awaiting manual review and Apple-platform test evidence.
**Suggested manual commit message:** `Fix Phase 1 DER validation defects`

See the [single-image DER review](single-image-der-review.md) for implementation semantics and remaining limitations.

## Corrections and evidence

- `EntitlementCanonicalValidator.validateValue` passes the same `ProvisioningProfileParsingLimits` through array and dictionary recursion. The recursive calls are covered by nested custom-limit model tests; this checkout already contained both arguments on initial inspection.
- XML-invalid scalar/control tests use only Swift-representable strings. They exercise model validation and the canonical XML serializer directly (`CanonicalPropertyListError.invalidString`). A malformed UTF-8 DER value is supplied as explicit bytes and tested at the decoder boundary. No test claims that an invalid `CodeSigningEntitlements` value reaches `DEREntitlementsSerializer`.
- DER framing precedence is: after validating the fixed header and magic, an in-range declaration below the 8-byte header is `.invalidBlobFraming`; a declaration greater than `maximumFramedLength` is `.payloadTooLarge`, even if fewer bytes are available; otherwise a declaration unequal to the available byte count is `.invalidBlobFraming`. Actual framed input longer than the supported maximum is rejected as `.payloadTooLarge` before header parsing. Tests cover both oversized declaration and ordinary in-range mismatch.
- There is no `EntitlementCanonicalValidator.nodeCount(of:)`. The provisioning-profile decoder, canonical model validator, DER decoder, and canonical XML serializer use separate counters. Their entitlement-tree semantics are aligned: each scalar or container value counts once; dictionary keys and the implicit root dictionary do not count. Focused tests exercise the node limit across profile decode, model construction, XML serialization and DER decode.
- The test using `NestedSigningTestIdentityStore` and `NestedSigningTestVerifier` is named `testFixedVectorIdentityVerifiesDERBindingAndRejectsTampering`. It proves test-double signing orchestration and DER/slot/digest binding, not RSA verification. Real Security.framework RSA tests remain in `MachOSigningAppleTests.swift`, conditionally compiled under `#if os(iOS)`.
- `MachOSigningAppleTests` uses `SecKeyCreateRandomKey` with RSA-2048 and `AppleSignatureVerifier`. The project test target supports `iphonesimulator` (iOS 17 deployment target), and `#if os(iOS)` includes iOS Simulator builds, so these tests are eligible for an iOS Simulator run. They were not run in this environment; eligibility is not a pass result.
- XML canonical serialization checks the configured document-byte limit before each line append, checks string length before escaping, and base64-encodes data in bounded 57-byte chunks. DER serialization still constructs writer/pair buffers before `DEREntitlementsBlob` enforces the 1 MiB payload cap; this remaining allocation-bound limitation is documented as follow-up in the review note.
- DER remains experimental and disabled by default in the application pipeline and signing coordinator. Their explicit refusal gates are unchanged.

## Validation status for this correction

The final `Scripts/ci/docs_check.sh` result is recorded below after running the checker on this version of the documentation. Other checks and host test availability are reported in the agent's review summary; this file does not treat unrun checks as passed.

| Check | Result |
|---|---|
| `Scripts/ci/architecture_guard.sh` | **Pass** — 8 rules, no boundary violations |
| `Scripts/ci/security_scan.sh` | **Pass** — no secret material detected; gitleaks history scan unavailable |
| `Scripts/ci/dependency_check.sh` | **Pass** — project remains dependency-free |
| `Scripts/ci/docs_check.sh` | **Pass** — 105 pages, 0 errors, 0 warnings (re-run for this correction) |
| Full Python host suite | **Pass** — 165 tests |
| Swift parser, focused typecheck, targeted XCTest | **Unavailable** — Swift and Xcode tools are not installed |
| SwiftLint / SwiftFormat | **Unavailable** — neither tool is installed |
| Xcode build, XCTest, iOS Simulator RSA tests | **Not run** — Xcode/iOS Simulator unavailable |

## Acceptance limits

This report is a review artifact, not a release, platform-interoperability, or cryptographic-acceptance claim. The DER grammar and canonical bytes still require Apple/tool interoperability validation. No install/device/AMFI/CoreTrust result is claimed. Manual review and Apple-platform test evidence remain required before any Phase 2 work.
