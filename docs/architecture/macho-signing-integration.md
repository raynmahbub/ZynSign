# Mach-O cryptographic signing integration (ZS-026)

## Status and evidence

The controlled single-image pipeline is implemented, with independent public
vectors and focused tests. **Release verification remains incomplete:** no
Swift compiler, Xcode, simulator, or physical iOS device is available in the
implementation environment. The host vector checks below passed; they are not
execution of the Swift implementation. Do not promote this experimental path
to application signing or installation on the strength of those checks.

The initial CMS and pre-hash layout blockers are addressed by the narrow
construction profile and prepare/finalize contract described below. The earlier
[design review](macho-signing-design-review.md) records the proposal, not the
current implementation status.

Evidence reviewed on 2026-09-23:

- **Verified — format:** [Apple XNU `cs_blobs.h`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/cs_blobs.h)
  defines the CodeDirectory, embedded SuperBlob, signature slot `0x10000`,
  wrapper magic `0xFADE0B01`, and generic big-endian frame.
- **Verified — content boundary:** [Apple Security `signer.cpp`](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/signer.cpp),
  `signCodeDirectoryWithIdentity`, passes the entire serialized CodeDirectory
  to detached CMS. It does not put primitive RSA bytes directly in the wrapper.
- **Verified — limited verifier evidence:** [Apple Security `StaticCode.cpp`](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/StaticCode.cpp),
  the macOS, non-embedded-policy branch of `verifySignature`, verifies detached
  CMS and tolerates absent hash-agility attributes. This is not evidence that
  iOS embedded policy, CoreTrust, or AMFI accepts the same reduced profile.
