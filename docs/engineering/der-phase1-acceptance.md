# Phase 1 acceptance — DER entitlement correctness hardening

**Branch:** `arena/fdda5dac-zynsign` (proposed as `arena/zynsign-der-correctness`; current session branch is fixed)  
**Base:** `de4f63f44239ca5dc6a4adcd1f7b4f428432c665` (`main`)  
**Suggested commit subject:** `fix(signing): enforce DER entitlement semantic consistency`  
**Date:** 2026-10-31  
**Reviewer for acceptance:** @raynmahbub (manual approval required before Phase 2)

## What this phase closes

Phase 1 of the roadmap fixes the five DER audit findings **without expanding DER into the application pipeline**:

1. XML and DER semantic equivalence — one canonical string policy, one node-budget counter, round-trip validation before key use.
2. Bounded DER decoding — total-blob, payload, depth, collection and overflow checks before allocation.
3. Consistent node-budget enforcement — exact and over-limit behaviour identical in the model, XML and DER.
4. Typed redacted diagnostics — `missingDEREntitlements`, `invalidDERMagic`, `invalidBlobFraming`, `unsupportedValueType`, `malformedDEREncoding`, `derXMLSemanticMismatch`, `derEntitlementsDigestMismatch`, `unsupportedDERCodeDirectoryVersion`, `derEntitlementsMismatch` carried through `MachOSigningError`/`EntitlementsError`/`SigningMetadataError` without value bytes.
5. Genuine cryptographic regression evidence — real Security-primitive suite where available, plus host-runnable DER/slot/digest cryptographic binding tests.

## What changed (and what did not)

### Files changed
- `ZynSign/Domain/EntitlementCanonicalValidator.swift` **new** — single shared string/budget validator.
- `ZynSign/Domain/CodeSigningEntitlements.swift` — delegates `validateKey`/`validateValue` to canonical validator, adds `init(values:limits:)` overload, enforces `invalidXMLString`, sorts keys by `utf8Ascending`.
- `ZynSign/Domain/CanonicalPropertyListSerialization.swift` — enforces `10_000` collection-count hard limit per array/dictionary before emit.
- `ZynSign/Domain/DEREntitlements.swift` — overflow-checked declared length (`addingReportingOverflow`), payload `maximumPayloadLength + 8` cap before `Data` allocation, `Data` copy only after header validated, `write(value:)` rejects `real` as `notRepresentable`, string/collection/data limits via canonical validator, `writeDictionary` validates keys via validator.
- `ZynSign/Domain/DEREntitlementsDecoding.swift` — payload pre-check, outer-SET minimal-length guard, pair collection bound before each pair, key/string `isValidEntitlementString` → `invalidXMLString`, `readValue` UTF8String same, `readString` same, `readLength` overflow-checked `multipliedReportingOverflow`/`addingReportingOverflow` plus remaining-buffer check, final return via `CodeSigningEntitlements(values:limits:)`.
- `ZynSign/Domain/SigningMetadata.swift` — XML canonical round-trip (parse + re-serialize equality) before digest, DER candidate decode + re-encode equality + `xmlClaims` cross-check before `slotDigest`, maps `CanonicalPropertyListError.invalidXMLCharacter` → `canonicalizationError`.
- `ZynSign/Application/SignMachO.swift` — verify preserves DER typed errors, maps `MachOParsingError.malformedSignatureBlob` to `invalidDERMagic` vs `invalidBlobFraming` via embedded blob magic/length, distinguishes `MachOParsingError` from `EntitlementsError` when `emitDER` is true, `derXMLSemanticMismatch`/`derEntitlementsMismatch` carried.
- `Tests/ZynSignTests/DEREntitlementCorrectnessTests.swift` **new** — executable regression for the five findings.
- `docs/engineering/single-image-der-review.md` — records Phase 1 scope, fixes and evidence/limitations.
- `docs/engineering/der-phase1-acceptance.md` **new** — this report.

