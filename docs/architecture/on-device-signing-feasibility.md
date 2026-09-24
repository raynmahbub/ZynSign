# On-Device Signing Feasibility

## 1. Purpose

This document records a technical feasibility investigation for ZynSign's intended
core capability: an iPhone/iPad application that can inspect an IPA, perform
signing operations on-device, verify the resulting signatures, rebuild the IPA,
and determine what installation workflows are technically possible on
iOS/iPadOS.

It is research and architecture-feasibility documentation only. It does not
implement anything: there is no production code, no project file, no dependency,
and no experiment has been executed under this task. Every capability described
here is planned or hypothetical until the experiments in Section 15 close the
corresponding questions.

The document feeds the feasibility boundaries in
[architecture.md](architecture.md) (Section 6 there) and the findings record in
[phase-0-discovery.md](phase-0-discovery.md). Where those documents and this one
state the same platform question differently, this document supersedes them on
the strength of the research recorded here; where they record questions this
research could not close, their status stands.

Two separations are load-bearing throughout:

- **Signing and installation are different questions.** Producing a signed
  archive and installing that archive onto a device have independent
  preconditions. Section 13 treats installation on its own terms.
- **Feasibility is not implementation.** A classification of *Feasible* means
  evidence indicates the operation can be performed with available APIs or an
  independent implementation inside the application sandbox. It does not mean
  the operation is implemented, specified, or safe to start building.

### Implementation follow-up: secure identity boundary

The project now targets iOS/iPadOS 17.0. ZS-016 adds an uncomposed experimental
Keychain adapter and a signature-only capability boundary; see the
[security design](../security/signing-identities.md). This does not close E1 or
E7, does not establish PKCS#12 compatibility, and does not supersede Section
16.2's physical-device gate for production identity storage. Historical research
assumptions below remain recorded as originally investigated.

## 2. Product and Runtime Assumptions

The following assumptions frame every conclusion below.

- The product runtime is **iOS/iPadOS on iPhone and iPad**, inside the standard
  application sandbox. ZynSign is not a macOS application, and macOS is not a
  supported runtime platform.
- The signing workflow is intended to execute **on-device**. No desktop
  process, helper application, or network service is part of the runtime
  architecture.
- **macOS/Xcode exist only as developer-side tooling**: building ZynSign,
  generating controlled fixtures, independently inspecting and validating
  artifacts with `codesign` and related tools, and running experiments that
  cannot run inside the iOS runtime. macOS tooling is never a runtime
  dependency, and the application must not be designed around invoking it.
- The application **cannot execute command-line tools**. iOS does not provide a
  supported mechanism for a sandboxed application to invoke `codesign`,
  `security`, or any other utility; mandatory code signing prevents loading
  executables the platform did not approve. Every operation must be an
  in-process API call or an independent implementation. **[Verified]**
- The **deployment target is undecided** (architecture Section 6, item 17).
  Statements below that depend on API availability at a specific OS version are
  marked accordingly, and the experiments in Section 15 must be run against
  whatever deployment target is chosen.
- **No dependency has been selected.** Where this document says a capability
  needs "custom implementation," that means an implementation inside ZynSign's
  own source; whether some of it later comes from an approved third-party
  library is a deferred decision (architecture Sections 9 and 15).

## 3. Feasibility Summary

### 3.1 Classification vocabulary

Each major capability is classified using exactly the categories defined for
this research:

- **Feasible** — evidence indicates an iOS/iPadOS implementation is technically
  possible using available APIs and/or independent implementation.
- **Feasible with custom implementation** — the OS does not provide a complete
  high-level API, but the functionality appears implementable within the
  application's runtime constraints.
- **Requires experiment** — theoretical feasibility is insufficient; a small
  controlled prototype must validate the capability before architecture is
  finalized.
- **Restricted / platform-dependent** — the capability depends on Apple
  platform policy or APIs and cannot be treated as generally available.
- **Not currently established** — available information is insufficient for a
  responsible conclusion.

Classifications describe evidence, not effort. No classification below should
be read as an estimate of difficulty, cost, or schedule.

### 3.2 Classification table

