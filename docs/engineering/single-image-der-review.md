# Single-image DER signing review

Status: **Experimental / blocked on Apple-platform validation**. This is not an installation or launch claim.

The single-image metadata option defaults off. When enabled for the isolated `SignMachO` experiment, it derives XML and DER candidates from the same `CodeSigningEntitlements` model, applies the project's v20400 CodeDirectory policy, and validates candidates before key use. The application signing pipeline and coordinator still refuse `emitDEREntitlements`; DER remains disabled by default and is not embedded in application signing output. See the [Phase 1 correction review record](der-phase1-acceptance.md).

## Validation and framing

`EntitlementCanonicalValidator` is the model's recursive canonical validator and string policy, not a shared node-count helper. `EntitlementCanonicalValidator.nodeCount(of:)` does not exist. The provisioning-profile decoder, canonical model validator, DER decoder, and XML serializer maintain distinct counters. The counter implementations follow the same tree semantics: a scalar or container value counts once; dictionary keys and the implicit root entitlement dictionary do not count. The model validator passes the supplied parsing limits unchanged to nested array/dictionary values. Focused regression tests cover root/key exclusions and bounded nested values across profile decoding, model construction, XML serialization, and DER decoding.

Malformed UTF-8 DER strings are tested with explicit byte fixtures at the DER decoder boundary. XML-invalid controls and noncharacters representable in Swift `String` are tested separately through model validation and the canonical XML serializer. Swift `String` cannot represent an unpaired surrogate scalar, and no test claims that a model-invalid value reaches `DEREntitlementsSerializer`.

The XML serializer's validation error is `CanonicalPropertyListError.invalidString`; the entitlement serialization boundary maps it to `EntitlementsError.invalidXMLString`. There is no `.invalidXMLCharacter` case in this path.

For framed DER input, after the minimum 8-byte header and magic are checked, an in-range declaration shorter than the header is `.invalidBlobFraming`; a declared total length above `maximumFramedLength` is `.payloadTooLarge` even when the supplied bytes are shorter; then an ordinary in-range declared/actual byte-count mismatch is `.invalidBlobFraming`. Actual input larger than the frame maximum is refused as `.payloadTooLarge` before header parsing. Payload copying happens only after the accepted framing is established.

The parser/model limits cap input dimensions. XML serialization checks `maximumDocumentByteCount` before each line is appended, enforces the configured string-byte limit before escaping, and emits data as 57-byte chunks (76 base64 characters) rather than creating a whole-value base64 string. A chunk/escaped line is materialized before its individual append check; cumulative output remains capped.

**DER serialization allocation limitation:** `DEREntitlementsSerializer` currently builds nested `DEREWriter` buffers and retains encoded dictionary-pair `Data` values before `DEREntitlementsBlob(derPayload:)` applies the 1 MiB payload limit. Thus the final payload is capped, but an oversized serialization can accumulate intermediate buffers beyond that cap before it is rejected. Adding incremental checked limits across nested writers and pair aggregation remains follow-up work; no general serializer rewrite is part of this correction.

## Test and cryptographic evidence

`DEREntitlementCorrectnessTests.testFixedVectorIdentityVerifiesDERBindingAndRejectsTampering` uses `NestedSigningTestIdentityStore` and `NestedSigningTestVerifier`. It exercises fixed/test-double signing orchestration and DER/slot/digest tamper rejection; it does **not** prove RSA verification.

The separate `MachOSigningAppleTests.swift` suite is guarded by `#if os(iOS)`. Its setup generates an ephemeral RSA-2048 key using `SecKeyCreateRandomKey`, builds a test certificate from the public key, signs through Security.framework, and verifies through `AppleSignatureVerifier`. The project test target supports `iphonesimulator` with iOS 17, and `os(iOS)` includes Simulator, so these tests are eligible for a Simulator test run. This eligibility is not evidence that they passed; no Simulator result is claimed here.

Neither the test doubles nor the Security.framework tests establish Apple entitlement-schema acceptance, AMFI/CoreTrust acceptance, device installation, or broad interoperability. Those remain unproven.

## DER-disabled-by-default regression gate

`SignApplicationPipeline` and `SigningEngineCoordinator` retain refusal gates for requested DER entitlements. The isolated single-image experiment is not authorization to enable DER in the application pipeline. Keep the option disabled unless a separately reviewed project policy explicitly changes that gate.
