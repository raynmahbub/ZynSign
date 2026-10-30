# Single-image DER signing review

Status: **Experimental / Blocked on Apple-platform validation**. This is not an installation or launch claim.

The single-image metadata option defaults **off**. When enabled, it requires entitlements and this project's v20400 CodeDirectory policy, derives XML and DER from the same `CodeSigningEntitlements` model, refuses a lossy or non-equivalent DER round trip before any private-key use, hashes the entire framed DER blob (`0xFADE7172`) into special slot 7, and includes it in the SuperBlob. Verification checks the decoded and re-encoded bytes, the prepared payload, and the slot-7 digest before accepting the CMS signature. The application pipeline and coordinator DER refusal gates remain in place; XML-only requests retain v20200 behaviour.

## Phase 1 — correctness hardening (five audit findings remediated)

This review records the Phase 1 scope the roadmap required: **do not expand DER into the application pipeline** — the `SigningEngineCoordinator` guard and the `SignApplicationPipeline` gate that refuses `emitDEREntitlements` before any allocation are unchanged — and instead close the five correctness defects identified in the DER audit on the single-image path. Each remains proven only by the hosted Xcode job; see *Evidence and limitations* below.

### 1 — XML and DER semantic equivalence via a single canonical model

**Finding.** XML and DER could carry different strings for the same claim set (XML's `Character.isValidXMLText` vs DER's raw bytes, differing handling of `U+0009`/`000A`/`000D` and of invalid XML characters such as lone surrogates, `0x00`, `0xFFFE`/`FFFF`).

**Fix.** Introduce `EntitlementCanonicalValidator` as the **single source of truth** for the entitlement string policy, key rules and node-budget calculation (`ZynSign/Domain/EntitlementCanonicalValidator.swift`). Both `CanonicalPropertyListXMLSerializer.isValidXMLText(_:)` and the XML/DER serializers and decoders delegate to it:

- The canonical XML Char production is `U+0009 | U+000A | U+000D | U+0020–U+D7FF | U+E000–U+FFFD | U+10000–U+10FFFF`; lone surrogates, `FFFE`/`FFFF` and all other controls are not representable.
- `CodeSigningEntitlements` validates every key and every string value through `EntitlementCanonicalValidator.validateKey(_:limits:)` / `validateValue(_:limits:depth:nodeCount:)` on construction; construction now throws `.invalidXMLString` for a disallowed string rather than silently truncating or coercing.
- `CanonicalPropertyListSerialization` and `DEREntitlementsSerializer` both enforce the same `invalidXMLString` refusal for keys and string values and reject `real` as `notRepresentable` on the DER path.
- `DEREntitlementsDecoder` validates every string it materializes (keys, UTF8String values) against `EntitlementCanonicalValidator.isValidEntitlementString(_:)`; a DER string that would fail the XML check is refused as `invalidXMLString` rather than delivered.
- String ordering for serialized output is `utf8Ascending` (UTF-8 code-unit order) in both paths.

**Round-trip proof.** `SigningMetadataPreparation.prepare(_:hashConfiguration:messageDigest:)` — the point where no private key has yet been used — now performs **two round-trip validations before returning**:

1. **XML:** `EntitlementsCanonicalSerializer.serialize(.dictionary(values))` → `EntitlementsPlistParser.parse` → `serialize` again → assert byte equality (canonicalization proof).
2. **DER (candidate, when `emitDEREntitlements` is true):** `DEREntitlementsSerializer.serialize` → `DEREntitlementsDecoder.decode` → `DEREntitlementsSerializer.serialize` again → assert byte equality; then decode the XML bytes back to claims and assert they equal the DER claims (`xmlClaims.hasSameSerializedClaims(as: derClaims)` → otherwise `.derXMLSemanticMismatch`).

A mismatch surfaces as `SigningMetadataError.entitlements(.derXMLSemanticMismatch)` or `canonicalizationError` / `invalidXMLString` / `notRepresentable` **before** `CryptographicSigningEngine` or `SignMachOUseCase` is reached. The new regression suite `DEREntitlementCorrectnessTests` pins all supported value types, Unicode, CR/LF/TAB handling, nested dictionaries and arrays through both encodings and asserts that re-encoding is byte-equal and cross-encoding is claim-equal.

### 2 — Bounded DER decoding (total-blob, payload, depth, collection, overflow)

**Finding.** The decoder could allocate before checking declared lengths, integer math was unchecked, and collection counts could be reached only after partial materialization.

**Fix.**