| Capability | Classification | Basis (summary) |
| --- | --- | --- |
| SHA-1/SHA-2 hashing | Feasible | CryptoKit and CommonCrypto documented on iOS |
| RSA and ECDSA signature primitives with `SecKey` | Feasible | Security framework key APIs documented on iOS |
| Signing with a non-extractable Keychain private key | Feasible | Keychain extractability attributes documented; signing does not require export |
| Importing a `.p12` signing identity | Feasible with custom implementation | `SecPKCS12Import` available on iOS, but only with legacy PBE algorithms; workflow and error handling are ZynSign's responsibility |
| Certificate metadata inspection | Feasible with a bounded DER reader | `SecCertificateCopyValues` is macOS-only (**Verified** — Apple documentation, macOS 10.7+). `SecCertificateCreateWithData` exists on iOS (**Verified**) but is not a field dictionary |
| CMS (PKCS#7 SignedData) construction and verification | Feasible with custom implementation | No CMS API exists on iOS (vendor-confirmed); format is specified (RFC 5652) and buildable on available primitives |
| Mach-O reading and modification (headers, load commands, signature region) | Feasible with custom implementation | Format fully specified; structures shipped in the iOS SDK; no platform API exists or is needed |
| CodeDirectory / requirements / entitlements blob construction | Feasible with custom implementation | Formats specified in Apple open-source and Inside Code Signing technotes; no iOS API provides them |
| Bundle resource seal (`_CodeSignature/CodeResources`) construction | Feasible with custom implementation | Format specified; regeneration is content hashing plus plist encoding |
| Nested-code discovery and signing order | Feasible with custom implementation | Deterministic traversal rules; correctness must be fixture-validated |
| Provisioning-profile payload parsing | Feasible with custom implementation | Structure specified (TN3125); extraction requires custom CMS unwrap |
| Provisioning-profile container signature verification on-device | Requires experiment | Needs CMS verification plus certificate-chain policy against Apple issuers on iOS; no documented on-device equivalent of `security cms` verification |
| Code-signing certificate chain evaluation with an iOS trust policy | Requires experiment | `SecTrust` is available; the applicability of the Apple code-signing policy object on iOS is not established |
| Independent signature verification (CodeDirectory, resource seal, CMS, entitlement/profile compatibility) | Feasible with custom implementation | All inputs are readable and all primitives available; equivalence to platform validation cannot be claimed (Section 10) |
| iOS policy validation (what the platform itself will accept) | Restricted / platform-dependent | Only the OS performs install/launch validation; a ZynSign verdict is advisory |
| IPA extraction in the sandbox | Feasible | Standard sandboxed file workflows; performance and provider edge cases need experiments |
| IPA repackaging (ZIP writing) | Feasible with custom implementation | No documented system ZIP-container API on iOS; raw DEFLATE is available; container writer is ZynSign's to build or source |
| Security-scoped import, large-file handling, cancellation, cleanup | Feasible | Documented platform mechanisms; behavior under load and with hostile providers requires experiments |
| Direct installation of a produced IPA from ZynSign on-device | Restricted / platform-dependent | No documented public application-facing install API; legitimate channels are system- and policy-gated (Section 13) |
| External installation workflows (OTA manifest link, MDM, computer-side tools) | Restricted / platform-dependent | Documented Apple channels exist but require user actions, hosting, managed-device relationships, or a computer |
| On-device Keychain per-use authorization (e.g., biometrics on key use) | Requires experiment | Access-control APIs exist; their interaction with imported signing keys is not established |
| Extended-attribute fidelity across extract/repack cycles | Not currently established | Insufficient evidence about presence in IPAs and preservation in the iOS sandbox |

## 4. Cryptographic Capabilities

### 4.1 What the platform provides

Three layers are relevant and must not be conflated.

**Cryptographic primitives (available).** On iOS/iPadOS:

- `SecKey` operations — key creation from raw data (`SecKeyCreateWithData`),
  key generation, signature creation (`SecKeyCreateSignature`) and verification
  (`SecKeyVerifySignature`) for RSA (PKCS#1 v1.5 variants over SHA-1/SHA-2
  digests and over raw messages) and ECDSA (X9.62 over SHA-2 digests), plus
  algorithm-attribute checks (`SecKeyIsAlgorithmSupported`). **[Verified —
  Apple Security framework documentation]**
- Hashing — SHA-256/384/512 via CryptoKit; SHA-1 (where legacy formats demand
  it) via `Insecure` CryptoKit shims or CommonCrypto (`CC_SHA1`,
  `CC_SHA256`, and relatives). CryptoKit's public-key support covers
  P-256/P-384/P-521 and Curve25519 and **does not include RSA**; RSA work
  belongs to `SecKey`. **[Verified — Apple CryptoKit documentation]**
- Certificate handling — `SecCertificateCreateWithData` exists on iOS
  (**Verified** — Apple Security documentation, iOS 2.0+).
  `SecCertificateCopyValues` is documented for macOS 10.7+ and is not in the
  iOS API surface (**Verified**). It is not a source of subject, issuer,
  serial, or validity fields on the iOS 17 deployment target. `SecIdentity`
  pairing and `SecTrust` remain separate from metadata inspection. **[Verified
  — Apple Security framework documentation; the earlier claim that
  `SecCertificateCopyValues` was available on iOS was wrong]**
- Keychain storage — `SecItemAdd`/`SecItemCopyMatching` with accessibility
  classes, access-control objects (`SecAccessControlCreateWithFlags`), and the
  `kSecAttrIsExtractable` attribute, which suppresses
  `SecKeyCopyExternalRepresentation` when unset. Signing operations do not
  require extractability: a non-extractable private key can still sign.
  **[Verified — Apple Keychain Services documentation; extractability
  behavior additionally reported by Apple DTS]**

**Apple code-signing-specific operations (not available as APIs).** iOS does
not expose any API that constructs or validates Apple code-signature
structures. There is no on-device equivalent of `codesign`, of the macOS
`SecStaticCode`/`SecCode` validation family, or of blob-building services.
Community guidance and Apple DTS responses consistently treat on-device static
code-signature validation as unsupported on iOS. **[Verified — absence from
documented API surface; consistent Apple DTS statements]**

**CMS specifically.** Apple's CMS services (`CMSEncoder`/`CMSDecoder`) are
documented for macOS only. Apple DTS has stated repeatedly — in 2017, again in
2021, and confirmed again in 2023 — that the iOS SDK has no CMS support and
that callers must write or acquire their own. **[Verified — Apple DTS
statements in Apple Developer Forums]**

This was re-checked symbol by symbol against Apple's current platform
documentation before the provisioning-profile verification increment was
written, and the result is the same: `CMSDecoderCreate` lists macOS 10.5 with
no iOS entry, `CMSDecoderCopySignerStatus` lists macOS 10.5 with no iOS entry,
and `CMSSignerStatus` lists macOS and Mac Catalyst only. No symbol in the CMS
decoder family is available to an iOS 17 application, so none of them may
appear in a runtime code path or be hidden behind a port that iOS could never
satisfy. **[Verified — Apple Security documentation, per symbol]** The
primitives a substitute needs are documented for iOS:
`SecCertificateCreateWithData` (iOS 2.0+), `SecCertificateCopyKey` (iOS
12.0+), `SecKeyIsAlgorithmSupported` and `SecKeyVerifySignature` (iOS 10.0+),
including the message-based algorithms `.rsaSignatureMessagePKCS1v15SHA256`
and `.ecdsaSignatureMessageX962SHA256`, which keep hashing inside the
platform primitive. **[Verified — API availability. Their agreement with a
given certificate's own key fields, and their behaviour on device, remain
Requires experiment (E3, E4).]**

This distinction is the single most important cryptographic finding: the
*primitives* Apple code signing needs (SHA-256, RSA PKCS#1 v1.5 over a digest)
are available on iOS, but the *format assembly* around them — CMS SignedData
for both the Mach-O signature slot and the provisioning-profile wrapper — is
ZynSign's to implement or source.

The consequence has now been acted on for one direction of that format. Reading
and verifying an existing SignedData message is implemented inside ZynSign: a
bounded structure reader over RFC 5652 SignedData plus the documented key
primitives behind a narrow port, with no CMS API and no third-party ASN.1 or
crypto dependency. Constructing SignedData — which the Mach-O signature slot
needs — is still unbuilt and still the higher-risk half of this finding.

**Observed — ZS-021 built the generic half of the primitive layer on these
documented primitives.** The generic cryptographic foundation consumes no
platform API that this section does not already record as verified: digests go
through CryptoKit's hashing primitives, and signing and verification go
through the `SecKey` primitives behind the `CryptographicSigningEngine` and
`CryptographicSignatureVerifier` ports. No new API dependency was introduced
and no CMS, codesign, or format-assembly API appears. What this does not yet
establish: that the on-device behaviour of these primitives matches the
documented availability — that is still experiment E1 for the signing
direction (protected-key signature production and verification through the
Keychain adapter) and E4 for the verification direction's platform-status
mapping. The pure engine, request, result, digest, and failure-model tests do
not require a device; the iOS-gated signature-mathematics tests are the device
evidence when they run.

### 4.2 Key import, storage, and non-exportable use

- `SecPKCS12Import` is available on iOS and returns `SecIdentity` items into
  the application Keychain. **[Verified — API availability; Apple DTS confirms
  iOS-specific implementation]**
- The importer only supports **legacy PKCS#12 protection algorithms**
  (SHA1/3DES and SHA1/RC2-era PBEs). Packages produced by modern tooling with
  AES-based PBEs fail to import; Apple DTS guidance is to emit
  Apple-compatible (legacy) parameters. This is a **compatibility constraint on
  the `.p12` files ZynSign accepts**, not a total blocker: identities exported
  from Apple's own tooling are the compatible case. **[Verified — Apple DTS
  statements, 2021–2023]**
- Keys imported through `SecPKCS12Import` on iOS end up in the Keychain
  marked non-extractable — raw key bytes cannot be read back through
  `SecKeyCopyExternalRepresentation` — while remaining usable for signing.
  Whether ZynSign can *choose* extractability attributes at import time on iOS
  (as macOS `SecItemImport` allows) is **not established**. **[Verified for
  non-extractability via Apple DTS; Unknown for attribute control — see
  Experiment E7]**
- Signing with a stored key produces bytes through `SecKeyCreateSignature`
  under a named algorithm; the private key never enters ZynSign's address space
  as material it could log, export, or persist. This satisfies the
  architecture's "key material has one direction of travel" rule at the API
  level. **[Inferred — correct as a mechanism; guarantees still come from the
  OS, per architecture Section 14]**
- Keychain items are subject to data-protection accessibility classes
  (`kSecAttrAccessibleWhenUnlocked`, …`ThisDeviceOnly`, etc.) and to per-key
  `SecAccessControl` flags. Whether a signing key can be protected such that
  **each signature requires user presence** (biometrics/passcode) on iOS is
  **[Unknown — Requires experiment E7]**; the design must not assume it until
  measured.

### 4.3 What still requires custom implementation

| Operation | Why the platform does not cover it |
| --- | --- |
| CMS SignedData construction (for the `CodeDirectory` signature slot) | No iOS CMS encoder; structure specified by RFC 5652 |
| CMS SignedData parsing and verification (for profiles and self-verification) | No iOS CMS decoder |
| ASN.1/DER encoding for certificates' auxiliary needs, DER entitlements, DER profile payload | No public general ASN.1 writer in the iOS SDK |
| Code-signature blob assembly (CodeDirectory, requirements, entitlements) | No code-signing blob APIs on iOS (Section 5) |
| Hashing workflow over Mach-O pages and bundle resources | Orchestration over available hash primitives |

**Consequence:** the cryptographic *core* of on-device signing is Feasible on
documented APIs; the cryptographic *packaging formats* are Feasible with custom
implementation, and CMS is the highest-risk custom component because both
signature embedding and profile validation depend on it.

## 5. Mach-O and Code-Signature Requirements

### 5.1 What an on-device implementation must understand

All of the following are format facts an implementation must encode. None of
them requires a platform API beyond byte-level file access, and the structure
definitions are shipped in the iOS SDK (`mach-o/loader.h`, `mach-o/fat.h`) or
published in Apple's open-source Security headers. **[Verified]**

- **Mach-O container** — 32/64-bit headers, load-command enumeration, segment
  and section layout. The code signature is referenced by
  `LC_CODE_SIGNATURE` (command `0x1d`), a `linkedit_data_command` carrying a
  file offset and length inside `__LINKEDIT`.
- **Embedded signature superblob** — magic `0xFADE0CC0`, an indexed container
  of blobs: CodeDirectory (`0xFADE0C02`; one or more, e.g. SHA-1 and SHA-256
  alternates), requirements set (`0xFADE0C01`), XML entitlements
  (`0xFADE7171`), DER entitlements (`0xFADE7172`), and the CMS signature
  slot (blob-wrapper `0xFADE0B01` wrapping RFC 5652 SignedData) at slot
  `0x10000`. **[Verified — Apple open-source `cs_blobs.h` lineage; Inside
  Code Signing series (TN3125–TN3127, TN3161)]**
- **CodeDirectory** — identifier (typically the bundle ID), team identifier,
  hash type (SHA-1 = 1, SHA-256 = 2), page size as a log2 field (commonly
  4096), `codeLimit` (signed byte range, excluding the signature itself),
  executable-segment base/limit/flags, runtime version field, ordinary hash
  slots covering successive code pages, and **special slots** sealing related
  artifacts by hash: `−1` `Info.plist`, `−2` requirements blob, `−3`
  `_CodeSignature/CodeResources`, `−4` unused/application-specific, `−5`
  XML entitlements blob, `−7` DER entitlements blob. **[Verified — TN3126 and
  Apple open-source headers]**
- **Requirements** — opcode-encoded requirement expressions (designated
  requirement and internal requirements), specified in Apple open-source
  `requirement.h` and described in TN3127. **[Verified]**
- **Entitlements** — claimed entitlements exist twice: as an XML blob in the
  superblob and, on modern signatures, as a DER-encoded blob; both are sealed
  by special slots. **[Verified — TN3125; `cs_blobs.h]**
- **CMS signature** — binds the CodeDirectory to a signing certificate chain;
  contains the signer's certificate(s) and a signature over the CodeDirectory
  content (with authenticated attributes per CMS). **[Verified as to role —
  TN-series and RFC 5652; exact attribute set produced by Apple's signer is
  [Inferred] until compared against fixtures in E6]**
- **Bundle-level seal** — `_CodeSignature/CodeResources` records per-resource
  hashes (and rules for exclusions/inclusions) and is itself sealed by special
  slot `−3`. It is separate from the executable's embedded signature.
  **[Verified]**
- **Architectures** — device IPAs are expected to be thin `arm64`;
  `arm64e` slices appear as a CPU subtype and present no different signing
  mathematics (bytes are hashed as-is); fat/universal binaries carry a
  big-endian fat header and **each signed slice references its own
  signature region via `LC_CODE_SIGNATURE`**. An unsigned slice may have
  no such command. Simulator slices are distinguishable via
  `LC_BUILD_VERSION` platform fields. **[Verified for fat layout and slice
  signatures; Inferred for "no special arm64e signing rule"; to be confirmed
  against fixtures in E5]**
- **Encrypted executables** — FairPlay-encrypted App Store binaries
  (`LC_ENCRYPTION_INFO` with a nonzero `cryptid`) cannot be usefully re-signed
  for execution without decryption the platform does not offer. ZynSign must
  classify them as unsupported input rather than attempt signing.
  **[Inferred from platform behavior; product policy recommendation]**

### 5.2 Feasibility split

| Work item | Classification | Notes |
| --- | --- | --- |
| Reading headers, load commands, locating the signature region | Feasible with custom implementation | Pure byte parsing with `Data`/streams; SDK headers supply constants |
| Parsing superblob, CodeDirectory, requirements, entitlements | Feasible with custom implementation | Specified formats; hostile-input hardening required |
| Replacing/extending the signature region (offsets, `__LINKEDIT` sizing, 16-byte alignment of the signature data offset, `codeLimit` bookkeeping) | Feasible with custom implementation, **Requires experiment** for layout edge cases | Layout rules are observable in fixtures but not fully specified by Apple; E5 validates |
| Building a correct CodeDirectory (page hashing, special slots, exec-segment fields, version selection) | Feasible with custom implementation | Version/flag choices must match what current iOS accepts; E6 validates |
| Generating `CodeResources` | Feasible with custom implementation | Hashing plus plist emission; rule-set fidelity validated in E6 |
| Evaluating the full requirements language | Feasible with custom implementation (scope-limited) | A complete requirement VM is large; supporting only the constructs ZynSign actually produces/inspects is an acceptable scope decision — recorded as Open Question 6 |
| Fat-binary resign | Feasible with custom implementation | Per-slice signature replacement; product may restrict to thin `arm64` — Open Question 4 |
| Simulator/x86_64 slices | Not a feasibility question | Classify as unsupported input for installation purposes (product policy) |

**Observed in the repository (ZS-022):** The read-only portion of the first two
rows now has a [bounded Mach-O inspector](macho-inspection.md): thin/fat headers,
load commands, the signature region, SuperBlob index and blob headers, and
versioned CodeDirectory metadata. It does not decode requirements or entitlement
payloads, verify any signature, or decide what iOS/iPadOS accepts. Signature
alignment beyond the format-defined load-command and fat-slice rules, segment
coverage, page hashing and all construction rows still require fixture research
and E5/E6. This observation does not change the feasibility or experiment
classifications for signing.

## 6. Nested-Code Requirements

### 6.1 Categories to support

Code-bearing content inside an application bundle includes, at minimum:
frameworks (`Frameworks/*.framework`, including versioned framework layouts
with symlinks), dynamic libraries, app extensions (`PlugIns/*.appex` or
equivalent), nested applications (including watch companion structures where
present), widgets, and other plug-in bundles with their own executables,
`Info.plist`, and signatures. Ordinary resources are not code and are covered
by the container's resource seal instead. **[Verified for the main categories —
bundle structure documented by Apple and by TN3125; the complete location set
is [Inferred] and must be fixture-validated]**

### 6.2 Why signing order matters, and what must be discovered first

- The outer executable's signature seals nested content twice over: nested
  bundle files are covered by the outer `CodeResources` hashes, and nested
  code signatures are themselves files inside the outer seal. Changing any
  inner bytes invalidates the outer signature. Therefore **inner code must be
  signed before its container**, and the container's seal must be regenerated
  after all inner content is final. **[Inferred from seal structure; standard
  practice of Apple's own tooling — validated in E6]**
- Before signing, the implementation must have discovered: every code-bearing
  bundle; each bundle's executable and its architecture(s); each bundle's
  identifier, version, and existing entitlements; the dependency direction
  among nested components; and the set of files that will be hashed into each
  seal. Ambiguity (two candidate executables, unreadable nested
  `Info.plist`) must surface as an inspection diagnostic, never be guessed
  (architecture Section 17).
- Edge cases to design for, none yet validated: framework symlink chains;
  watch-app-plus-extension double nesting; extensions whose entitlements must
  be signed with the same identity as the host but their own bundle ID;
  nested `_CodeSignature` directories and `embedded.mobileprovision` inside
  extensions; dylibs that are also loaded by multiple containers; code in
  unexpected locations; and bundles nested deeper than the traversal expects.
  **[Inferred — each requires fixture coverage in E6]**

**Classification:** nested-code discovery and ordering are **Feasible with
custom implementation**; correctness on real-world packages is **Requires
experiment** (E6).

## 7. Provisioning Profiles

### 7.1 Structure — what can be stated with confidence

Apple's TN3125 establishes the following authoritatively **[Verified]**:

- A provisioning profile is **a property list wrapped in a CMS signature**
  (RFC 5652). The device checks the CMS signature before trusting the
  contents.
- The payload answers five questions: who may sign (`DeveloperCertificates`),
  what they may sign (`Entitlements` > `application-identifier`, an App ID of
  `team-prefix.bundle-ID` with optional wildcard), where it runs
  (`ProvisionedDevices`, or `ProvisionsAllDevices` for in-house/Developer ID),
  when it runs (`ExpirationDate`), and how it may be entitled (`Entitlements`
  allowlist).
- Profile types are distinguishable from these fields: development profiles
  carry `ProvisionedDevices` and permit `get-task-allow`; in-house profiles
  carry `ProvisionsAllDevices`; App Store profiles carry neither device list
  in the local-run sense and the final App Store app has **no embedded
  profile** (Apple re-signs during distribution).
- Profiles are normally embedded at `Payload/<App>.app/embedded.mobileprovision`.
- Modern profiles include a **`DER-Encoded-Profile`** property: a DER copy of
  the profile which, per Apple, is now the **source of truth** rather than the
  plist view. In the DER form, `DeveloperCertificates` entries are stored as
  SHA-256 checksums of the certificates rather than full certificates.

Additional fields commonly present (UUID, `Name`, `CreationDate`,
`TeamIdentifier`, platform list, Xcode-managed markers) are part of the plist
view; their exact roles are **[Inferred from observed profiles]** and must be
read, not assumed.

### 7.2 What an on-device implementation can parse locally

- Extracting the payload plist from the CMS container requires **CMS
  parsing** — content info, certificates, signer info — which iOS does not
  provide (Section 4.1). With a custom CMS unwrap, the payload plist (and the
  nested DER payload) are ordinary structured data readable with plist/DER
  parsers. **Classification: Feasible with custom implementation.**
- All compatibility checks ZynSign needs are then pure data comparisons:
  bundle-ID/wildcard match against the application identifier, team-prefix
  consistency, certificate presence in `DeveloperCertificates` (full DER in the
  plist view; SHA-256 match in the DER view), expiration versus current time,
  device authorization against the running device's identifier when the
  product ever obtains one legitimately (Open Question 9), and profile type
  versus intended distribution. **Classification: Feasible** (domain logic).

**Observed — ZS-017 payload boundary and parser.** The implementation now has a
bounded `ProvisioningProfileInput`, a `ProvisioningProfilePayloadDecoder` port,
and a property-list payload parser. The parser preserves optional profile
metadata, exact application identifiers and device strings, typed entitlement
values, and certificate references; a separate validator evaluates required
fields and an injected-clock period. Tests use synthetic payloads only. This
closes neither CMS extraction nor authenticity: the application-layer result
marks container authenticity and authorization as `notEvaluated`, and the
archive inspection workflow does not read embedded profiles.

**Observed — ZS-019 policy stage.** The compatibility predicates this section
lists are implemented as domain rules over values that already exist: the
profile's application-identifier scope (exact, or a trailing wildcard treated as
a prefix test at a component boundary), the team identifiers the profile and a
certificate subject's structured organizational units declare, the profile's
validity period against an injected clock, the certificates the profile names
compared by SHA-256 fingerprint, entitlement claims compared per key against the
allowlist, the profile's declared platforms against the platforms the caller
establishes, and the profile's device list against a device identifier only when
a caller supplies a trustworthy one. A `compatible` result says the configuration
satisfies ZynSign's rules; it does not say the platform will accept it.

**Observed — ZS-020 integrated pipeline.** The three stages are now sequenced by
one application-layer use case: the container is verified, the payload is parsed
only from a verified container, the parsed profile is structurally validated, the
signer and profile certificates are related, and the ZS-019 predicates are applied
to an authenticated payload — in that order, with no rule re-implemented in the
integration layer. A run reports four separate states about a profile (discovered,
parsed, authenticated, compatible with this application and signing configuration)
plus structural validity and the certificate relationship, and its integrated status
is `valid` only when every required stage passed and the policy evaluation was
`compatible`; `invalid` requires a definite rejection by some stage; `unsupported` is
reserved for coherent input outside supported capability; everything else is
`indeterminate`, including a run with no profile to validate. The predicate list in
§7.2 is therefore reachable from one call, and the reading it never does is
substitute for the platform's own validator: `trustEvaluation` stays `notPerformed`,
`authorization` stays `notEvaluated`, and a `valid` integrated result is not a claim
that the platform would accept, install, or run the application.

Since the same increment, one package path exists for the profile bytes themselves: a
read-only intake reads the `embedded.mobileprovision` entry of a library
application's bundle through the existing bounded archive reader and hands those
bytes to the pipeline. That closes the input half of §7.2's "requires a custom CMS
unwrap" chain for embedded profiles, without extraction, without any write, and
without changing the bundle explorer, which still reads no entry content.

**Open here.** Whether the platform's wildcard and profile-type rules agree with
the predicates above is not established. A trustworthy device identifier remains
Open Question 9, so the device rule defers instead of assuming the running device
is authorized, and no identifier is fabricated.

### 7.3 What must be cryptographically verified

Parsing is not trust. Before ZynSign *acts* on profile contents — selecting a
profile for a user, matching certificates, asserting entitlement
authorization — the CMS container signature should be verified:

1. verify the CMS signature over the payload using the signer certificate from
   the container;
2. evaluate the signer chain (Apple-issued developer/distribution
   intermediates) up to an Apple anchor using `SecTrust` with an appropriate
   policy;
3. only then treat payload fields as authorization input.

Step 1 is implemented: the container is read by ZynSign's own bounded SignedData
reader, the signer certificate is selected from the embedded bag by serial
number, the signed attributes are re-encoded as a `SET OF` and bound to the
encapsulated content through the message-digest attribute before any signature
check, and the signature is checked with `SecKeyVerifySignature` behind a port.
Its on-device behaviour is still unmeasured. **[Implemented — Observed in this
repository; Requires experiment (E3, E4) on device.]** Step 2 uses documented
`SecTrust` APIs, but whether a code-signing-appropriate policy object behaves
correctly on iOS for Apple's issuing intermediates is **not established**
(`kSecPolicyAppleCodeSigning` appears in iOS API release notes, but its
effective behavior on iOS is undocumented in detail). Step 3 is not implemented
at all: no entitlement, device, bundle, platform, or profile-type decision is
made anywhere in the repository. **Classification: Requires experiment (E3,
E13).**

Until those experiments close, ZynSign must not present profile contents as
"trusted" or "authorized." What it may present, and what the verification
result states separately, is: parsed, structurally valid, signature verified or
rejected or not evaluated, signer certificate related or not, trust not
performed, authorization not evaluated.

## 8. Entitlements

Four different things are routinely conflated; ZynSign's model must keep them
apart. The first three rules are stated by TN3125 **[Verified]**; the
consequences for ZynSign are **[Inferred]** from those rules.

1. **Entitlement metadata** — the claims embedded in a code signature (XML and
   DER blobs). Constructing these claims is a ZynSign implementation task.
   Writing an entitlement plist does **not** make an entitlement real: a claim
   that the profile does not allow, that the OS version does not know, or that
   the distribution model forbids will be rejected at install time or
   inert/denied at runtime.
2. **Entitlement compatibility** — every entitlement claimed by the app must
   appear in the profile's `Entitlements` allowlist (wildcards resolved per
   the profile's syntax); the reverse inclusion is explicitly allowed (the
   allowlist may contain claims the app does not make). Compatibility is a
   pure predicate ZynSign can and should evaluate *before* signing.
3. **Entitlement authorization** — comes from the profile's CMS signature
   (Apple issued it) plus device-level checks. ZynSign can verify the
   container signature (Section 7.3) but cannot *grant* authorization.
4. **Entitlement enforcement** — iOS itself enforces entitlements at
   installation and at runtime (kernel/AMFI and the system services involved).
   ZynSign has no influence over enforcement and cannot simulate it fully.
   **[Verified — Apple Platform Security, "App code signing process."]**

Cross-cutting interactions ZynSign must validate before attempting signing:

- `application-identifier` must be consistent with the bundle identifier being
  signed (exact or wildcard per profile rules) and with the team prefix.
- `com.apple.developer.team-identifier` must be consistent with the profile's
  team and with the identity's certificate subject association.
- The identity used must appear in the profile's `DeveloperCertificates`.
- Nested code: each extension/plug-in has its own bundle ID and claims; the
  covering profile must authorize each (wildcard or explicit). Host and
  extension are signed with the same identity in the normal flow.
- `get-task-allow` presence depends on profile type and affects
  debuggability, not installability, on the profiles where it is allowed.
- Changing entitlement claims after signing changes the entitlements blobs and
  therefore invalidates the CodeDirectory special slots — entitlement edits
  are signing operations, never metadata edits.

**Classification:** entitlement compatibility checking is **Feasible** (pure
domain logic over parsed inputs). Producing claim blobs is **Feasible with
custom implementation**. Any statement of "this app will be allowed to run with
these entitlements" remains **Restricted / platform-dependent** until the
platform actually accepts the artifact.

**Observed — how ZynSign compares claims (ZS-019).** The predicate above is
implemented per key, in key order, with property-list types preserved: string,
boolean, integer, real, sequence, and string-keyed dictionary values are compared
under explicit rules; an integer is not coerced into a real; a sequence is not
treated as a set, so an element-wise subset is reported as an open question
rather than a pass; a requested value the allowlist does not carry is a conflict;
and data, dates, and structures without an established rule are reported as
unsupported rather than approved. `application-identifier`,
`com.apple.developer.team-identifier`, and `get-task-allow` are decided by their
own rules and never by the generic ones, so the identifier claim and the
bundle-identifier check cannot drift apart. Absence is not treated as `false`: a
profile with no `get-task-allow` claim does not authorize a request for `true`,
and a request for `false` where the profile authorizes `true` stays an open
question rather than a pass or a conflict. Nothing strips, rewrites, or
synthesizes a claim, and nothing here asserts enforcement — which remains
platform behaviour, as rule 4 above states.

## 9. Certificates and Signing Identities

The architecture already fixes the conceptual vocabulary (architecture
Section 7). Feasibility maps onto it as follows.

| Concept | On-device availability | Notes |
| --- | --- | --- |
| Certificate | Feasible for inspection | DER bytes are classified by a bounded reader. `SecCertificateCopyValues` is not available on iOS (**Verified**). `SecCertificateCreateWithData` can build a platform object later (**Verified**, iOS 2.0+); inspection does not retain one. Uncommon fields are preserved or skipped, not fetched from a macOS-only dictionary |
| Private key | Feasible (as a Keychain-resident secret) | Present only as a `SecKey` reference; non-extractable after `.p12` import |
| Signing identity | Feasible | `SecIdentity` = certificate + matching key, obtained from `.p12` import |
| Keychain item | Feasible | Accessibility, access groups, and deletion semantics documented; app-specific design required |
| Cryptographic signing capability | Feasible | `SecKeyCreateSignature` under a supported algorithm; availability must be checked per key/algorithm |
| Provisioning profile | Feasible to parse; signature verification Requires experiment | Section 7 |

Workflow steps and their status:

- **Import** — accept a user-selected `.p12` (through the same document-access
  paths as any other file, Section 12), prompt for the passphrase, import via
  `SecPKCS12Import`, retain the resulting identity in the Keychain, discard
  the source bytes. Constraint: legacy PBE only (Section 4.2). Wrong
  passphrases and modern-encoded packages are expected, designed-for failure
  modes, not crashes. **Classification: Feasible with custom implementation.**
- **Inspect** — read subject, issuer, serial, validity interval, and public-key
  algorithm/size; report expiry independently of key availability (architecture
  Section 7 rule). **Classification: Feasible.**
- **Associate with a profile** — match certificate DER (or its SHA-256 in the
  DER profile view) against `DeveloperCertificates`. **Classification:
  Feasible** once profile parsing exists; trust in that association still
  depends on container verification (Section 7.3).
- **Determine usability** — a present certificate is not a usable identity:
  key presence, algorithm support, expiry, and profile coverage are separate
  predicates with separate diagnostics. **Classification: Feasible** (domain
  rules plus one capability probe).
- **ZynSign cannot mint Apple certificates.** Certificate issuance stays with
  the Apple developer portal and its tooling; the product consumes identities
  the user already possesses. **[Verified — certificate issuance is an Apple
  service; TN3161]**

**Security/API limitations to design around:** imported keys should use
device-only accessibility; identities must never be exportable through any
ZynSign code path; whether per-use user presence is possible is open
(E7); Keychain items created by ZynSign are wiped when the app is deleted
(uninstall semantics are a product consideration, not a defect).

## 10. Verification

### 10.1 Layers, and who can perform them

| Layer | What it checks | Can ZynSign do it on-device? |
| --- | --- | --- |
| CodeDirectory verification | Page hashes over executable bytes; special-slot hashes over `Info.plist`, requirements, `CodeResources`, entitlement blobs | **Yes — Feasible with custom implementation** (re-hash and compare; all inputs local) |
| Resource sealing | Recompute `CodeResources` entries under the recorded rules | **Yes — Feasible with custom implementation**, subject to rule-set fidelity (E6) |
| Requirements evaluation | Interpret requirement opcodes (designated/internal) | **Yes, scoped — Feasible with custom implementation** for the subset ZynSign supports; full-language parity is an open scope question |
| CMS signature on the CodeDirectory | Extract signer info, verify signature with the embedded certificates using `SecKeyVerifySignature` | **Yes — Feasible with custom implementation** (custom CMS parse + available primitives) |
| Certificate-chain verification | Validate the signer chain to an Apple anchor under a suitable policy | **Partially — Requires experiment** (`SecTrust` available; code-signing policy behavior on iOS unestablished, E13) |
| Provisioning compatibility | Profile signature + type + expiry + app ID + team + certificate + (device) | **Partially — Implemented** for parsing, structural validity, container signature verification, certificate relationship, the policy predicates of ZS-019 (identifier scope, team, validity, certificate, entitlements, platform, and device with a supplied identifier), and their integrated one-call pipeline in ZS-020, which stages and reports each state separately; **Requires experiment** for the chain-trust step and for whether the platform agrees with those predicates |
| Entitlement compatibility | Claims ⊆ profile allowlist, identifier consistency | **Yes — Feasible, implemented as typed per-key rules** (ZS-019); enforcement remains platform-side |
| iOS policy validation | Everything the platform actually enforces at install/launch (AMFI, kernel checks, trust decisions, version-specific acceptance) | **No — Restricted / platform-dependent.** ZynSign cannot execute the platform's validator, and no public iOS API exposes it |

### 10.2 What a ZynSign verifier may and may not claim

- A ZynSign verification result must be labeled as **ZynSign verification**:
  the artifact is internally consistent (hashes, seals, cryptographic bindings,
  profile and entitlement compatibility as ZynSign understands them).
- It must **never be presented as equivalent to Apple's install-time or
  launch-time validation**. The platform applies checks ZynSign cannot see or
  reproduce (policy decisions, OS-version acceptance of entitlements and
  signature versions, trust decisions, revocation and provisioning state on
  the actual device). **[Verified as a boundary — platform validation is
  system-performed; Inferred as to the exact set of platform-only checks.]**
- Divergence is expected and must be handled as data: experiment E14 compares
  ZynSign verdicts, developer-side `codesign --verify` results, and real
  install outcomes, and any disagreement is recorded as a discrepancy (Section
  16), not resolved by assumption.
- Verification must be implemented independently of signing state
  (architecture Section 5): it re-derives everything from bytes and public
  material.
- A verified provisioning-profile CMS signature is a statement about bytes and
  one public key: the payload is the payload that key signed. It is not evidence
  that the signer's certificate is trusted, that Apple issued it, that it is
  unrevoked, that ZynSign holds the matching private key, or that the profile
  authorizes an application, a device, or an entitlement. Those are separate
  states and are reported separately; the profile verification result has no
  single validity flag that could collapse them.

## 11. Packaging

### 11.1 Requirements for a valid IPA after signing

- **ZIP structure** — `Payload/<Name>.app/` with all bundle contents beneath
  it; no entries outside `Payload/` are required, and extra top-level content
  should be rejected or explicitly preserved by policy. **[Verified — IPA
  structure; Apple TN3125 references the `.ipa` as the distributable container]**
- **Signing order relative to packaging** — all signing happens on the
  extracted tree; the ZIP is then a container around already-signed content.
  Re-zipping does not alter signed bytes, so packaging cannot invalidate
  signatures **provided file contents, relative paths, and the seal-relevant
  metadata below are preserved**. **[Inferred — validated in E10]**
- **Permissions** — POSIX mode bits stored in ZIP external attributes must
  preserve executable bits and, critically, **symlinks** (framework version
  directories commonly use them). Losing a symlink or mode bit breaks either
  extraction fidelity or the resource seal. **[Inferred — high confidence;
  E10 validates round-trip]**
- **Timestamps** — DOS timestamps in ZIP entries are not part of code-signature
  hashing; they may be normalized for determinism unless product policy says
  otherwise. **[Inferred]**
- **Extended attributes** — rarely part of IPA content and not known to be
  seal-relevant; whether they exist in real inputs and whether the sandbox can
  round-trip them is **[Unknown — Open Question 8, E10]**.
- **Embedded signature artifacts** — the packaged tree must contain the
  freshly produced `_CodeSignature/CodeResources`, embedded signatures in each
  executable, and the selected `embedded.mobileprovision`; stale signature
  material must never survive alongside new material.
- **Determinism** — a canonical entry order, fixed timestamps, and a fixed
  compression policy can make output byte-reproducible; this is a policy
  choice, not a platform requirement. **[Inferred]**

### 11.2 System API situation

There is **no documented Apple API for creating or reading ZIP-container
archives** on iOS. Apple's own engineers have stated on record that Apple
platforms "have no good API for working with zip archives" and that Apple
Archive does not produce ZIP; the Compression framework supplies raw
DEFLATE-class algorithms but not the ZIP container. The Files app's ZIP
behavior is a system app capability, not a public API. **[Verified — Apple DTS
statements in Apple Developer Forums, 2021]**

Consequences:

- Reading and writing the ZIP container is **Feasible with custom
  implementation** (container logic in Swift plus platform compression), or
  via a dependency if one is later approved — the choice is explicitly deferred
  by architecture Section 9 and must respect the resource limits that section
  requires (entry-count and expansion-ratio bounds, path safety).
- Whether packages produced by ZynSign's writer are accepted by the platform's
  installer for every compression method and metadata choice is **Requires
  experiment (E10)** — ZIP-level acceptance is part of installation testing,
  not something this research can settle from documentation.

## 12. iOS Sandbox and Filesystem

The planned workflow — import, extract, modify, repackage, export — is
**compatible with the iOS application sandbox in principle [Inferred, high
confidence from documented mechanisms]**; none of the steps requires access
outside what the platform gives sandboxed applications. The constraints and
open points:

- **Import** reaches ZynSign through user-initiated document picks, Files,
  share-sheet extensions, or drag-and-drop. URLs are security-scoped: access
  lasts only while ZynSign holds the grant, and long workflows should begin by
  copying input into the app container so later provider revocation cannot
  break an in-flight operation. **[Verified — documented security-scoped
  URL model]**
- **Extraction and intermediates** live in application-owned directories
  (`tmp`/`Documents`-class locations) with the container's protections.
  Temporary data is purgeable in principle; working files should be treated as
  non-authoritative and rebuilt after relaunch. **[Verified — documented
  storage model]**
- **Storage pressure** — peak usage is roughly input + extracted tree + output
  (several times archive size). The application must pre-check free space,
  fail with a typed error rather than partially complete, and clean up on
  failure, cancellation, and relaunch after crash. Behavior under genuine
  pressure is **Requires experiment (E8)**.
- **Large files** — streaming/mmap discipline rather than whole-file `Data`
  loads; multi-gigabyte IPAs must not be buffered in memory. Performance
  characteristics on device are **Requires experiment (E8)**.
- **Provider edge cases** — iCloud/Drive/File Provider URLs that download on
  demand, on-demand materialization failures, and revocation mid-read are
  documented as possible; their real-world frequency and error surfaces need
  **E9**.
- **Coordination** — `NSFileCoordinator` is warranted when an input URL comes
  from a provider that requires coordinated reads; applying it uniformly adds
  cost without benefit. Decide per input path during E9, consistent with
  architecture Section 8 (no speculative coordination).
- **Cancellation and crash recovery** — every stage must be cancelable with
  cleanup on the same path as failure; after an unclean termination, stale
  intermediates are discarded on next launch. Design rule; validated in E8.
- **Output destinations** — exports use the same user-granted document
  machinery as imports; there is no general "write anywhere" capability, and
  none is needed.

Nothing in the planned pipeline requires privileges the sandbox forbids. The
sandbox is a constraint to design around, not a feasibility risk, for
inspection-signing-packaging. It becomes a policy question only for
installation (Section 13).

## 13. Installation

Installation is assessed independently of signing feasibility, per the
architecture (Sections 3 and 5).

### 13.1 What iOS officially permits

Documented, legitimate installation channels for third-party applications:

| Channel | Preconditions | Role for ZynSign |
| --- | --- | --- |
| App Store | Apple review and Apple's own distribution signing | Not applicable to user-produced artifacts |
| Over-the-air (OTA) via `itms-services` | Artifact and `manifest.plist` served over **HTTPS**; manifest describes the app; user opens the `itms-services` link (documented flow: from a website, typically in Safari) and confirms the system prompt; profile must cover the device (ad hoc/development) or the enterprise profile must be trusted; Developer Mode must be enabled where the signature class requires it (development-signed apps on iOS 16+) | The most plausible *external* channel for artifacts ZynSign produces; requires hosting ZynSign does not have and user steps outside ZynSign's control |
| Device management (MDM) | Supervised/managed device, MDM `InstallApplication`/`InstallEnterpriseApplication` or declarative management commands | Available only inside an organizational managed-device relationship |
| Computer-side tools | Finder, Xcode/`devicectl`, Apple Configurator, paired computer | Explicitly outside the product runtime |

Supporting platform facts, all **[Verified against Apple documentation
(TN3125; Apple Platform Security; Xcode "Enabling Developer Mode on a device";
Apple Deployment Guide)]**:

- Devices verify the provisioning-profile CMS signature and check the app
  against the profile's criteria before allowing it to run.
- iOS 16+ requires **Developer Mode** to be enabled (with a restart) before
  development-signed apps will launch; enterprise/TestFlight/App Store classes
  differ.
- In-house apps installed manually (without MDM) on iOS/iPadOS 18+ require a
  device restart to complete profile trust.
- First launch of proprietary in-house apps requires positive confirmation
  with Apple unless installed through an established management relationship.

### 13.2 Can installation occur directly from the ZynSign application?

- **No public API exists** that lets an iOS application install an arbitrary
  IPA (its own output or any other) onto the device it is running on. No such
  API is documented, and Apple's own guidance routes installation through the
  channels above. **[Verified as to documentation absence; Inferred as to
  absolute impossibility — an inference this research is comfortable making
  but which experiment E11 will re-check for the OTA path specifically.]**
- Opening an `itms-services` URL from within an application (rather than from
  a browser) and having the system present the install prompt is reported
  inconsistently in the field and is **[Unknown — Requires experiment E11]**.
  Even in the most favorable case it would trigger a *system* flow requiring
  HTTPS hosting of the artifact and manifest that ZynSign itself does not
  provide.
- Device-to-device installation (ZynSign on one device preparing an artifact
  for another) has no public install API either; file transfer between devices
  (multipeer, network shares) can move bytes but the **target device still
  needs a legitimate installation channel and user consent**. **[Inferred]**

### 13.3 Position

- Installation of ZynSign-produced artifacts is **Restricted /
  platform-dependent** in every currently known variant: it depends on Apple
  policy, profile class, device state (Developer Mode, trust, registration,
  management), user actions, and in most flows on infrastructure external to
  the application.
- The product-relevant conclusion: **signing on-device does not imply
  installing on-device.** The most plausible workflows are external (host the
  artifact, open an OTA link, confirm in the system UI) or organizational
  (MDM). Whether any of these belongs in ZynSign's scope remains the
  architecture's *Unresolved* item 15, and this research does not close it.
- This document deliberately covers only legitimate, documented channels. It
  does not investigate, and ZynSign must not depend on, mechanisms that
  circumvent Apple's security controls; such mechanisms are outside product
  scope by policy (architecture Section 14).

## 14. iOS and macOS Capability Boundary

Cells state what research found; "Uncertain" marks questions this research
could not close. macOS column describes the **developer environment only** and
is never a runtime assumption.

| Capability | iOS/iPadOS runtime | macOS developer environment | ZynSign consequence |
| --- | --- | --- | --- |
| Cryptographic primitives (SHA-2, RSA/ECDSA via `SecKey`, CryptoKit) | Documented and available | Same, plus additional legacy APIs | Primitives are portable across the product boundary; no redesign needed for hashing/signing math |
| Keychain / private keys | Available; `SecPKCS12Import` with legacy PBE only; non-extractable imported keys; per-use authorization Uncertain | Keychains plus `SecItemImport`/file keychains with extractability control | Import UX must handle legacy-PBE constraint; extractability control assumption is device-only and unproven (E7); macOS import paths must not be assumed present on iOS |
| `codesign` / static code-signature validation APIs | Not available to applications (no `SecStaticCode`, no tool execution) | `codesign`, `security`, `SecStaticCode` available | All signing and verification logic must live in-process; macOS is only an independent validator of ZynSign output |
| Mach-O manipulation | No APIs needed or provided; SDK structure headers available | `otool`/`lipo`/`codesign` for inspection; same format | One custom parser/writer serves the runtime; macOS tooling cross-checks it |
| CMS (PKCS#7) | **No API** (vendor-confirmed, 2017–2023; re-verified per symbol: `CMSDecoderCreate`, `CMSDecoderCopySignerStatus`, `CMSSignerStatus` list macOS/Mac Catalyst only) | `CMSEncoder`/`CMSDecoder` documented | CMS must be custom-built for the runtime; macOS CMS must not appear in any runtime code path. Verification of an existing SignedData message is now custom-built (bounded reader + `SecKeyVerifySignature`); construction remains to be built |
| Provisioning profiles | No complete parser API; CMS container is custom-parsed and its signature verified; decoded payload parsing is implemented in ZS-017; trust step Uncertain (E3/E13) | `security cms -D`, developer portal, Xcode | CMS handling remains a custom component; macOS only prepares fixtures and cross-checks |
| ZIP/archive handling | No documented ZIP-container API; Compression framework supplies DEFLATE-class codecs; Apple Archive ≠ ZIP | `ditto`, `zip`, full POSIX filesystem | Container reader/writer is a ZynSign component (or future approved dependency); implementation choice deferred |
| Device communication | Peer file transfer possible; **no install-targeting API** | USB/pairing, Xcode/Configurator, device consoles | Cross-device flows can only move artifacts; installation stays external/restricted |
| Installation | System channels only (App Store, OTA `itms-services`, MDM); no in-app install API | Finder/Xcode/Configurator install to *other* devices | Installation feasibility is separate from signing and remains *Unresolved* in product scope |

## 15. Required Experiments

No experiment below has been run. Each must be executed before the
architecture decision it gates is finalized. "Controlled credentials" means
project-owned test material only (synthetic keys or a project Apple
Development identity on a test device) — never third-party or production
material, per `SECURITY.md`.

### E1 — Key import and signature production with a controlled key
- **Status:** the `.p12` import half is not implemented (PKCS#12 remains a
  separate capability, deliberately deferred), so that objective is fully
  open. The signature-production half has a test surface on both sides of the
  device boundary: the opt-in Keychain identity integration suite (ZS-016,
  run only when `ZYNSIGN_RUN_KEYCHAIN_TESTS=1` in a signed iOS test host)
  exercises key residence, capability resolution, and RSA and EC signature
  production plus verification, and the ZS-021 pure engine tests cover the
  engine, request, result, and failure-model behaviour without a device.
  Neither has produced device evidence in this environment; nothing here is a
  device result.
- **Objective:** prove a `.p12` import, Keychain residence, and RSA PKCS#1
  v1.5 SHA-256 digest signature can complete on iOS.
- **Environment:** iOS app test harness; deployment-target device; macOS to
  generate the `.p12` (legacy PBE parameters).
- **Input:** synthetic RSA-2048 key + self-signed certificate in `.p12`;
  passphrase; fixed 32-byte digest.
- **Expected observation:** import succeeds; `SecKeyCreateSignature`
  returns a signature; `SecKeyCopyExternalRepresentation` on the private key
  fails (non-extractable); signature verifies against the certificate's
  public key.
- **Success criteria:** all four observations hold on the target OS.
- **Failure interpretation:** import failure ⇒ packaging/passphrase UX must
  adapt or input support is narrower; signature failure ⇒ cryptographic core
  needs revisiting before any blob work.
- **Device:** physical device required for Keychain realism; simulator run is
  informative only. **Credentials:** synthetic, no Apple identity.
  **Automatable:** yes.

### E2 — Certificate metadata inspection
- **Objective:** compare a bounded DER reader's subject, issuer, serial,
  validity, and key characteristics with whatever a device build can observe
  from Security framework objects, without treating that comparison as trust.
- **Environment:** iOS harness; macOS to prepare certificates.
- **Input:** synthetic RSA, EC, and unusual-name certificates. No private keys.
- **Expected observation:** `SecCertificateCopyValues` is not available on
  iOS (**Verified**). `SecCertificateCreateWithData` may accept or reject
  each input; that result is **Requires experiment** and is not the
  inspection classifier. `SecCertificateCopyData` byte-identity with the
  input is **Unknown**.
- **Success criteria:** the reader reports the fields it decoded, and a nil
  platform object is recorded as an observation rather than as a parse
  failure.
- **Failure interpretation:** a platform object that disagrees with the
  reader does not by itself make the reader wrong; the disagreement is
  evidence for a later experiment, not a trust decision.
- **Device:** simulator is informative; a physical device is required before
  any claim about device Security framework behaviour. **Credentials:**
  synthetic. **Automatable:** the reader is; the platform comparison is not
  yet.

### E3 — Provisioning-profile parse and container verification
- **Status:** the software under test exists. Payload extraction, SignedData
  structure reading, signer selection, signed-attribute binding, and signature
  verification are implemented, and the iOS-gated test suite exercises them over
  synthetic OpenSSL-generated containers; that suite has not been executed in an
  iOS harness, so nothing here is yet device evidence. Chain-trust evaluation is
  still absent from the repository, so this experiment's trust objective is
  unchanged.
- **Objective:** extract the payload from a real profile on-device and verify
  its CMS signature and issuer chain.
- **Environment:** iOS harness; developer-side `security cms -D` as reference.
- **Input:** one development profile and one distribution profile owned by the
  project; plus a tampered copy (payload byte flipped).
- **Expected observation:** custom CMS unwrap matches the macOS-extracted
  plist; `SecTrust` accepts the Apple issuer chain under the chosen policy;
  tampered copy fails verification.
- **Success criteria:** byte-identical payload extraction; trust success on
  valid input; definitive rejection of the tampered input.
- **Failure interpretation:** unwrap failure ⇒ CMS scope underestimated;
  trust failure ⇒ policy choice wrong (feeds E13) — record, do not silently
  downgrade to "parse-only success".
- **Device:** physical device preferred (trust store realism); simulator
  acceptable for unwrap-only. **Credentials:** project profiles.
  **Automatable:** yes (tamper case included).

### E4 — CMS SignedData construction round-trip
- **Scope note:** this experiment is about *construction*, which is not
  implemented. Verification is implemented separately, and the part of it that
  still needs a device is narrower: that `SecCertificateCopyKey` yields a key
  whose algorithm support matches the certificate's own key fields, and that
  `SecKeyVerifySignature` accepts the re-encoded `SET OF` attribute bytes for
  both RSA and ECDSA signers. That confirmation is recorded under E3. The
  ZS-021 generic signature verifier uses the same documented primitives
  (`SecCertificateCopyKey`, `SecKeyIsAlgorithmSupported`,
  `SecKeyVerifySignature`) over plain messages and digests, so its on-device
  behaviour rides the same confirmation; its iOS-gated tests check real
  RSA and ECDSA fixture signatures once they run on a device or simulator.
- **Objective:** construct a CMS SignedData object over controlled content and
  have independent tooling accept it.
- **Environment:** iOS harness builds; macOS `security`/OpenSSL verify.
- **Input:** fixed content bytes; E1 key and certificate; optional intermediate
  certificate included in the bag.
- **Expected observation:** independent verifier reports the signature valid
  and content intact; structure matches RFC 5652 expectations.
- **Success criteria:** external verification succeeds deterministically.
- **Failure interpretation:** any mismatch ⇒ CMS implementation must iterate
  against fixtures before it is used anywhere near real artifacts; this is the
  single highest-risk custom format.
- **Device:** not required (pure computation + file exchange).
  **Credentials:** synthetic. **Automatable:** yes.

### E5 — Mach-O signature-region read and controlled modification
- **Status (ZS-031):** partly exercised on hosted macOS for ZynSign's own
  output. On the synthetic executable model, `otool -l` agrees with ZynSign
  on `LC_CODE_SIGNATURE` and `__LINKEDIT`, the signature offset is 16-byte
  aligned, and the region ends at the end of the file, for single images
  and for the pipeline's main and nested executables. Rewriting an existing
  signature, the fat fixture, and real linker layouts are not exercised:
  the signer refuses all three. See
  [external-validation.md](external-validation.md).
- **Objective:** locate, bound, and rewrite the `LC_CODE_SIGNATURE` region of a
  disposable fixture without corrupting the file.
- **Environment:** iOS harness; macOS `otool`/`codesign -dvvv` reference.
- **Input:** thin arm64 signed fixture (synthetic or project-built), plus a fat
  fixture for per-slice behavior.
- **Expected observation:** load-command parsing matches `otool`; rewritten
  region respects offset alignment and segment sizing; developer-side tools
  still parse the binary (not necessarily *verify* it yet — E6 covers that).
- **Success criteria:** structural equivalence to reference output for the
  fields touched.
- **Failure interpretation:** layout mismatch ⇒ signature-replacement rules
  need another fixture round; do not proceed to blob construction.
- **Device:** not required. **Credentials:** none. **Automatable:** yes.

### E6 — Minimal end-to-end resign of a controlled fixture
- **Status (ZS-031):** the developer-side validator half runs on every
  push, not yet with the result E6 asks for. `codesign --verify` accepts
  ZynSign's single-image signatures and rejects the pipeline's bundle and
  its nested framework ("code has no resources but signature indicates they
  must be present"); the signature format also fails Apple's documented
  iOS 15+ requirements. The input is a synthetic executable signed with a
  throwaway self-signed identity, not a minimal real application, and the
  install probe has not run. See
  [external-validation.md](external-validation.md).
- **Objective:** produce, from scratch on-device, a CodeDirectory + entitlement
  blobs + CMS slot + `CodeResources` for a trivial app fixture, in correct
  nested order, and pass independent validation.
- **Environment:** iOS harness; macOS `codesign --verify --strict --deep` and
  `spctl`-class inspection as independent validators; a physical device for
  the install probe described in E12/E14.
- **Input:** minimal signed IPA fixture with one nested framework or
  extension; controlled identity (E1-level for the cryptographic slot; a
  project Apple Development identity only for the install probe).
- **Expected observation:** developer-side `codesign --verify` accepts each
  signed component and the container; resource seal recomputes identically;
  innermost-first ordering produces a consistent outer seal.
- **Success criteria:** independent verification passes on every component.
- **Failure interpretation:** any failure classifies the failing component's
  design as not yet ready; discrepancies vs `codesign` output are recorded in
  the discrepancy log (Section 16), not patched around.
- **Device:** simulator for the signing steps; physical device required only
  when combined with E12/E14. **Credentials:** synthetic for signing;
  project identity for install probe. **Automatable:** yes for signing and
  verification; install probe partially manual.

### E7 — Keychain behavior on a physical device
- **Objective:** establish extractability, accessibility, uninstall, and
  per-use authorization behavior for imported/generated signing keys.
- **Environment:** physical iPhone/iPad; harness exercising
  `SecPKCS12Import`, `SecItem` queries, `SecAccessControl` flags.
- **Input:** E1 `.p12`; a generated key with `kSecAttrIsExtractable = false`;
  attempts to use the key while the device is locked and from background.
- **Expected observation:** imported key non-extractable and still signable;
  accessibility class honored; behavior of `privateKeyUsage`/`userPresence`
  ACLs recorded as-is (whatever it is).
- **Success criteria:** documented behaviors reproduce on the deployment
  target; per-use authorization question answered positively or negatively.
- **Failure interpretation:** negative per-use authorization ⇒ key-use gating
  must be enforced in application logic and acknowledged as weaker than
  OS-mediated per-use consent.
- **Device:** **physical required.** **Credentials:** synthetic.
  **Automatable:** yes, except lock-state scenarios (semi-automated).

### E8 — Large-IPA extraction and repackaging under resource pressure
- **Objective:** validate peak storage, throughput, cancellation, and crash
  cleanup with realistically large inputs.
- **Environment:** physical device(s) across the smallest supported storage
  class; harness with instrumented storage accounting.
- **Input:** IPAs of approximately 100 MB, 1 GB, and (if obtainable as
  synthetic fixture) multi-GB size; forced low-space conditions.
- **Expected observation:** extraction completes within budgets or fails with a
  typed pre-flight storage error; cancellation and kill-during-operation leave
  no orphans after relaunch.
- **Success criteria:** no silent partial outputs; cleanup verified after
  kill; memory ceiling respected (no whole-archive buffering).
- **Failure interpretation:** unbounded memory or orphaned data ⇒ packaging
  architecture must change (streaming-only) before feature work.
- **Device:** **physical required.** **Credentials:** none (synthetic
  archives). **Automatable:** yes.

### E9 — Security-scoped document access across input sources
- **Objective:** characterize real provider behavior for import paths.
- **Environment:** physical device; Files app, iCloud Drive, a third-party
  provider if available, iPad external storage if in product scope.
- **Input:** IPA selected via document picker; provider revocation mid-read;
  on-demand materialization files.
- **Expected observation:** security-scoped grants behave per documentation;
  copy-in strategy isolates the workflow from later revocation; error surfaces
  are classifiable.
- **Success criteria:** every supported input path completes or fails with a
  typed diagnostic; no dependency on a grant outliving the copy-in.
- **Failure interpretation:** hostile provider behavior ⇒ strengthen
  copy-in-first policy; consider coordination only where a path proves to
  require it.
- **Device:** **physical required.** **Credentials:** none.
  **Automatable:** partially (picker interaction is manual/assistive).

### E10 — ZIP round-trip fidelity and installer acceptance
- **Objective:** prove the planned writer preserves seal-relevant metadata and
  that output is accepted far enough into installation to exercise signature
  checks.
- **Environment:** iOS harness writer; macOS extractor for comparison; physical
  device install attempt (inside E12/E14 context).
- **Input:** fixture tree with executable bits, framework symlinks, nested
  bundles; then a full ZynSign-produced IPA from E6.
- **Expected observation:** round-trip preserves modes/symlinks/contents;
  device installation attempt reports signature/profile-class outcomes (not
  container-format errors).
- **Success criteria:** byte-level content equality after round-trip; failure
  messages at install time concern signing/policy, never ZIP structure.
- **Failure interpretation:** container-format rejection ⇒ writer must change
  before any further install work; metadata drift ⇒ preservation policy
  revisited.
- **Device:** **physical required for the install probe.** **Credentials:**
  project identity/profile for probe. **Automatable:** round-trip yes; install
  probe partially manual.

### E11 — OTA handoff behavior from an app context
- **Objective:** determine whether ZynSign can initiate the documented
  `itms-services` flow at all, and what it can honestly promise users.
- **Environment:** physical device; small HTTPS hosting surface controlled by
  the project (developer-side); valid manifest and test artifact.
- **Input:** `itms-services://?action=download-manifest&url=…` opened via
  `openURL` from the harness; the same link opened in Safari as control.
- **Expected observation:** either the system install prompt appears, or the
  URL is ignored/refused — recorded per iOS version.
- **Success criteria:** behavior established and reproducible on the
  deployment target.
- **Failure interpretation:** in-app open refused ⇒ OTA remains an
  external-workflow feature (hand the user a link) and product scope for
  "install from ZynSign" shrinks accordingly; feeds the *Unresolved*
  installation decision.
- **Device:** **physical required.** **Credentials:** project test
  identity/profile; controlled HTTPS host. **Automatable:** partially
  (prompt confirmation is manual).

### E12 — Developer Mode and trust prerequisites matrix
- **Objective:** document, per profile class, the exact user-facing
  prerequisites for running a ZynSign-produced artifact on a real device.
- **Environment:** physical device, factory-observed states: Developer Mode
  off/on; enterprise profile trusted/untrusted; device registered/not
  registered in an ad hoc profile.
- **Input:** controlled artifacts from E6/E10 per profile class.
- **Expected observation:** prompts, restarts, and refusal messages match
  Apple's documented behavior (Developer Mode, trust, registration).
- **Success criteria:** a written matrix of precondition → outcome per
  profile class on the deployment target.
- **Failure interpretation:** undocumented precondition discovered ⇒ it becomes
  a product-facing diagnostic requirement, not a silent failure.
- **Device:** **physical required.** **Credentials:** project
  identities/profiles. **Automatable:** no (manual state changes and
  observation), though install attempts themselves can be scripted.

### E13 — Trust-policy behavior for code-signing chains on iOS
- **Objective:** establish which `SecPolicy` construction correctly evaluates
  Apple-issued signing certificates on iOS.
- **Environment:** iOS harness; chains from E3 inputs.
- **Input:** development and distribution signer chains; anchors as present in
  the iOS trust store; expired and foreign-issuer negatives.
- **Expected observation:** one policy (basic X.509 with explicit anchors, or
  the Apple code-signing policy where functional) accepts valid chains and
  rejects negatives.
- **Success criteria:** a single recommended policy with recorded semantics.
- **Failure interpretation:** no suitable policy ⇒ chain verification must be
  built on explicit anchors + custom checks, and profile/CMS verification
  claims must be worded accordingly.
- **Device:** physical device preferred (trust store). **Credentials:**
  project certificates. **Automatable:** yes.

### E14 — Discrepancy harness: ZynSign vs developer tooling vs device
- **Status (ZS-031):** the developer-tooling column exists. Damaged copies
  of the single images (code byte, CodeDirectory byte, entitlements byte,
  CMS signature byte, truncation) are rejected by both ZynSign and
  `codesign`, nine of nine. The stale-`CodeResources` mutation (bundle
  mutations mean nothing until an unmodified bundle is accepted), the
  expired-profile and wrong-team mutations, and the device column are not
  yet measured. See [external-validation.md](external-validation.md).
- **Objective:** make verification divergence observable instead of assumed.
- **Environment:** all of the above, wired as one pipeline: ZynSign verifier →
  macOS `codesign --verify --strict --deep` → physical install attempt.
- **Input:** correct fixtures, plus systematic mutations (flipped code byte,
  stale `CodeResources`, altered entitlement claim, expired profile, wrong
  team prefix).
- **Expected observation:** each tool's verdict per mutation, tabulated.
- **Success criteria:** every mutation produces at least the expected
  developer-side failure; ZynSign's misses and false alarms are enumerated;
  device outcomes recorded where reached.
- **Failure interpretation:** a ZynSign miss on a mutation ⇒ verifier gap
  (bug, not policy); a ZynSign pass that the device rejects ⇒ expected
  platform-only check — added to the known-divergence list, never suppressed.
- **Device:** physical device for install outcomes. **Credentials:** project
  identities/profiles. **Automatable:** yes for tool verdicts; install steps
  partially manual.

**Sequencing:** E1–E2 and E5 are independent starters. E3/E4 gate any claim
about profile trust or CMS. E6 is the integration gate for the signing
pipeline. E7–E10 gate production architecture for storage and keys. E11–E12
gate any installation-scope decision. E13 feeds E3's trust step. E14 runs
continuously once E6 exists.

## 16. Architecture Consequences

### 16.1 Confirmed architectural requirements

Things this research says the architecture must already account for — none is
speculative:

1. **A dedicated, single signing boundary** (the `SigningEngine` port) is
   required: on iOS the only way to sign is in-process, so every use of the
   private key, every blob write, and every profile/identity decision
   concentrates there.
2. **Custom format implementations belong in Infrastructure, not Platform** —
   CMS, Mach-O blob structures, CodeDirectory/requirements/entitlements
   encoding, `CodeResources` generation, and the ZIP container are all
   in-language, pure, fixture-testable components. Platform holds only
   `SecKey`/Keychain/`SecTrust`/file access. This matches the layer model in
   architecture Section 4 and is now evidence-backed.
3. **Verification stays independent of signing** (architecture Section 5) and
   additionally needs an explicit **known-divergence register**: platform-only
   checks ZynSign does not replicate, populated from E14. "ZynSign-verified"
   and "platform-accepted" are different labels everywhere they appear,
   including UI copy.
4. **Profile trust is a staged decision**: parse ≠ verify ≠ authorize
   (Section 7). The product must show which stage a profile reached.
5. **Identity import must accept the legacy-PBE constraint** and report
   modern-encoded `.p12` failures as an input-compatibility condition with a
   clear remedy, not as an internal error.
6. **Extraction/repackaging must be streaming-first with pre-flight space
   checks, cancellation-with-cleanup, and crash-safe stale-data disposal**
   (Section 12) — these are requirements, not polish.
7. **Signing and installation remain separate stages with separate error
   domains** (architecture Sections 3 and 5). No code path may treat a
   packaging success as installability evidence.
8. **Input classification must include unsupported categories** discovered
   here: encrypted executables, simulator-architecture slices, unreadable
   nested bundles, modern-PBE `.p12` files — each with a typed diagnostic.

### 16.2 Feasibility dependencies (must be validated before implementation)

| If implementation of… | starts only after… |
| --- | --- |
| Production signing engine (any blob emission) | E1, E4, E5, E6 |
| Profile-trust and identity-association features | E3, E13 |
| Keychain-backed identity store | E7 (physical-device results) |
| Production packaging pipeline | E8, E10 |
| Import UX for arbitrary user files | E9 |
| Any installation-facing feature or promise | E11, E12 **and** an explicit product-scope decision (architecture item 15) |
| Verification claims shown to users | E6, E14 |

### 16.3 Deferred decisions (must remain unresolved)

- Deployment target (gates API availability assumptions throughout).
- Archive implementation: custom vs dependency (architecture Section 9).
- CMS implementation: custom vs dependency — do not decide before E4 shows
  the real error surface.
- Installation scope in the product (architecture item 15).
- Supported profile types, entitlement allowlist scope, certificate types,
  and supported nested-code location set.
- Whether platform policy agrees with the predicates ZynSign implements for
  wildcard application identifiers, profile classification, entitlement
  authorization, and device provisioning; and whether a trustworthy device
  identifier can be obtained at all (Open Question 9). These must not be
  resolved by assumption, and a `compatible` policy result must not be presented
  as platform acceptance.
- Requirements-language subset (Open Question 6).
- Persistence technology, retention durations, UI design (unchanged from
  architecture Sections 15 and 13).

### 16.4 Phases unlocked vs. phases blocked

**Can safely begin after this research** (all fixture-based, no production
signing claims): domain model and validation rules (bundle metadata, profile
payload interpretation *without* trust claims, entitlement-compatibility
predicates, nested-code ordering logic, diagnostics/redaction); read-only
Mach-O inspection against fixtures; experiment harnesses E1–E14 themselves;
developer-side fixture-generation scripts; archive threat-model tests on
synthetic trees.

**Must wait** (gated by Section 16.2): production signing of any kind;
identity/Keychain production storage; profile verification surfaced as
"verified" to users; packaging pipeline finalization; anything installation-
facing; release-quality verification results.

## 17. Security Implications

Discovered or confirmed during this research, mapped to controls the design
must carry. Threat categories are limited to what this product's workflow
actually touches.

| Area | Implication | Required posture (design-level) |
| --- | --- | --- |
| Imported `.p12` / private keys | Highest-value secret in the product; import path is user-reachable | Import → Keychain only; non-extractable keys; passphrase never logged; source bytes zeroized/discarded after import; no export path may exist in code review checklists |
| Keychain access | Keys usable by the process; per-use OS authorization unproven (E7) | Device-only accessibility; explicit user intent before each signing session; acknowledge honestly if per-use consent cannot be OS-enforced |
| Malicious IPAs | Untrusted by definition: path traversal, symlink escape, entry/entry collisions, zip bombs, pathological nesting | Enforce architecture Section 9 limits *before* extraction; inspection runs with no key material reachable (architecture Section 5) |
| Malformed Mach-O | Hostile parsers: absurd load-command counts, overflow-prone offsets, truncated blobs, contradictory sizes | Bounded readers, fail-closed parsing, no permissive fallback, structure limits as policy |
| Malicious provisioning profiles | Forged or tampered containers attempting to influence identity/entitlement decisions | Never act on unverified payloads (Section 7.3); tamper-detection covered by E3; treat profile fields as attacker-controlled strings in all matching logic |
| Decompression/resource exhaustion | Extraction can exceed storage or memory arbitrarily | Pre-flight space checks, expansion-ratio and entry-count caps, streaming I/O, cancellation cleanup (E8 validates) |
| Temporary files and crash leftovers | Extracted trees and intermediates can outlive their purpose after a crash | Defined lifetimes; next-launch disposal of stale work areas; no sensitive intermediates (identity bytes, passphrase buffers) ever written |
| Logs and diagnostics | Signing workflows leak naturally (paths, team IDs, bundle IDs, profile contents) | Redaction as tested domain logic (architecture Section 14); certificates/profiles/keys/device IDs excluded from logs by default |
| Diagnostic exports | Support bundles are an exfiltration path by accident | Export builders composed only from explicitly allowlisted, redacted fields |
| Sensitive user paths | Document-picker URLs reveal user structure | Store identifiers, not full paths, in persisted records where possible |
| Signed artifact retention | Produced IPAs embed provisioning material and signature output | Retain only per explicit policy; default to user-controlled deletion; no background sync of artifacts |
| Verification honesty | Overclaiming verification status is itself a security defect | Known-divergence register (Section 16.1); wording rules in Section 10 are mandatory, not stylistic |

No other threat categories are introduced by this research.

## 18. Open Questions

Unresolved after this research; each maps to an experiment or a product
decision:

1. **Deployment target** — which iOS/iPadOS versions must be supported, and
   therefore which APIs and acceptance behaviors apply?
2. **CMS strategy** — custom implementation vs approved dependency; to be
   revisited after E4, not before.
3. **Profile-verification scope** — does the first release surface
   "signature verified," or ship parse-only with explicit unverified state
   until E3/E13 are conclusive?
4. **Architecture coverage** — thin `arm64` only, or fat-binary resign
   (E5 informs; product decides)?
5. **Encrypted/simulator input policy** — confirmed as reject-class for
   installation purposes; confirm for inspection-only mode.
6. **Requirements-language subset** — which constructs ZynSign must evaluate
   vs display-only?
7. **Extended attributes** — presence in real IPAs and sandbox round-trip
   (E10).
8. **Device-identifier access for ad hoc checks** — whether ZynSign can
   legitimately obtain the local device identifier to pre-check
   `ProvisionedDevices` without user typing; if not, that check is deferred to
   install-time failure with a clear diagnostic.
9. **OTA and installation scope** — outcome of E11/E12 combined with the
   product decision on architecture item 15.
10. **Per-use key authorization** — outcome of E7; if unavailable, what
    compensating UX constraints apply.
11. **Keychain retention across reinstall** — product stance on identity loss
    when the app is deleted.
12. **Supported identity set** — certificate classes the product will accept
    (development, distribution, in-house) and their matching rules.

## 19. Evidence and Confidence Classification

### 19.1 Definitions

- **Verified** — established through authoritative Apple documentation
  (technotes, API documentation, Platform Security, deployment guides) or
  explicit Apple DTS statements in official channels.
- **Observed** — established through controlled inspection or testing.
- **Inferred** — technically reasoned from verified facts but not
  experimentally verified.
- **Unknown** — insufficient evidence.

### 19.2 Classification of major conclusions

| # | Conclusion | Class | Basis / caveat |
| --- | --- | --- | --- |
| 1 | SHA-2 hashing and RSA/ECDSA signing primitives are available to iOS apps via `SecKey`/CryptoKit/CommonCrypto | Verified | Apple API documentation |
| 2 | No CMS API exists on iOS; CMS must be written or acquired | Verified | Repeated Apple DTS statements (2017, 2021, 2023) |
| 3 | `SecPKCS12Import` works on iOS but only with legacy PBE algorithms | Verified | Apple DTS statements (2021–2023) and API documentation |
| 4 | Keys imported via `SecPKCS12Import` on iOS are non-extractable yet usable for signing | Verified | Apple DTS statement; attribute *control* at import time remains Unknown |
| 5 | No documented public API lets an app install an arbitrary IPA on-device | Verified (documentation absence) / Inferred (impossibility) | Channel inventory from Apple documentation; absolute-negative inference re-checked by E11 |
| 6 | OTA installation requires HTTPS manifest + `itms-services` + user confirmation; Developer Mode gates development-signed apps on iOS 16+ | Verified | Apple deployment guide; Xcode Developer Mode documentation |
| 7 | Provisioning profile = CMS-signed plist; DER form is the modern source of truth; entitlement allowlist semantics | Verified | Apple TN3125 |
| 8 | Code-signature structure (superblob, CodeDirectory, special slots, requirements) | Verified | Apple Inside Code Signing series; Apple open-source headers |
| 9 | Devices validate profile signature and app/profile criteria before run | Verified | TN3125; Apple Platform Security |
| 10 | iOS apps cannot invoke `codesign` or other tools; no `SecStaticCode` equivalent is documented for iOS | Verified | Sandbox/mandatory-signing model; consistent DTS/community position |
| 11 | No documented system API creates ZIP containers on iOS; Apple Archive is not ZIP | Verified | Apple DTS statement (2021) |
| 12 | Inner-before-outer nested signing order is required by seal structure | Inferred | From verified seal mechanics; fixture validation pending (E6) |
| 13 | Signature-region replacement layout rules (alignment, `__LINKEDIT` sizing) are implementable | Inferred | Format reasoning + reference-tool observations; pending E5 |
| 14 | `SecTrust` with a code-signing-appropriate policy behaves correctly for Apple issuers on iOS | Unknown | Constant appears in iOS API history; behavior undocumented; E13 |
| 15 | Per-use user-presence authorization can be attached to imported signing keys | Unknown | E7 |
| 16 | The planned extract/modify/repackage workflow is sandbox-compatible | Inferred | From documented sandbox mechanisms; load/provider behavior pending E8/E9 |
| 17 | Installer accepts ZynSign-style ZIP output (methods/metadata) | Unknown | E10 |
| 18 | Opening `itms-services` links from an app context triggers installation | Unknown | Conflicting field reports; E11 |
| 19 | A custom verifier can match platform validation | Rejected as a claim | Only the platform validates for installation; ZynSign reports its own, narrower result (Section 10) |
| 20 | Extended-attribute relevance to IPA round-trips | Unknown | Open Question 7 / E10 |
| 21 | arm64e requires different signing treatment | Inferred (no) | Bytes hashed as-is; confirm against fixtures in E5 |
| 22 | FairPlay-encrypted executables cannot be re-signed for execution | Inferred | No legitimate decryption path exists; classification as unsupported input recommended |

### 19.3 Evidence discipline for this document

- **No controlled experiment was executed under this task**, so the *Observed*
  class is intentionally empty; experiments E1–E14 are how it gets populated.
- Where documentation and future experimentation disagree, the discrepancy is
  recorded (Section 16.1, item 3 and E14) rather than resolved silently.
- Statements sourced from Apple Developer Forums DTS replies are treated as
  vendor statements (Verified) but are weaker than technotes; the most
  consequential of them (CMS absence, PKCS#12 constraints) are cross-checked
  across multiple years of independent replies, and E3/E4 re-test them on the
  chosen deployment target regardless.

**Primary sources consulted:** Apple TN3125 (Provisioning Profiles), TN3126
(Hashes), TN3127 (Requirements), TN3161 (Certificates); Apple Platform
Security ("App code signing process"); Apple Deployment Guide (in-house
distribution, OTA manifest requirements); Xcode documentation (Enabling
Developer Mode); Apple Security, CryptoKit, and Keychain Services API
documentation; Apple open-source Security/Mach-O headers (`cs_blobs.h`,
`loader.h`, `fat.h`, `requirement.h`); Apple Developer Forums DTS statements
on CMS availability and PKCS#12 import (2017–2023); RFC 5652 (CMS).