### Files not changed (regression protection)
- `SigningEngineCoordinator` still refuses `emitDEREntitlements` in `validating` before bundle validation, working copy, or signing.
- `SignApplicationPipeline.sign(_:)` still refuses `SignApplicationOptions(emitDEREntitlements: true)` at the top of the method before any archive, inspection or copy.
- No new production call site sets `emitDEREntitlements: true`.
- No authenticated device transport, pairing, installation, guest execution, or unrelated redesign changed.

## Checks run in this environment (what is proven here, what is not)

| Check | Tool | Result | Notes |
|---|---|---|---|
| Architecture guard | `Scripts/ci/architecture_guard.sh` | **pass** — 8 rules, no boundary violations | Domain layer imports allowed list unchanged |
| Secret policy | `Scripts/ci/security_scan.sh` | **pass** — no private-key or certificate material outside fixtures | `Tests/**/CertificateFixtures*` excluded |
| Documentation | `Scripts/ci/docs_check.sh` | **pass** — 104 pages, 0 error, 0 warning; version claims `v0.1.0-alpha.3` build 9, 10 of 18 staged features, 3 never | Changelog/notes/product pages agree |
| SwiftLint | `Scripts/ci/lint.sh` | **skipped** — tool not installed in this environment | Hosted Quality job is the judge |
| SwiftFormat | `format.sh` | **not installed** in this environment | Hosted Quality job is the judge |

**What this environment cannot prove:** No Swift toolchain (`swift`/`xcodebuild` are not installed on this runner), so **no compilation and no XCTest execution was performed here**. The new and amended XCTest cases were authored against independently computed vectors but are **unproven until the hosted macOS Xcode job runs**. This report therefore conditions acceptance on that job passing (see *Gate* below).

## Tests new or amended — what each is supposed to prove

The hosted Xcode job must compile and execute the following suites; each row names the suite and the typed failure it is expected to demonstrate (no value bytes in diagnostics).