- **Verified — CMS:** [RFC 5652 sections 5.1–5.6](https://www.rfc-editor.org/rfc/rfc5652.html)
  establish detached SignedData, signer identification, and the signed-attribute
  digest rules. [RFC 5754 sections 2.2 and 3.2](https://www.rfc-editor.org/rfc/rfc5754.html)
  establish SHA-256 with absent CMS digest parameters and
  sha256WithRSAEncryption with NULL signature parameters.
- **Inferred — project scope:** a single directly authenticated CodeDirectory
  and no alternate directories permit this deliberately reduced cryptographic
  experiment, with no hash-agility attributes. No Apple-specific attribute
  payload was guessed or invented. Platform-policy acceptance is **Unknown**.

## Supported scope and explicit request

`MachOSigningRequest` carries artifact bytes, an optional identity ID (missing
is a structured error), the existing `CodeDirectoryConstructionRequest`, a
signing algorithm, existing-signature policy, and explicit
`singleImageCryptographicExperiment` policy. The CodeDirectory request exposes
identifier, team identifier, version, flags, hash configuration, page size,
code limit, platform field, and special slots. There are no hidden profile or
bundle defaults and no raw private-key input.

Initial admitted model:

- One thin little-endian arm64 image, subtype zero, `MH_EXECUTE`, Mach-O flags
  `0x20`, reserved header word zero.
- Exactly two segment64 load commands: `__TEXT` then `__LINKEDIT`.
- Text begins at file offset zero, ends where linkedit starts at a 4096-byte
  boundary, and has exactly one nonempty `__text` section. Its file/VM mapping
  must agree, its offset is four-byte aligned (alignment exponent two), it
  covers the rest of text, and its flags are `0x80000400`. Relocations and
  reserved section fields must be zero. It establishes header padding capacity.
- Segment maximum protection is seven; initial protection is five for text and
  one for linkedit; segment flags are zero. VM addresses are 4096-byte aligned.
- Linkedit has no sections and ends at the input file end. Its existing virtual
  reservation must fit the result. Text and linkedit virtual ranges must not
  overlap or overflow. ZS-025 checks zero header slack and all mutation bounds.
- One primary version `0x20200` CodeDirectory; full SHA-256, 4096-byte pages,
  zero code-signing flags/platform, optional explicit team, empty special slots.
- RSA-2048 with PKCS#1 v1.5 SHA-256 digest signing; exactly one attempted private
  operation, never retries or algorithm fallback.

This intentionally synthetic executable model does not establish executable
behavior. Unsupported forms include universal containers, 32-bit/big-endian
images, other CPUs/subtypes, dylibs, other segment/load-command layouts,
encryption commands, alternate CodeDirectories, other hashes/key sizes,
ECDSA, nonempty special slots, and nonzero code-signing flags. No framework,
extension, nested-bundle, IPA, or installation orchestration is present. A
bundle role cannot be inferred from an isolated image's Mach-O file type.
Existing signatures are rejected; replacement is explicitly unsupported.

## Layout, code limit, and page hashes

`MachOCodeSignatureWriter.prepare` uses the existing checked ZS-025 layout and
mutation logic to finalize `ncmds`, `sizeofcmds`, `LC_CODE_SIGNATURE`, and
`__LINKEDIT.filesize` before hashing. Its immutable preparation token contains
only the finalized prefix and layout. `finalize` appends an exactly sized region,
refuses size changes, and reparses the result. Existing `append` delegates to
these operations; load-command mutation logic is not duplicated.

`codeLimit` must equal the ZS-025 planned, 16-byte-aligned signature offset.
It includes any zero padding between the original file end and the signature.
It is neither assumed to equal original file length nor final file length.
`CodePageHasher` hashes only `0..<codeLimit` of the prepared prefix. No signature
region byte participates. A caller-supplied mismatch fails before signing.

The CodeDirectory serializer now exposes its validated size layout. CMS size
is established with fixed-size digest/signature placeholders and checked by the
existing CMS reader; no private operation occurs during planning. Placeholder
bytes never escape as an artifact. RSA-2048 produces 256 signature bytes, so
actual digest/signature values cannot change the planned DER or region sizes.

## Cryptographic flow and signature structure

`SignMachOUseCase` orchestrates:

1. Validate request, parse/admit input, and establish the explicit code limit.
2. Retrieve the public certificate through `IdentityStore.signingCertificate`;
   parse it through the existing certificate parser, checking metadata and key
   characteristics. Plan exact CodeDirectory/CMS/SuperBlob lengths.
3. Prepare final layout; construct and validate the CodeDirectory through
   ZS-023 using page hashes of the final prefix; serialize the real directory.
4. Compute `SHA256(serializedCodeDirectory)` including its header and full length.
5. Build two canonical CMS signed attributes: id-data content-type and the full
   CodeDirectory digest as message-digest. Hash their DER **SET OF** encoding.
6. Resolve the existing capability; check identity ID, availability, RSA, and
   algorithm support. Call `CapabilitySigningEngine` exactly once with that
   signed-attributes digest under `.rsaPKCS1SHA256Digest`.
7. Construct detached CMS SignedData, the wrapper, ZS-024 SuperBlob, and ZS-025
   region. Finalize without changing any prepared-prefix byte.
8. Reparse and self-verify before returning any artifact.

The primitive signs the signed-attributes digest, not the CodeDirectory digest
directly. The latter is authenticated through message-digest. CMS uses one
version-1 issuer-and-serial SignerInfo, one certificate, SHA-256, and
sha256WithRSAEncryption. No eContent, chain building, CRLs, time, timestamp,
unsigned attributes, hash-agility attributes, or alternate directories are
emitted. This is standard CMS inside the established Apple wrapper, not a
custom opaque signature format.

The existing Mach-O parser also retains section and segment mapping/protection
metadata so admission rejects unmodeled relocations and ambiguous file/VM
mappings without creating another parser.

The existing certificate parser now preserves original issuer and serial DER
for CMS, and the existing CMS reader preserves issuer DER for comparison. No
second certificate parser was introduced. Two missing throwing-call markers
in the touched certificate parser and a shadowed CMS reader function name were
also corrected while integrating those paths.

## Identity, provisioning, and security boundaries

The existing store exposes only the existing public `Certificate` value in
addition to its existing capability. Other store implementations default to a
structured certificate-unavailable failure. The secure store rechecks the
certificate fingerprint; its key resolver continues checking actual public-key
association. No private key, platform key object, registry record, or locator is
returned to the signing use case or presentation. Post-sign verification also
binds the result to the retrieved certificate.

No private-key export, serialization, logging, temporary file, runtime shell,
private API, or dependency was added. The production pipeline is in-memory and
never executes the input. Certificate/CMS bytes are not included in errors.
Stage-specific errors separate malformed input, unsupported forms/configuration,
identity/capability failures, layout/code limit, construction, serialization,
digest, CMS, SuperBlob, mutation, and verification failures.

Non-zero-based Data slices are refused before zero-based binary indexing.
Input/output are bounded to the existing parser's 256 MiB ceiling, with existing
page/count limits, checked offsets, and checked region arithmetic. CMS encoding
is bounded to 512 KiB and certificate input to the existing 256 KiB cap. The
writer checks capacity before prefix allocation. Transients contain only public
artifact/digest/signature data; no key bytes enter Swift buffers to erase. Swift
copy-on-write memory is not claimed to provide guaranteed zeroization.

No profile data enters this request. No parsed profile is promoted to trusted
input. A later profile-dependent application path must consume ZS-020 validation
and must not reuse this experimental policy as a bypass. Certificate validity,
provisioning validity, and platform authorization are explicitly not performed.

## Verification and test record

Production self-verification parses the final Mach-O and SuperBlob, requires
exactly a CodeDirectory and CMS entry, checks code limit and region extent,
checks zero trailing padding, reconstructs all requested CodeDirectory fields
and page hashes from final bytes, and compares the complete serialization. It
recomputes the content digest, decodes CMS through the separate existing reader,
checks certificate/issuer/serial, digest/signature algorithms, canonical
attributes and content binding, then uses the existing public-key verifier.
Missing verification support fails closed. No artifact returns on failure.

The two new test suites contain 25 XCTest cases.
`MachOSigningIntegrationTests` covers the complete independent vector,
structure/hash determinism, CMS length/encoding, request rejection, malformed
and universal inputs, existing-signature policy, header slack, capability and
signature failures, tampering, and prepare/finalize byte preservation.
`MachOSigningAppleTests` checks the independent vector using Security and a
real ephemeral RSA identity. Its test certificate is issued in setup; each
measured Mach-O request performs exactly one signing call. Private keys are
never serialized or retained in fixtures. The portable vector capability is
explicitly a replay double, not a private-key operation.

**Actually run:**

- `python3 Tests/Host/verify_macho_signing_vector.py`: passed independent field,
  offset, padding, byte-preservation, page-hash, and signed-attribute checks.
- OpenSSL 3.0.20, called by that host-only check: verified the public detached CMS
  with the exact CodeDirectory; rejected changed CodeDirectory, signed attributes,
  and signature.
  `-noverify` deliberately skips certificate trust; it does not skip signature
  verification. This validates the independent fixture, not Swift execution.
- Grammar parsing of changed/new Swift files: passed; not Swift type-checking.
- Diff whitespace and documentation-link checks: passed.

**Not run:** Swift build/XCTest (including existing regression suites), Apple
Security execution, simulator, physical device, or Apple acceptance. An attempted
Swift toolchain download failed at TLS connection. Run the shared Xcode scheme,
including existing identity/certificate/CMS/CodeDirectory/SuperBlob/Mach-O suites,
before declaring ZS-026 fully verified.

**Requires experiment:** actual iOS capability behavior and final platform
acceptance. Structural validity, cryptographic validity, certificate validity,
provisioning validity, platform authorization, and installability remain separate.
RSA PKCS#1 v1.5 with fixed certificate/inputs and no time attributes is expected
to be deterministic; that claim must not be generalized to future algorithms.
No subsequent task, nested signing, packaging, profile modification, or
installation was started.
