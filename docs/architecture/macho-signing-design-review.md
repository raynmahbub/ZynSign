# ZS-026 implementation design review

Status: **Historical proposal, superseded by the implementation record.**
The [integration document](macho-signing-integration.md) now records the narrow
implemented scope, authoritative format evidence, and remaining test gates.
The text below preserves the design decisions considered before implementation.
A generic CMS/host-vector check is not an Apple-platform acceptance result.

## Recommendation

Implement the prerequisites inside the existing boundaries, with no dependency
or alternative private-key abstraction. Start with RSA PKCS#1 v1.5 and SHA-256.
Its fixed signature length removes the need for signing retries or speculative
CMS reserve slack. Keep the experiment separate from application signing policy.
A standards-valid CMS experiment alone does not satisfy the Apple-format gate.

## Proposed first supported request

| Input | First supported policy |
| --- | --- |
| Artifact | In-memory, unsigned, thin little-endian arm64 `MH_EXECUTE`; bounded synthetic fixture initially |
| Identity | Explicit identity ID resolved through `IdentityStore`; missing/unavailable is an error |
| Certificate | Matching public certificate from the identity store; RSA 2048-bit for the first fixture |
| CodeDirectory | One primary directory, version `0x20200` |
| Identifier | Explicit validated ZS-023 identifier |
| Team | Explicit optional ZS-023 team identifier, not authorization evidence |
| Hash | Full SHA-256 only; no truncation or alternate directories |
| Page size | Explicit 4096 bytes (exponent 12) |
| Flags | Explicit zero; reject ad-hoc and unknown flag combinations |
| Code limit | Explicit policy: derive signature offset; optional expected limit must match |
| Special slots | Explicit empty collection initially; nonempty input unsupported |
| Existing signature | Reject; replacement unsupported |
| Context | Synthetic single-image experiment, no provisioning-derived inputs |

These are project restrictions, not claims about all valid Apple binaries.
Reject fat images, dylibs, unsupported CPUs/subtypes, encrypted images,
unsupported load-command/layout forms, insufficient header slack, overlapping or
ambiguous segment layouts, and unsafe linkedit mappings before any signing call.
The fixture must have a real file-backed text/header mapping and a final
non-overlapping linkedit mapping; parser success alone is not layout admission.
Bundle, framework, extension, and nested-container orchestration is absent,
not inferred from the file type of an isolated executable.

## CMS profile decision