### `DEREntitlementCorrectnessTests` (new, `Tests/ZynSignTests/DEREntitlementCorrectnessTests.swift`)
- `testCanonicalStringPolicyRejectsSameInputsInXMLAndDER` — same invalid set (NUL, `01–1F`, `0B`/`0C`, `FFFE`/`FFFF`, lone surrogates) rejected as `invalidXMLString`/`invalidKey` by the model and as `notRepresentable`/`invalidXMLString` via `DEREntitlementsSerializer`.
- `testAllowedControlCharactersRoundTripIdentically` — `09` (tab), `0A` (LF), `0D` (CR) including `&#xD;` preservation round-trip identically through XML canonical parse+re-serialize and through DER encode→decode→re-encode, and XML/DER claims are claim-equal.
- `testUnicodeStringsArePreservedInBothEncodings` — `é`, `✓`, `日本語`, emoji, musical symbol, mixed with controls, all round-trip.
- `testNestedDictionariesAndArraysRoundTrip` — nested dicts, arrays, empty containers round-trip and XML/DER are claim-equal.
- `testAllSupportedValueTypesRoundTrip` — string, bool true/false, int (0, 128, −1, 300, −128), data, array, dict, Unicode.
- `testDERRejectsRealAndDERAndXMLStayConsistent` — `real` serializes in XML but is `notRepresentable` in DER and fails `SigningMetadataPreparation.prepare` with `.entitlements(.notRepresentable)`.
- `testFramedBlobLengthValidationBeforeAllocation` — empty/short framing → `invalidBlobFraming`; `0xFFFFFFFF` declared → `payloadTooLarge` before copy; declared≠actual → `invalidBlobFraming`; wrong magic → `invalidDERMagic`; framed count > `maxFramedLength` → `payloadTooLarge`.
- `testPayloadBoundsBeforeAllocation` — payload > 1 MiB → `payloadTooLarge`; empty payload → `emptyPayload`.
- `testMalformedHeadersAreRefused` — indefinite length, non-minimal length (short-form-when-long), leading-zero long form, truncated element, trailing bytes after outer SET, declared-length past buffer — each `malformedDEREncoding`.
- `testIntegerOverflowAndTruncation` — `byteCount > 4`, declared 4 GiB past buffer, declared 16 MiB past budget → `resourceLimitExceeded` or `malformedDEREncoding`, never a truncated materialization.
- `testNodeBudgetExactLimitAndOverLimit` — outer `SET` count enforced before each pair; model `init(values:limits:)` and `DEREntitlementsDecoder` share the 10-node test limit and refuse the 11th as `resourceLimitExceeded`; cross-limits DER built under higher limits then decoded under tighter limits is refused.
- `testCollectionCountExactAndOverLimit` — 4-entry `dict` at limit vs 5-entry over-limit on model construction and on DER decoder; array count at 4 vs 5.
- `testNestingDepthExactAndOverLimit` — depth-2 allowed (`k → dict(a → array(true))`), depth-3 `array(array(array(true)))` over-limit, both on model construction and on DER decoder via cross-limits payload.
- `testDefaultNodeBoundaryIsSharedBetweenXMLAndDER` — 50 000 nodes (1 array + 5 inner arrays + 49 994 leaves) decodes in both paths; 50 001st leaf refused as `resourceLimitExceeded`.
- `testDiagnosticsAreTypedAndRedacted` — `missingDEREntitlements`, `unsupportedDERCodeDirectoryVersion`, `invalidDERMagic`, `invalidBlobFraming`, `unsupportedValueType` (REAL `0x09`), `malformedDEREncoding`, and cross-check `derXMLSemanticMismatch` vs `canonicalizationError`/`notRepresentable`; no diagnostic contains the word `secret` or key material.
- `testDERVerificationDiagnosticsForEachFailureMode` — end-to-end `SignMachOUseCase` over one DER-signed image: flipped DER slot type → `missingDEREntitlements`; flipped blob magic → `invalidDERMagic`/`invalidBlobFraming`/`postSignVerification`; flipped CodeDirectory slot-7 hash byte → `derEntitlementsDigestMismatch`; flipped DER payload byte → `derEntitlementsMismatch`; truncated DER → `malformedDEREncoding`; flipped string tag `0x0C→0x09` → `unsupportedValueType`/`malformedDEREncoding`; each preserved through the `SignMachO` verify translation, not collapsed to generic.
- `testPipelineDERRefusalRemains` — `SignApplicationPipeline` with `emitDEREntitlements: true` returns `.failed` at `mainExecutable` with `"DER entitlements are not embedded"` before any copy.
- `testCoordinatorDERRefusalRemains` — `SigningEngineCoordinator` with `emitDEREntitlements: true` returns `.failed` at `validating` with `unsupportedInput` and `workingCopy == nil` — no bundle validation, no working copy, no signing.
- `testRealKeySignAndVerifyRejectsTampering` — `NestedSigningTestIdentityStore` signs `get-task-allow` + `aps-environment`, verifies, rejects DER-byte flip as `derEntitlementsMismatch`, code-page flip as `postSignVerification`, wrong certificate as invalid; `signCalls` proves verify does not sign.