- `DEREntitlementsBlob(existingBlob:)` validates **magic → declared vs actual byte count → overflow-checked `declaredLength + header` → `maxFramedLength` (1 MiB + 8)** before the payload `Data` slice is copied; `payloadLength` is produced with `addingReportingOverflow(_:)` and a declared length larger than the supplied bytes is `invalidBlobFraming` or `payloadTooLarge`, never a truncated read.
- `DEREntitlementsDecoder.decode(blob:)` rejects empty input before allocation and rejects `blob.count > maxFramedLength`.
- `DEREntitlementsDecoder.decode(_:)` (payload) enforces `payload.count <= maxPayloadLength` (1 MiB) and a 2-byte minimal-SET guard before the `[UInt8]` copy.
- `DEREReader.readLength()` now uses `multipliedReportingOverflow` / `addingReportingOverflow` for each length byte and checks `contentLength <= bytes.count - offset - cursor - lengthOfLength` before advancing; a length that would overflow `Int` or claim past the supplied buffer is `malformedDEREncoding` or `resourceLimitExceeded`, never a slice past the buffer.
- Collection counts are enforced **before** each element is produced: the outer SET pair count, every SEQUENCE member count, and the inner `array` item count and `dictionary` pair count all compare `values.count` / `dict.count` / `items.count` against `limits.maximumCollectionCount` before materializing the next element.
- String and data lengths are validated against `ProvisioningProfileParsingLimits.maximumStringByteCount` / `maximumDataByteCount` before value construction.

**Coverage.** `DEREntitlementCorrectnessTests` constructs oversized declared-length blobs, empty and 7-byte-short blobs, wrong-magic blobs, 1 MiB-plus-one payloads, indefinite-length (`0x80`) and non-minimal length forms, leading-zero long forms, truncated elements, trailing bytes after the outer SET, and overflow-sized declared lengths; each asserts the redacted typed error named above and never a truncated copy.

### 3 — Consistent node budget

**Finding.** The model path and the decoder path counted value-tree nodes under slightly different rules, so one budget could pass while the other overflowed on the same claim set.

**Fix.**

- The node count for any `ProvisioningProfileValue` tree is now computed by **one function**: `EntitlementCanonicalValidator.nodeCount(of:)`. It counts every non-container value as `1` and every array/dictionary container and its recursive members, recursively, with checked `addingReportingOverflow(_:)`; overflow is `resourceLimitExceeded`.
- `CodeSigningEntitlements.init(values:limits:)` delegates to that counter (new `init(values:limits:)` overload) and enforces `maximumNestingDepth` and `maximumValueNodeCount` uniformly.
- `DEREntitlementsDecoder` now tracks `nodeCount` with the same semantics while walking DER values and validates against the **same `ProvisioningProfileParsingLimits`** it was constructed with; the final `CodeSigningEntitlements(values:limits:)` construction re-validates the budget so the decoder's running count and the model's counter agree.
- `CanonicalPropertyListSerialization` enforces a hard 10 000-entry limit per array and dictionary during encoding/decoding before emit (matching the `ProvisioningProfileValue` defaults), closing the path where a 50 001-entry container could be produced without an explicit error today.

**Coverage.** `DEREntitlementCorrectnessTests` checks exact-limit (50 000 nodes), over-limit-by-one, collection-exact-limit / over-limit, depth-exact / over-limit, and a manually constructed DER payload built under higher limits then decoded under tighter limits to prove the decoder enforces the same boundary as the model.

### 4 — Typed redacted diagnostics and round-trip checks

**Finding.** Several failure paths surfaced as generic `postSignVerification` or `invalidBlobFraming` where a typed, redacted error was required, and a few could include value bytes in the diagnostic.

**Fix.**

- `DEREntitlementsBlob.existingBlob` distinguishes `invalidDERMagic` (wrong `0xFADE7172` word) from `invalidBlobFraming` (declared length mismatch) and `payloadTooLarge` (declared > `maxFramedLength`), so callers can render the right recovery sentence without revealing bytes.
- `DEREntitlementsDecoder` emits `emptyPayload`, `payloadTooLarge`, `malformedDEREncoding` (indefinite or non-minimal length, truncated element, trailing data, overflow), `unsupportedValueType` (REAL `0x09` or other tag outside the entailment grammar, including when wrapped), `invalidXMLString` (string failing the canonical Char policy), and `resourceLimitExceeded`.
- `SigningMetadataPreparation` maps `CanonicalPropertyListError.invalidXMLCharacter` → `SigningMetadataError.entitlements(.invalidXMLString)` and validates the DER candidate before returning; a bad XML string, a lossy DER round trip, and a DER/XML mismatch each have their own `EntitlementsError` case and never a generic framing error.
- `SignMachOUseCase.SignMachO.verify(artifact:request:certificate:)` preserves the six DER-specific `MachOSigningError.entitlements` cases the pipeline defines (`missingDEREntitlements`, `unsupportedDERCodeDirectoryVersion`, `invalidDERMagic`, `invalidBlobFraming`, `unsupportedValueType`, `malformedDEREncoding`, `derEntitlementsMismatch`, `derEntitlementsDigestMismatch`, `derXMLSemanticMismatch`) and only maps a generic `MachOParsingError.malformedSignatureBlob` to `invalidDERMagic` (bad magic) vs `invalidBlobFraming` (declared mismatch) using the embedded blob's magic/length, otherwise preserving the typed error; any `EntitlementsError` is carried out as `.entitlements` rather than collapsed to `postSignVerification`.
- `MachOSigningRequest.validate()` remains the typed gate for `missingDEREntitlements` and for `unsupportedDERCodeDirectoryVersion` (any `CodeDirectoryVersion != .v20400` when `emitDEREntitlements` is true), so refusal happens before key use.