**Verified (standard):** [RFC 5652 sections 5.2–5.5](https://www.rfc-editor.org/rfc/rfc5652.html)
allows detached content. With signed attributes, content-type and message-digest
attributes are mandatory, and the primitive signature covers the DER SET OF
encoding of attributes, not their on-wire context-specific tag.

**Verified (Apple source):** [Security's signer](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/signer.cpp)
uses detached CMS over the serialized CodeDirectory and supports Apple
hash-agility attributes. It does not justify replacing CMS with raw signature
bytes, nor prove that a minimal generic CMS subset is Apple-compatible.

Proposed CMS skeleton: outer SignedData ContentInfo; SignedData version 1;
one SHA-256 digest algorithm; detached id-data content; one X.509 signer
certificate; one version-1 SignerInfo identified by issuer and serial; RSA
PKCS#1 v1.5 signature; no CRLs, timestamp, countersignature, or signing time.
Use content-type and message-digest signed attributes. Resolve the Apple
hash-agility attribute decision before fixing the final emitted profile.

Exact flow with attributes:

1. `contentDigest = SHA256(serializedCodeDirectory)`.
2. Insert that full digest into the message-digest attribute.
3. DER-encode and canonically sort the signed attributes.
4. `signingDigest = SHA256(DER_SET_OF_signedAttributes)`.
5. Submit exactly one ZS-021 digest request with
   `.rsaPKCS1SHA256Digest` through the existing capability.
6. Require a 256-byte signature for the admitted RSA-2048 key; finish CMS.

Do not sign `contentDigest` directly in this profile, rehash it as a message, or
silently choose a no-attributes profile. This is a necessary clarification of
the task's conceptual digest-to-signature flow, not a second signing operation.
A direct no-attributes profile is possible in generic CMS but is not approved
here as an Apple code-signing format.

**Open format gates:** confirm exact digest/signature AlgorithmIdentifier OIDs
and parameter encodings from their algorithm specifications and Apple CMS
implementation; establish hash-agility requirements/encodings for a single
SHA-256 CodeDirectory; independently decode a matching Apple-produced public
fixture. No custom attribute, guessed payload, or acceptance claim is allowed.

## Certificate and identity boundary

Extend `IdentityStore` with a narrowly scoped public-certificate retrieval
operation returning the existing `Certificate` type. `SecureIdentityStore`
should parse its existing stored DER and recheck the recorded fingerprint.
Never return `StoredSigningIdentity`, key references, or platform key objects.
Resolve the existing capability and verify identity ID, availability, supported
algorithm, and actual certificate/public-key association. Missing certificate
retrieval support must fail closed in other store implementations.

**Observed (repository):** `CertificateDERParser` already locates issuer and
serial, but exposes normalized metadata rather than the original issuer DER.
Extend that same parser to retain bounded original issuer and serial encodings
for CMS signer identification; do not reconstruct a distinguished name from
strings or create a second certificate parser. The CMS reader currently keeps
only signer serial bytes for issuer-and-serial identifiers. Extend it to retain
issuer DER too, so self-verification compares both, not serial alone. Continue
to use ZS-015 metadata and the existing public-key verifier.

## One-pass signing layout

Add a size-only CMS planner after the profile is fixed. Certificate bytes,
issuer/serial, attribute lengths, 32-byte digests, and a 256-byte RSA signature
make its exact size knowable before signing. Digest contents do not affect DER
length. Count all DER length octets, wrapper headers, and SuperBlob indices;
check arithmetic and resource ceilings before allocating. No placeholder
signature is an externally visible result.

Extend ZS-025 with prepare/finalize operations sharing its current mutation
validation. Prepare determines offset and aligned size from exact planned
SuperBlob length, writes final load commands and linkedit filesize, and returns
an immutable prepared prefix plus a layout token. Use existing layout arithmetic
and checked mutation helpers, not copies in the signing engine.

Set codeLimit to the token's signature offset and hash the prepared prefix,
including zero alignment padding. Finalize accepts only a region whose exact
serialized and padded lengths match the token, appends it without changing any
prefix byte, and reparses the output. The old append operation should delegate
to shared logic while preserving its current behavior and tests. No re-signing,
file relocation, silent resize, or mutation of hashed bytes is permitted.

## Verification and error gates

Before signing: validate request, certificate/key association, admitted Mach-O
layout, CodeDirectory, exact serialization and size plan. Test that all rejected
inputs cause zero signing calls. After signing: require exactly one call,
validate signature length, finish CMS and SuperBlob, finalize, and parse output.
Compare every requested field, region range, and prefix byte; recompute page
hashes and CodeDirectory digest from final bytes. Decode CMS independently of
its encoder, verify signer identity, algorithm identifiers, detached binding,
attributes, and signature using the existing certificate verifier. Unavailable
verification is failure, not an omitted check. Return no artifact on failure.

Keep structured failures by stage: invalid request/Mach-O, unsupported form or
algorithm, layout/code-limit, unavailable identity, capability failure,
CodeDirectory construction/serialization, CMS, SuperBlob, mutation, and
post-sign verification. Diagnostic values contain no payload or key internals.

## Implementation order and acceptance

1. Close the CMS format gates above; add literal independent DER vectors.
2. Add certificate retrieval and issuer/serial preservation with regression tests.
3. Add bounded CMS size planner/encoder and independent decoder checks.
4. Refactor ZS-025 prepare/finalize with byte-preservation tests.
5. Add the explicit request and orchestrator, reusing ZS-021/023/024/025.
6. Add full synthetic Mach-O round-trip and tampering tests, plus an independent
   host CMS verification harness using non-sensitive ephemeral test identities.
7. Run Swift build/XCTest on an Apple test host before declaring completion.

Tests must cover invalid DER lengths, overflow/resource limits, wrong issuer,
wrong certificate, incompatible algorithms, malformed key output, duplicate or
incorrect attributes, code/header tampering, region sizing, signature failure,
existing signatures, universal input, and deterministic structure/page hashes.
For fixed inputs RSA PKCS#1 v1.5 signatures are deterministic; do not generalize
that statement to future ECDSA support. A deterministic output test must fix
certificate bytes and every request input and exclude timestamps.

**Observed:** OpenSSL 3.0.20 is available as a potential host-side independent
verifier. No OpenSSL cryptographic experiment was run in this review. It must
not become a product dependency or runtime subprocess. Swift and Xcode are not
available here. Unit, simulator, physical-device, and Apple acceptance results
remain unperformed. **Unknown:** platform authorization and installability.

Implementation follow-up: the AlgorithmIdentifier encodings were checked against
RFC 5754, and Apple's macOS non-embedded-policy verifier was inspected for its
explicit absent-hash-agility behavior. The reduced experimental profile uses
that limited evidence and an independent public CMS vector, not an
Apple-produced fixture or demonstrated iOS acceptance. The current integration
record, rather than this historical proposal, defines the implemented contract.
Apple-host Swift build and test execution remain required.