### `MachOSigningAppleTests` (existing, `#if os(iOS)` — Apple platform only)
- `testIndependentPublicVectorWithSecurityVerifier` — independent fixture vector verifies under real `AppleSignatureVerifier` (real digest + SecKey verify).
- `testRealKeyBindsDERAndRejectsTampering` — ephemeral `SecKeyCreateRandomKey` RSA-2048 identity self-signs a certificate, signs one DER-bearing image, proves the slot-7 digest equals the exact framed blob digest, rejects torn DER byte, torn code byte, wrong certificate; `calls == 1` proves single signing.
- `testEphemeralIdentitySignsOnceAndVerifiesCompleteArtifact` — two sequential signs of the same request yield byte-identical artifacts (deterministic PKCS#1 v1.5, no time attribute), each verifies, torn artifact and wrong certificate rejected.

### `DEREntitlementsDecodingTests`, `EntitlementsTests`, `SigningMetadataIntegrationTests`, `MachOSigningIntegrationTests`, `CryptographicSigningEngineTests`, `AppleCMSSignatureVerifierTests` (existing)
Behavioral expectations are preserved; see `docs/engineering/single-image-der-review.md` for ordering and boolean-canonical (`ff` requires Apple/platform interop validation) notes. The new `EntitlementCanonicalValidator`-delegated construction must not change the golden-vector artifacts for metadata-free requests — `SigningMetadataIntegrationTests` pins this.

## Gate to `Unreleased` / `main`

No push, tag, or release occurs automatically. The following must all be true **in the hosted GitHub Actions run on this branch** before promoting the increment into `Unreleased` (and before any Phase 2 work begins):

1. **Build and test (Xcode)** — the test matrix passes on the scheme that builds `DEREntitlementCorrectnessTests` and the suites listed above, including the `#if os(iOS)` real-key tests where the runner supports them.
2. **Quality** — `architecture_guard`, `lint`, `format`, `complexity`, `dependency`, `docs`, and `security_scan` all pass in the hosted job (local passes of `architecture_guard`/`security_scan`/`docs_check` in this environment are not sufficient).
3. **Manual approval** — this acceptance report is reviewed and accepted by the designated reviewer; the decision is recorded on the PR or in `docs/internal/`.

Until those are met, Phase 2 (application-pipeline DER, or any expansion beyond the single-image `SignMachO` experiment) must not begin.

## Honest limitations that remain after Phase 1

- No Swift toolchain ran in this environment; the new tests are uncompiled and unexecuted here.
- No Apple verification (`codesign -v`, `ldid`, device AMFI/CoreTrust), no independent signed-artifact slot/hash inspection, no provisioning validation, no install, and no device test was performed here.
- The `ff` vs `01` boolean canonicalization difference with `ldid` and byte-exact agreement with Apple tooling still require experiment on real Apple artifacts.
- The pipeline and coordinator DER refusal gates are unchanged but still require the hosted Xcode run as regression evidence.

## Acceptance checklist

- [ ] Hosted **Build and test (Xcode)** passes on `arena/fdda5dac-zynsign` (all new and existing DER/signing suites).
- [ ] Hosted **Quality** passes (`architecture_guard`, `lint`, `format`, `complexity`, `dependency`, `docs`, `security_scan`).
- [ ] Manual reviewer has accepted this report; the acceptance is recorded on the PR or in `docs/internal/`.
- [ ] No `emitDEREntitlements: true` production call site was added.
- [ ] No device transport, installation, or guest execution behavior changed.

## Suggested branch and commit

If the reviewer accepts Phase 1, the preferred history for the merge into `main` is:

```bash
git switch -c arena/zynsign-der-correctness arena/fdda5dac-zynsign
git add ZynSign/Domain/EntitlementCanonicalValidator.swift \
        ZynSign/Domain/CodeSigningEntitlements.swift \
        ZynSign/Domain/CanonicalPropertyListSerialization.swift \
        ZynSign/Domain/DEREntitlements.swift \
        ZynSign/Domain/DEREntitlementsDecoding.swift \
        ZynSign/Domain/SigningMetadata.swift \
        ZynSign/Application/SignMachO.swift \
        Tests/ZynSignTests/DEREntitlementCorrectnessTests.swift \
        docs/engineering/single-image-der-review.md \
        docs/engineering/der-phase1-acceptance.md
# Optional: docs/architecture/signing-metadata.md if a follow-up doc change is accepted.
git commit -m "fix(signing): enforce DER entitlement semantic consistency" \
           -m "Establishes EntitlementCanonicalValidator as the single source of" \
           -m "truth for the XML Char policy, key rules and node budget; hardens" \
           -m "DER framing and length overflow checks before allocation with a" \
           -m "unified node-budget; enforces string equivalence between XML and" \
           -m "DER (CR/LF/TAB, NUL/lone-surrogate/FFFE rejection, Unicode) with" \
           -m "pre-key round-trip validation; and adds typed redacted diagnostics" \
           -m "and genuine generated-key cryptographic regression coverage." \
           -m "DER remains disabled by default and the application-pipeline and" \
           -m "coordinator DER refusal gates are unchanged."
git push origin arena/zynsign-der-correctness  # not automatic — only when ordered
```

The final merge into `main` is expected to be via a PR with the manual approval recorded, not a direct push.

## Sign-off

| Role | Name | Decision | Date |
|---|---|---|---|
| Author | Arena agent (Phase 1) | Ready for review — **do not merge** until gate passes | 2026-10-31 |
| Reviewer | @raynmahbub | _pending_ | _pending_ |