**Coverage.** `DEREntitlementCorrectnessTests` hits each error kind directly: missing entitlements with `emitDEREntitlements: true`, wrong version, wrong magic, wrong length, REAL, malformed, and — via end-to-end `SignMachO` — slot-hash mismatch (`derEntitlementsDigestMismatch`), embedded-bytes mismatch (`derEntitlementsMismatch`), and missing DER slot (`.missingDEREntitlements`). No diagnostic under test contains value bytes; see `SigningMetadataIntegrationTests` and the `DEREntitlementCorrectnessTests` per-mode sections.

### 5 — Genuine cryptographic regression evidence

**Finding.** Existing suites exercised the DER slot/digest binding through a fixed-signature test double (`MachOVectorIdentity` replays the same 256-byte RSA signature for any input), so binding was proven only under a replaced verifier.

**Fix.**

- The existing `MachOSigningAppleTests` — `#if os(iOS)` real `Security.framework` primitive suite — already generates an ephemeral RSA 2048-bit key per test with `SecKeyCreateRandomKey`, self-signs a certificate on that key, exposes **only** the public key bytes to the certificate builder, and signs **digests** with `SecKeyCreateSignature(.rsaSignatureDigestPKCS1v15SHA256)` behind `SigningCapability.sign(data:algorithm:)` (the capability never exports a private key handle). It checks:
  - Independent fixture vector verifies under `AppleSignatureVerifier` (real digest + real SecKey verify).
  - `EphemeralMachOIdentity` signs one image once, verifies the full artifact through the same certificate, proves the slot-7 digest covers the exact framed DER blob bytes, and rejects a torn DER byte, a torn code byte, and a wrong certificate.
- This increment adds `DEREntitlementCorrectnessTests.testRealKeySignAndVerifyRejectsTampering()` as the host-runnable cryptographic binding proof (runs on any runner): the fixed-vector identity signs a claim set containing `get-task-allow` + `aps-environment`, verification succeeds, a DER-byte flip is rejected as `derEntitlementsMismatch`, a code-page flip as `postSignVerification`, and a wrong certificate as invalid. The fixed-vector double here proves the pipeline's DER/slot/digest wiring; the `MachOSigningAppleTests` suite proves RSA mathematics when the platform provides it — the two together are the evidence this increment claims, not a single double standing in for a real key.

No file of private-key material, certificate, or key handle is written; see the `security_scan.sh` exclusion of `Tests/**/CertificateFixtures*`.

## Evidence and limitations

- Apple's [XNU cs_blobs.h](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/cs_blobs.h) defines slot 7 and magic `0xFADE7172`; it names version `0x20400` for exec-segment fields, not a DER-specific minimum. The version restriction is repository policy.
- [ldid](https://github.com/ProcursusTeam/ldid/blob/af86971ae72ec3ed3d0a699107c4e882324c941b/ldid.cpp) independently sorts full encoded dictionary members and rejects reals. Its encoder emits boolean true as `01`, while this implementation uses DER-canonical `ff` and its decoder accepts only canonical booleans. This difference needs actual Apple and independent interoperability testing; it is not evidence of Apple acceptance.
- OpenSSL `asn1parse` parsed a manually supplied synthetic two-pair DER fixture. It did **not** inspect bytes emitted by Swift or a signed Mach-O, and does not validate Apple's entitlement schema, set ordering, CodeDirectory binding, CMS or platform trust.
- Swift, Xcode, `codesign`, and `ldid` are unavailable in this environment. New and amended XCTest cases in this increment have not been compiled or executed here. No current independent signed-artifact inspection, Apple verification, GitHub Actions run, provisioning validation, install or device test was performed on this increment. A macOS Xcode run of the full suite — including the new `DEREntitlementCorrectnessTests`, `MachOSigningAppleTests`, and `DEREntitlementsDecodingTests` — followed by independent slot/hash inspection and authorized physical-device validation is required before broader use.
- `architecture_guard.sh` and `security_scan.sh` were executed on this increment and passed. `docs_check.sh` passed. The hosted **Xcode** job on the branch must still pass before any release claim.

## Regression protection

- **DER stays off by default.** No new call site sets `emitDEREntitlements: true` outside tests. XML-only requests retain v20200 behaviour.
- **Application pipeline refusal unchanged.** `SignApplicationPipeline.sign(_:)` still refuses `SignApplicationOptions(emitDEREntitlements: true)` at the top of `sign(_:)` before any `ArchiveReader`, inspection or copy, returning `.failed` with `signingMetadata(.invalidDER)`.
- **Coordinator refusal unchanged.** `SigningEngineCoordinator.sign(_:)` still refuses any `SigningEngineOptions.emitDEREntitlements: true` during `validating` before `validateBundle(for:)`, before a working copy, and before any signing.
- **Serializer ordering.** The DER serializer sorts complete DER-encoded dictionary members including nested dictionaries. General-purpose decoding remains permissive about SET ordering; the signing verifier enforces it by re-encoding. If parsing fails before the DER entry can be inspected, verification can still return `postSignVerification`; the typed-path coverage is documented above.
