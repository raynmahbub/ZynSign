# ZynSign Architecture

## Status

This document defines the architecture of ZynSign: the platform it runs on, the
layers and boundaries the application is organised into, the decisions that are
settled, and the capabilities that are not yet established.

Nine implementation increments exist. The first is an Xcode application
target with a SwiftUI application shell, a composition root, a minimal pure
domain layer, and a unit-test target; it establishes the layer boundaries of
Section 4 and no workflow capability. The second adds the archive-reading
layer the inspection stage depends on: bounded ZIP container reading behind
the `ArchiveReader` boundary, application-bundle discovery, structural
validation of a package's layout, and their tests. The third adds the
application metadata layer: a pure domain reader that extracts and validates
the metadata a bundle declares in its bundle information file, an
application-layer use case that reads that one entry through the archive
boundary for an established bundle and records the outcome on the artifact,
and their tests. The fourth adds the document-import workflow: a
user-driven `.ipa` selection through the system document picker, one
security-scoped, bounded-chunk staging of the selected document into
application-owned temporary storage addressed by the artifact identifier,
examination of the staged archive by the existing inspection use cases, and
an Import area that renders the outcome through an explicit phase machine.
The fifth adds application persistence: a durable, value-typed library
record for each accepted import, a versioned catalog file that holds those
records, application-owned artifact storage that adopts the staged archive,
a deterministic content-based duplicate policy, and the library use case
that sequences them behind the import flow (Section 15). The sixth adds the
Applications area: a library screen that lists the persisted records with
each record's current artifact availability, imports another package through
the existing document-import workflow, opens a per-record detail screen, and
removes a record together with the package file behind it through the
library use case's removal operation. The seventh adds bundle inspection: a
read-only explorer, reached from the application detail screen, that lists
the files and folders inside a library application's bundle from the
package's entry table through the existing archive boundary, without
extracting, opening, or evaluating any of them (Section 9, Bundle Inspection
Decision). The eighth adds the certificate and signing-identity domain
foundation: a platform-independent certificate metadata model, validity
evaluation that distinguishes parsing success from current validity, chain
representation without trust evaluation, a narrow signing-capability
abstraction that does not expose private-key bytes, a distinct signing
identity model, an identity-store boundary, and a certificate parser behind
the `CertificateParser` port. Metadata is read by a bounded DER reader
because `SecCertificateCopyValues` is not available on iOS (Section 7,
Certificate and Signing Identity Foundation). The ninth refines that foundation
with explicit signing algorithms, structured identity failures, a secure registry
and capability resolver, and an experimental Keychain adapter. It is not composed
into the app: physical-device experiment E7 still gates production use. The
provisioning-profile parsing increment then adds a bounded raw profile input,
a CMS/container-decoder port, a decoded-payload property-list parser, typed
profile and entitlement values, an injected-clock period validator, and an
application-layer inspection use case. It did not implement CMS unwrapping or
verification, certificate-chain trust, entitlement/device/platform
authorization, embedded-profile archive inspection, signing, or persistence.
The provisioning-profile CMS verification increment then adds that container
boundary: a bounded SignedData structure reader, a signature-verification seam
over documented iOS key primitives, signer-certificate extraction, certificate
relationship analysis against the profile's own certificates and the locally
listed identities, an application-layer verification use case that parses a
payload only after its signature verified, and their tests. It performs no
certificate-chain trust evaluation, no signing-policy, entitlement, device, or
platform-compatibility decision, no embedded-profile archive inspection, no
profile persistence, and adds no profile-management interface. Apple's CMS
decoder family is documented for macOS only, so no platform CMS service is
called anywhere in the repository.
The inspection stage is therefore a partial capability: it reads containers,
classifies layout, reads one bundle's declared metadata, describes a bundle's
structure, and can separately inspect a caller-supplied decoded profile payload.
Accepted imports are recorded and kept across launches and are listed, imported,
browsed, and removed in the Applications area; certificate and profile parsing
and identity modeling exist as domain foundation; provisioning-profile CMS
verification reports signature authenticity separately from trust and
authorization and is reachable from the application layer only, not from any
interface; an experimental signature
primitive exists, but no application-signing, verification, packaging, or
installation workflow exists.

Nothing else in this document is a claim that any behaviour works. Every
feasibility boundary in Section 6 remains open except where noted here, and the
signing, verification, packaging, and installation stages are documentation of
intended structure only.

Earlier project documentation assumed a desktop runtime and desktop platform
services. That assumption no longer holds. ZynSign is defined here as an
iOS/iPadOS application whose signing workflow executes on-device, and every
capability that depends on the platform is recorded as an explicit boundary
rather than as an available mechanism. Where this document and
[phase-0-discovery.md](phase-0-discovery.md) disagree about platform questions,
this document is authoritative; the discovery document is retained as the
findings record that feeds the research backlog in
[Feasibility Boundaries](#6-feasibility-boundaries).

### Classification Vocabulary

Every platform-dependent statement in this document carries one of four
classifications.

- **Accepted** — an architectural decision that does not depend on an unverified
  platform capability, and which implementation can rely on.
- **Provisional** — a direction that is intended, but whose details may change
  once a related research question closes.
- **Unresolved** — no decision has been made yet. A decision is required before
  the related work is implemented.
- **Requires feasibility research** — the architecture depends on a platform
  capability whose availability, behaviour, or constraints are not established.
  Implementation of anything relying on it must not begin until research
  answers the question, and a negative answer may invalidate the corresponding
  feature.

Nothing in this document may be promoted out of *Unresolved* or *Requires
feasibility research* by assumption, by analogy with another Apple platform, or
by the presence of a similarly named API elsewhere.

## 1. Product Runtime

ZynSign is an iPhone and iPad application. Its intended inspection, signing,
verification, and packaging workflows are designed to run on the device itself,
rather than on a connected computer.

The following statements are **Accepted** and define the runtime:

- The product runtime is iOS and iPadOS, distributed as an application bundle and
  subject to the standard application sandbox.
- The signing workflow ZynSign is being designed for executes on-device. No
  separate desktop process, service, or daemon is part of the product runtime.
- ZynSign is not a macOS application. macOS is not a supported runtime platform
  for ZynSign, and no architecture in this document may assume desktop runtime
  capabilities.
- An iOS or iPadOS application cannot rely on executing command-line tools. There
  is no supported mechanism for a sandboxed application to invoke a separate
  signing executable, and the desktop signing tools are neither present on the
  platform nor callable from the application. The runtime architecture must not
  be designed around one.
- Capabilities that depend on iOS or iPadOS platform services are treated as
  unverified until they have been demonstrated against real platform behaviour on
  a supported deployment target. The architecture records them as feasibility
  boundaries (Section 6) rather than as available mechanisms.

## 2. Developer-Side Tooling Is Not Runtime Architecture

Development and validation of ZynSign inherently involve macOS and Xcode. Those
environments are **Accepted** as developer-side infrastructure and must remain
outside the product runtime:

- building and running the application;
- running development tooling, static analysis, and test runners;
- generating controlled test fixtures, including synthetic signed artifact
  samples;
- independently inspecting and validating artifacts produced by ZynSign;
- conducting platform compatibility experiments while researching feasibility
  questions.

The distinctions below are **Accepted** and are not stylistic:

- A macOS command-line tool may appear in the testing and research
  infrastructure as an independent validator of ZynSign's output. It is not an
  iOS runtime component, and the application must not be architecturally shaped
  around invoking it.
- Signing operations in the product runtime may not be implemented by delegating
  to desktop tooling — locally, on another computer, over a network, or through a
  helper application — and no such delegation is planned.
- Fixtures generated with desktop tooling are test inputs. Their existence does
  not establish that the corresponding operation is available on-device.

## 3. Architectural Principles

**Accepted**, unless noted:

1. **Platform capability is proven, not assumed.** Every dependency on an Apple
   framework, filesystem behaviour, or hardware capability is either verified for
   iOS/iPadOS or explicitly classified as unresolved.
2. **Signing and installation are separate concerns.** Producing a signed archive
   says nothing about whether that archive can be installed, or installed on the
   device running ZynSign. See Section 5.
3. **All imported input is untrusted.** Archives, plists, Mach-O data, profiles,
   certificates, and their metadata are attack surface, not just data.
4. **Key material has one direction of travel.** Private key material may enter
   signing operations and must not travel anywhere else. See Section 7.
5. **Pure logic stays pure.** Domain rules are testable without a device, a
   simulator, a network, or a keychain.
6. **Boundaries exist for architectural reasons.** A protocol is introduced when
   it marks a real seam — platform dependence, untrusted input, privilege, or
   substitutability for tests — not for uniformity. See Section 11.

## 4. Layer Model

```
        Presentation
             │
             ▼
        Application
             │
             ▼
          Domain
          ▲     ▲
          │     │
Infrastructure  Platform
```

Arrows indicate "may depend on". The model is **Accepted**.

| Layer | Responsibility | May depend on |
| --- | --- | --- |
| Presentation | User-visible state and interaction. Renders what the application layer exposes. | Application |
| Application | Use-case orchestration, workflow state, composition of domain logic with ports, transaction and cancellation semantics. | Domain |
| Domain | Pure rules and data: package structure, validation, identity matching, entitlement compatibility, nested-code ordering, verification interpretation, diagnostics, errors. | Nothing |
| Infrastructure | Portable implementations that are not tied to a platform service: in-language algorithms, encoders, deterministic writers, in-memory stores used by tests. | Domain |
| Platform | iOS/iPadOS runtime integration: platform services such as protected key storage and access, certificate and profile services, file and document access, temporary storage, device integration, and platform cryptography — each subject to the feasibility boundaries in Section 6. | Domain |

Rules that follow from the model, all **Accepted**:

- **Platform means iOS/iPadOS runtime infrastructure.** It is the seam at which
  Apple frameworks and sandbox behaviour are reached. It holds no domain rules.
- **Infrastructure means portable, non-platform-specific implementations.**
  Anything that can be expressed in language-level code without a platform
  service belongs here, so that it remains usable in pure tests.
- **macOS developer tooling sits outside this model entirely.** It is not a layer,
  not an adapter, and not a dependency edge.
- **Domain depends on no Apple UI or Security frameworks.** Domain types are
  value types built from language and standard-library primitives. Platform
  objects (key references, certificates, URLs handed over by a provider, file
  handles) do not appear in domain APIs.
- **Presentation does not reach platform implementations.** A view cannot obtain
  a key reference, a file handle, a temporary directory, or a signing engine.
- **Composition happens at the application boundary.** The application layer
  chooses concrete implementations for the ports it consumes; no lower layer
  constructs another layer's concrete types.
- **Ports are declared by the layer that consumes them.** A port is a protocol
  expressed in domain types and declared in Domain or Application, then
  implemented in Infrastructure or Platform. This keeps the dependency arrows
  pointing inward.

## 5. Workflow Stages and Their Boundaries

The pipeline below is **Accepted**. Each stage has its own capability boundary,
security model, failure domain, and test strategy. Stages may be exposed to the
user independently; they are not one indivisible operation.

```
Inspection ──▶ Signing ──▶ Verification ──▶ Packaging ──▶ Installation
```

| Stage | Purpose | Privileged input | Principal boundary |
| --- | --- | --- | --- |
| Inspection | Read an untrusted archive, discover the application bundle, nested code, metadata, and signing-related material; report diagnostics. | None | Untrusted input parsing and decompression limits |
| Signing | Produce new signature material for the bundle and its nested code using a selected identity and profile. | Private key access | Key material and platform cryptography |
| Verification | Independently evaluate the produced artifact against the rules it is supposed to satisfy. | Public certificates and profiles only | Implementation of verification itself |
| Packaging | Build a new archive containing the modified bundle and its preserved content. | None | Metadata preservation and deterministic layout |
| Installation | Deliver a signed archive to a device. | Device authorization | Platform policy, authorization, and user consent |

Constraints, all **Accepted**:

- **A successful signing stage does not imply installability.** Packaging and
  installation each add independent preconditions: profile-to-device
  authorization, profile type, trust, expiry, OS compatibility, and — for
  on-device scenarios — the fact that a device cannot generally be treated as
  authorized for an artifact merely because ZynSign produced it on that device.
- **Verification must not reuse signing state.** It re-derives its conclusions
  from the artifact and from public material, so that a signing-side bug cannot
  silently validate itself. Sharing parsing code between the two is acceptable;
  sharing conclusions is not.
- **Inspection never touches key material.** The inspection stage is designed to
  run against hostile input with no privileged capability available at all.
- **Installation is a separate capability boundary.** It carries its own security
  model (device authorization, trust in the signing identity, and explicit user
  consent), its own platform constraints and feasibility questions (Section 6,
  item 15), its own error model — where "not installable" is a normal outcome
  rather than a signing failure — and its own physical-device test strategy
  (Section 16). Whether installation belongs in the first release is
  **Unresolved** (Section 6, item 15).

## 6. Feasibility Boundaries

The intended workflow executes on-device, but the availability of each required
Apple signing operation to an iOS/iPadOS application is **not** established. The
table below is the authoritative list of feasibility boundaries. Every row is
**Requires feasibility research** unless stated otherwise.

| # | Area | Why it is a boundary |
| --- | --- | --- |
| 1 | Cryptographic signing primitives | Which digest and signature algorithms are usable by an application, on which key types, with which attributes and usage restrictions. Availability documented for one Apple platform does not establish it for another. |
| 2 | Private-key storage and access | Whether a code-signing private key can be imported, stored, protected, and used on the device at all; what protection class and per-use authorization apply; whether it can be marked non-exportable. See Section 7. |
| 3 | Certificate handling | X.509 parsing, chain assembly, issuer and expiry interpretation, and whether trust evaluation is available to an application or must be implemented. |
| 4 | CMS / PKCS#7 signature construction | Apple's signed-data encoding services are documented for macOS and are not documented for iOS; whether any supported equivalent exists is unverified. If none exists, the format must be built or supplied by a dependency. **Verification** of an existing SignedData message is no longer blocked by this row: the absence of an iOS CMS decoder is established (**Verified** — Apple Security documentation), so a bounded reader and the documented key primitives perform it (Section 7, Provisioning Profile CMS Verification). **Construction** remains open, and the on-device behaviour of the verification path still needs experiment E4. |
| 5 | CodeDirectory generation and modification | Which code-directory versions, hash types, special slots, and code-limit/page-size conventions the target platform requires and accepts. |
| 6 | Code-signature blob embedding | Constructing and replacing the signature region of a Mach-O binary, including load-command layout, segment offset and alignment rules, and fat/universal binaries. |
| 7 | Entitlement handling | Building entitlement blobs, the relationship between profile-derived entitlements and binary entitlements, and which entitlement data forms the platform expects. |
| 8 | Provisioning-profile interpretation | The profile is signed structured data; parsing it is distinct from validating the container signature, and both are required before a profile can be trusted for authorization decisions. Parsing and container signature verification are implemented and kept as separate states (Sections 7 and 12); signer-certificate **trust**, revocation, Apple issuance, and every authorization decision remain open and are not claimed. |
| 9 | Resource sealing | Reproducing the resource-seal form the platform evaluates, including how rules have changed across OS versions and which resources are sealed. |
| 10 | Nested-code handling | Deterministic discovery and signing order for frameworks, dynamic libraries, extensions, plug-ins, nested bundles, and nested applications, including exception cases. |
| 11 | Signature verification | The system code-signing validation services used on macOS are not assumed available to iOS applications. On-device verification may have to be implemented, with all of the format knowledge that implies. |
| 12 | IPA packaging | Archive writing and the layout, ordering, permissions, symlinks, and metadata the platform expects in a redistributable package. |
| 13 | Archive reading capability | Which archive container features can be read reliably on-device, and what resource limits can be enforced while reading. Narrowed by measurement rather than assumption: container reading is implemented and bounded (Section 9), but the deployment target is still Unresolved, so no claim is made yet about behaviour across the versions ZynSign may support. |
| 14 | Filesystem and sandbox behaviour | Working space, large-file handling, atomic replacement, metadata fidelity, and lifecycle interruptions inside the application container. See Section 8. |
| 15 | Installation mechanism | No public application-facing mechanism is known for installing an IPA onto the device running ZynSign. Candidate mechanisms are external to the application (managed-device installation, over-the-air distribution with user confirmation, host-based tooling). This is **Unresolved**; installation may not belong in the first release. |
| 16 | Key import and export constraints | Whether existing developer key material can be imported at all, and what platform restrictions apply to imported material. |
| 17 | Deployment target | Minimum supported iOS/iPadOS version, and therefore which APIs, archive features, and storage semantics are even available. **Unresolved** — a product decision with technical consequences. |

Research expectations, **Accepted**:

- Each boundary has a question with an explicit exit criterion. A boundary closes
  when the answer is demonstrated on a supported deployment target — not when an
  API appears to exist, and not when a similar capability is known to work on
  another Apple platform.
- Where an answer is negative, the affected capability is removed from the
  product scope or implemented differently, and this document is revised.
- No production implementation is committed for a capability whose boundary is
  still open.
- Some boundaries are informative rather than blocking. For example, a negative
  result on item 15 removes installation from the first release but leaves
  inspection, signing, verification, and packaging unaffected.

## 7. Key Material, Identities, and Signing Capability

The architecture distinguishes five concepts that are frequently conflated. The
distinctions are **Accepted**; the mechanisms behind them are not.

| Concept | Nature | Where it may appear |
| --- | --- | --- |
| Certificate metadata | Public, inspectable fields: subject, issuer, serial, validity, key algorithm and size, usage information. | Domain, Presentation, diagnostics |
| Private-key material | Secret key bytes. | Nowhere except the boundary that performs signing |
| Key reference / handle | An opaque, platform-scoped handle to a stored key. Not a secret, but not portable, serializable, or meaningful outside the process. | Application and Platform only |
| Signing-identity metadata | The operational pairing of a certificate with a usable matching key, as presented for selection and status. | Domain, Application, Presentation |
| Signing capability | The ability to produce a signature for a given identity. Exists only if usable key material is available. | Platform, behind a signing boundary |

Rules, **Accepted**:

- Private key material must not reach Presentation, persistence, logs,
  diagnostics, crashes, Domain models, or unrelated infrastructure.
- A certificate being present and valid is not evidence that its private key is
  available or usable. Certificate inspection, identity resolution, and signing
  authorization are separate operations with separate outcomes.
- A key reference is not a security boundary in itself. It is a handle whose
  protections come from the operating system, not from the type that wraps it.
- No UI layer may hold or display anything beyond identity metadata and status.
- Identity status must express unavailability, expiry, and unsuitability
  distinctly, because those conditions have different user remedies.

**Unresolved — requires dedicated feasibility research:** whether Apple
code-signing key material can be imported, protected, and used by an iOS/iPadOS
application, and which platform API provides that capability. Keychain behaviour
on iOS/iPadOS differs from macOS in access control, protection classes,
availability of key material to the process, and per-use authorization, and none
of those differences may be assumed away. The implementation mechanism for key
storage and use is deliberately not chosen here: it is a research outcome, and no
API is specified in this document before that research exists.

### Certificate and Signing Identity Foundation

This increment establishes the domain foundation required before any signing
engine is built. It is architecture and safe metadata handling, not signing.

**Accepted — certificate vs signing identity distinction.** A certificate is
public, inspectable metadata; a signing identity is certificate information
plus access to the corresponding private signing capability. The domain model
makes this explicit:

```
Certificate
     +
Private Signing Capability
     =
Signing Identity
```

A certificate can exist independently. A signing identity exists only when a
matching private capability is available or its absence is explicitly
represented. The two are never equated. **Verified** from X.509 and platform
documentation that possession of a certificate does not provide the private
key.

**Accepted — certificate domain model.** `CertificateMetadata` is a
platform-independent value type that records what a certificate declares:
subject, issuer, serial number, validity start/end, public-key algorithm and
size/curve where applicable, signature algorithm, SHA-256 fingerprint, and
chain relationship where known. The serial number is the hexadecimal form of
the INTEGER content octets, including a leading `0x00` when the encoding uses
one. It is not converted to a machine integer. It carries no raw DER bytes,
no platform `SecCertificate` object, no private-key material, and no trust
evaluation. Raw DER bytes, when needed for later CMS construction, are
represented by `Certificate` and `CertificateData` with an explicit ownership
boundary: owned by the component that accepted them, provided to the signing
boundary only when needed, never persisted in `ApplicationRecordStore`, never
logged, never exposed through UI beyond metadata and fingerprint. Inspection
does not retain a `SecCertificate`.

**Accepted — distinguished name handling.** Subject and issuer are
`CertificateDistinguishedName`. Attributes are kept in certificate order,
including attributes ZynSign does not recognise. Common name, organization,
organizational unit, country, locality, state or province, and email are
also exposed as fields; the first decoded text value of each recognised type
fills the field, and later values remain in `attributes`. The display string
is separate from that structured representation and is not a canonical
encoding. An unusual or unrecognised attribute does not fail the parse.

**Accepted — public-key and signature algorithm modeling.** `PublicKeyInfo`
holds algorithm (RSA, EC, unknown), key size in bits, curve name, and curve
identifier where the certificate carried one. The signature algorithm is read
from the certificate's signature field and is not inferred from the public-key
algorithm. `SignatureAlgorithm` enumerates common algorithms
(sha256WithRSAEncryption, ecdsa variants, Ed25519) with `unknown` preserving
the raw OID. An unrecognised key or signature algorithm is recorded; it does
not by itself fail parsing. `appearsAdequateForCodeSigning` (RSA ≥ 2048, EC
P-256 or larger, including the named curves P-256, P-384, and P-521) is a
domain heuristic, not a platform policy decision. P-521 is 521 bits.

**Accepted — fingerprint.** `CertificateFingerprint` is SHA-256 of the exact
DER bytes that were accepted, lowercase hexadecimal, 64 characters. It is
computed in Platform by a FIPS 180-4 SHA-256 implementation over those bytes.
CryptoKit `SHA256` is available on iOS 17 (**Verified** — Apple CryptoKit
documentation) and is not used, so the digest does not depend on
`SecCertificateCopyData`. Apple does not state that `SecCertificateCopyData`
returns the input bytes unchanged (**Unknown**). The fingerprint identifies
bytes only. It is not trust, not a chain proof, and not an Apple code-signing
identity.

**Accepted — validity vs parsing vs trust vs suitability.** Four concepts
are kept distinct:

- structurally parseable (existence of `CertificateMetadata`),
- validity-period status (`CertificateValidity` with `notYetValid`,
  `currentlyValid`, `expired`), evaluated inclusively against an explicit
  date from the caller or from an `EvaluationClock` injected at the
  inspection boundary — the comparison does not read the system clock,
- intended usage where verifiable (key usage, extended key usage) — not
  evaluated in this milestone, represented as `notEvaluated`,
- trust/chain evaluation — not implemented in this milestone,
  represented as `notEvaluated`.

Parsing succeeded ≠ currently valid ≠ trusted ≠ suitable for code signing.
`CertificateTrustEvaluation` and `CodeSigningSuitability` make the
distinction explicit. `CodeSigningSuitability` documents exactly what is
checked in this milestone: parsing, validity period currently valid,
recognised key algorithm with adequate size/curve, recognised signature
algorithm not SHA-1 based. What is **not** checked: key usage/EKU, trust,
Apple policy, profile association, private-key availability. Final policy
decision belongs to later work.

**Accepted — certificate chain.** `CertificateChain` holds
`[CertificateMetadata]` leaf-first, with `leaf`, `intermediates`, `root`
conveniences. It represents relationship, not trust. Empty chain is invalid
and not constructible. The domain can represent chain relationships without
hard-coding one-certificate-equals-identity.

**Accepted — certificate parsing boundary.** `CertificateParser` is declared
in Domain and implemented in Platform as `AppleCertificateParser`. Input is
untrusted bytes (`CertificateInput`). Empty input, truncated encoding,
malformed structure, PEM text, indefinite-length encoding, non-minimal DER
lengths, and input over the inspection bound produce typed `ZynSignError`
values. Nothing in the certificate is executed. Diagnostics do not contain
certificate bytes.

The metadata source is a bounded first-party DER reader, not a platform
field dictionary:

- `SecCertificateCopyValues` is documented for macOS 10.7+ and is not in the
  iOS API surface (**Verified** — Apple Security documentation). It is not
  called. An earlier statement in this document that it was verified on iOS
  was wrong.
- `SecCertificateCreateWithData` exists on iOS 2.0+ (**Verified**). It returns
  nil when Apple does not accept the bytes as DER-encoded X.509. That result
  does not distinguish empty, truncated, malformed, and unsupported input.
  Whether it accepts unrecognised algorithms, GeneralizedTime, or unusual
  names was not measured (**Requires experiment**). Inspection does not use a
  nil return as a rejection gate, and it does not retain a `SecCertificate`.
- `SecCertificateCopyData` exists on iOS 2.0+ (**Verified**). Byte-identity
  with the input is not stated (**Unknown**). The fingerprint is the SHA-256
  of the accepted input.
- `SecCertificateCopyKey` exists on iOS 12.0+ (**Verified**) and returns nil
  for an unsupported key encoding. Agreement between `SecKeyCopyAttributes`
  and the certificate's own fields, including leading-zero serial octets, was
  not measured (**Requires experiment**). Key characteristics are read from
  the certificate encoding. The key algorithm is not inferred from the
  signature algorithm.
- No published size limit for `SecCertificateCreateWithData` was found
  (**Unknown**). ZynSign refuses certificate input larger than 256 KiB. That
  bound is ZynSign policy, not an Apple limit. Constructed nesting is capped
  at 16, also ZynSign policy.

No third-party ASN.1 or X.509 library is used. The reader covers the fields
the domain model requires. Extensions, issuer unique ID, and subject unique
ID are skipped rather than interpreted. An unrecognised algorithm or name
attribute is preserved. A mismatched signature-algorithm identifier between
the TBS certificate and the outer certificate is rejected as invalid
structure. Inspection does not evaluate a signature or a chain.

**Accepted — signing capability protocol.** `SigningCapability` is a narrow
abstraction for future cryptographic signing, declared in Domain:

```
SigningCapability
    sign(data, explicit message-or-digest algorithm) -> signature
```

It exposes identity ID, public-key algorithm, supported algorithms, availability,
and a signing method that returns signature bytes only. It does not expose
private-key bytes, does not reveal storage location, and supports future
implementations where signing occurs through a protected key handle
(Keychain `SecKey` non-exportable, Secure Enclave-backed where applicable).
It does not implement the code-signing engine.

**Accepted — identity store boundary.** `IdentityStore` protocol declared in
Application (per Section 11), implementation in Platform. It answers list
identities, retrieve identity metadata, access signing capability. Security
boundary:

- Private key material never exposed; callers receive `SigningCapability`.
- Private keys not persisted in `ApplicationRecordStore`.
- No automatic import of arbitrary certificates or private keys.
- `.p12` / PKCS#12 import not implemented in this milestone; treated as
  separate capability.

### Secure Identity Storage Decision

**Accepted — capability instead of key bytes.** ZS-016 retains the existing
Domain/Application ports. `SigningAlgorithm` makes message hashing, digest
length, key family, and signature encoding explicit. The earlier default
forwarding a digest as a message was ambiguous and is removed. Identity
snapshots distinguish key availability, public-key association, and primitive
readiness; none implies trust or a successful signing operation.

**Provisional — experimental Keychain adapter.** `SecureIdentityStore` uses a
Platform registry and resolver. `KeychainIdentityRegistry` stores a minted UUID,
public certificate DER, and an opaque persistent key locator in device-only,
unlocked, non-synchronizable Keychain records. Registration validates already
stored keys; it does not import keys. Removal deletes the registration, never a
borrowed private key. Capabilities re-resolve on every operation, comparing the
certificate and key's actual public representations. Only signatures cross the
private-key boundary. No identity storage is added to the application catalog,
composition root, or presentation environment.

**Requires experiment — production activation.** Feasibility Section 16.2's E7
gate is preserved. The adapter is not a production storage claim; protection
attribute behavior, persistent-reference lifecycle, lock state, and signing
must be established on physical iOS/iPadOS 17+ devices. PKCS#12 remains deferred.
The [security design](../security/signing-identities.md) records ownership,
error redaction, API availability evidence, test scope, and unresolved questions.

**Accepted — PKCS#12 as separate capability.** PKCS#12 import is not
`.p12 → certificate + exportable private key` only. Feasibility research
records:

- `SecPKCS12Import` available on iOS (**Verified**),
- only legacy PBE algorithms supported (SHA1/3DES, SHA1/RC2-era); modern
  AES-based PBE fails (**Verified** via Apple DTS 2021–2023),
- imported keys are non-extractable yet usable for signing (**Verified** via
  DTS), attribute control at import time **Unknown — Requires experiment**,
- per-use authorization (biometrics on key use) **Unknown — Requires
  experiment**,
- Device-only accessibility, uninstall semantics, and access-control flags
  require physical-device validation.

No PKCS#12 import is implemented in this milestone. A dedicated feasibility
experiment is required before implementation.

**Accepted — code-signing suitability.** `CodeSigningSuitability` evaluates
whether a certificate appears suitable for code signing based on checks
performed in this milestone, with explicit unsuitability reasons. It does not
label every certificate as valid signing certificate and does not claim
platform acceptance.

**Security boundary, Accepted:**

- Private key bytes are never persisted, never logged, never appear in
  `ApplicationRecord`, `CertificateMetadata`, `SigningIdentity`, or
  diagnostics.
- Certificate parsing does not execute arbitrary content; malformed input
  produces structured errors.
- Raw certificate DER is public but treated as untrusted and not logged in
  full; owned by Platform, provided to signing boundary only when needed.
- Sensitive values (private key material, passwords, auth tokens, complete
  credentials) are never logged.
- Identity abstractions do not require key export.

**Unresolved — Requires experiment:**

- Exact iOS Keychain behavior for imported signing keys: extractability
  control at import time, accessibility classes, per-use authorization,
  lock-state behavior, background access, uninstall retention — needs
  physical-device experiment E7 from feasibility doc.
- `SecTrust` with code-signing policy (`kSecPolicyAppleCodeSigning`)
  behavior on iOS for Apple-issued chains — needs experiment E13.
- CMS SignedData construction on iOS — no CMS API (**Verified** absence via DTS
  2017–2023 and per-symbol Apple documentation), custom implementation
  required, highest-risk component — needs experiment E4.
- CMS SignedData *verification* on iOS — implemented without any CMS API: a
  bounded structure reader plus `SecKeyVerifySignature` behind a port
  (**Verified** absence of `CMSDecoderCreate`, `CMSDecoderCopySignerStatus`,
  and `CMSSignerStatus` on iOS from Apple documentation; the on-device
  behaviour of the substitute path is **Requires experiment** E4, and the tests
  that would establish it are gated on iOS).
- Provisioning-profile container verification — the container boundary is
  implemented and its states are separate from parsing, trust, and
  authorization; device confirmation of the platform primitives remains
  experiment E3.
- Whether `SecCertificateCreateWithData` accepts the certificates inspection
  parses, including unrecognised algorithms and GeneralizedTime, and whether
  `SecCertificateCopyData` preserves the input bytes — **Requires
  experiment**. Inspection does not depend on either result.

**Trust-validation boundary, Accepted:** No trust evaluation is implemented
in this milestone. `CertificateTrustEvaluation` represents trust as
`notEvaluated`. A successfully parsed certificate is not proof that an
application is trusted. Full Apple trust validation is not claimed unless
implemented and verified.

**Persistence boundary, Accepted:** Certificate raw bodies and private keys
are classified sensitive per Section 15. They are not stored in ordinary
application storage (`ApplicationRecordStore`, catalog JSON). `ApplicationRecord`
has no field that can carry them, verified by tests.

**UI scope, Accepted:** No certificate-management UI is built in this
milestone. No controls for sign, resign, install, select provisioning
profile, select device, export private key are added.

### Provisioning Profile Parsing Foundation

**Accepted for ZS-017 — input and CMS boundary.** A profile enters the
pipeline as `ProvisioningProfileInput`, a bounded value containing only the
untrusted bytes presented by the caller. `ProvisioningProfilePayloadDecoder`
is the explicit seam for CMS/container handling. It returns decoded property-list
bytes in `ProvisioningProfilePayload`; it does not make those bytes authentic by
itself. No CMS decoder or verifier is implemented in this increment, and no
embedded `embedded.mobileprovision` entry is read by the existing archive
inspection workflow.

**Observed in the implementation — typed payload model.**
`PropertyListProvisioningProfileParser` accepts binary or XML property-list
payloads, rejects empty, oversized, malformed, non-dictionary, and unsupported
OpenStep payloads, and ignores unknown top-level fields. It produces
`ProvisioningProfile` with optional UUID/name/date/platform/prefix/team/device,
certificate-reference, classification, and flag fields. The application
identifier keeps its full value separate from an explicit prefix and derives a
`BundleIdentifier` component only when the prefix boundary makes that
interpretation safe. Exact wildcard components are represented separately; a
prefix is never inferred by splitting at the first period.

Entitlements are `ProvisioningProfileValue` trees, not `[String: Any]` blobs.
Strings, booleans, integer and real numbers, data, dates, arrays, and
string-keyed dictionaries retain their types. Unknown entitlement names are
preserved, while unsupported types and bounded resource violations fail closed.
The parser may attach `CertificateMetadata` to full `DeveloperCertificates`
entries through the existing `CertificateParser` port. That metadata is public
certificate information only and never implies a matching private key.

**Accepted — structural validation boundary.** `ProvisioningProfileValidator`
checks required metadata, date ordering, identifier/prefix consistency,
collection invariants, and the injected creation/expiration period. It returns period states of
malformed, not-yet-valid, currently-valid, or expired; ordered intervals use
inclusive boundaries. Parser-level date type/encoding failures are controlled
errors, while a reversed ordered interval is a parsed `.malformed` period
state. An expired or future profile can be structurally parseable; period
status is not trust or platform authorization. Profile classification is
`development`, `adHoc`, `appStore`, `enterprise`, or `unknown`; the known cases
require multiple coherent fields and conflicting or insufficient evidence stays
unknown.

**Trust boundary, Accepted.** ZS-017 exposes four distinct facts: a payload was
parsed; its required fields passed the structural validator; CMS authenticity is
`notEvaluated`; and authorization is `notEvaluated`. Neither parsing nor
structural validity proves a CMS signature, an Apple certificate chain, private
key possession, entitlement authorization, device authorization, bundle
compatibility, platform support, installability, or signing permission. A later
CMS verifier may attach authenticity evidence through the payload/result seam;
a later policy stage must still evaluate authorization separately.

**Evidence status.** The type and dependency boundaries above are **Observed**
from this repository's implementation. The profile/CMS structure and the
absence of a documented iOS CMS decoder remain **Verified/Requires feasibility
research** as recorded in `on-device-signing-feasibility.md`; no local iOS
build or device experiment was available in this environment. Entitlement
authorization rules, DER-encoded profile precedence, signer-chain policy, and
platform acceptance remain **Unknown or Requires experiment**.

### Provisioning Profile CMS Verification

**Accepted for ZS-018 — the container boundary is ZynSign's own reader.**
Apple's CMS decoder family is documented for macOS only: `CMSDecoderCreate`
and `CMSDecoderCopySignerStatus` list macOS 10.5 with no iOS availability, and
`CMSSignerStatus` lists macOS and Mac Catalyst only (**Verified** — Apple
Security documentation, checked per symbol). No CMS API is called anywhere in
this repository, and none is abstracted behind a port that a later increment
could satisfy on iOS. `CMSStructureReader` walks the RFC 5652 SignedData subset
a provisioning profile uses, in the Platform layer, over bounded untrusted
bytes, and returns a structural description — content type, version, declared
digest algorithms, encapsulated content, certificate-bag encodings, revocation
entry count, and signers — rather than a verdict. The signature itself is
checked through the `CMSSignatureVerifier` port, whose iOS implementation uses
documented key primitives: `SecCertificateCreateWithData` (iOS 2.0+),
`SecCertificateCopyKey` (iOS 12.0+), and `SecKeyVerifySignature` (iOS 10.0+)
under message-based algorithms, so hashing stays inside the platform primitive
rather than in ZynSign code.

**Observed in the implementation — verification order.** The boundary applies,
in order: input bounds (empty and 4 MiB caps); structural reading with typed
rejection of armored, indefinite-length, non-minimal, high-tag-number,
truncated, trailing-data, and out-of-order encodings; encapsulated-content
presence (detached content is refused rather than approximated); parsing of
every certificate-bag entry through the existing `CertificateParser` port, with
unparsable entries counted and discarded; exactly one signer, since ZynSign does
not choose between several; signer-certificate selection by serial number;
algorithm mapping; message-digest binding; and finally the signature check.
Steps that establish nothing cryptographic produce returned evidence, not
exceptions: a container that decoded and did not verify is a normal result, so a
caller can distinguish a rejected container from one that could not be
evaluated. Structural problems are typed `ZynSignError` values carrying a
`CMSFailure` reason.

**Observed — signed attributes change what is signed.** When a signer carries
signed attributes, the signature covers their DER re-encoding as a `SET OF`, not
the `[0] IMPLICIT` form in the message, and the payload is bound to that
signature only through the message-digest attribute. The reader therefore
reconstructs the attribute set encoding with minimal definite lengths, and the
boundary compares the message-digest attribute with the SHA-256 digest of the
encapsulated content *before* any signature check. A missing message-digest
attribute is a structural refusal; a digest of the wrong length is reported as
an unsupported algorithm; a digest that does not bind the content is reported as
`.invalid` without asking a platform primitive to verify anything. A content-type
attribute that disagrees with the encapsulated content type is recorded as an
observation, not a failure, because the signature's binding to the payload is
what authenticity rests on.

**Accepted — certificate identity is compared by fingerprint.** The signer is
related to an embedded certificate by the serial number the identifier names,
and the signer certificate is related to the profile's own
`DeveloperCertificates` entries and to locally listed identities by the SHA-256
fingerprint of exact DER bytes. Subject names, labels, bag order, and profile
order are never used for matching; a bag that lists the signer second, a bag
holding an unparsable entry, and a profile listing the same certificate twice
each produce an explicit outcome. Two embedded certificates matching one serial
is reported as `.ambiguous` rather than resolved, and a subject-key-identifier
signer is reported as `.identifierNotMatchable` rather than matched by
approximation. A serial collision between different issuers inside one bag would
also be reported as ambiguous, because the issuer name in the identifier is not
re-parsed at this boundary; that conservatism is deliberate and recorded.

**Accepted — five states stay separate.** Parseable, structurally valid,
cryptographically authentic, certificate trusted, and platform authorized are
distinct evidence, and no single validity flag summarizes them.
`CMSVerificationResult` carries the signature status, the structured reason and
redacted detail, the signer count, the payload, the signer certificate and its
extraction status, the signer identifier, the embedded certificates and the
unparsable count, the declared and mapped algorithms, the signed-attribute
observation, and trust state. Trust is `notPerformed` — this increment evaluates
no chain, anchor, revocation, or platform policy — and authorization stays
`notEvaluated`. A `.verified` status means one thing: the signature over the
authenticated content was produced by the private key matching the signer
certificate's public key. It does not mean the certificate is trusted, that
Apple issued it, that ZynSign holds its key, or that the profile authorizes
anything.

**Accepted — application composition.** `ProvisioningProfileVerificationUseCase`
sequences the boundary, the existing ZS-017 parser and validator, and
`CertificateRelationshipAnalyzer`. It parses a payload only when the signature
verified, so unauthenticated profile metadata is never produced by this path;
the same verifier also backs the existing `ProvisioningProfilePayloadDecoder`
seam, which hands over `.authenticated` payloads, fails closed on rejected
containers, and marks unevaluated ones `.notEvaluated`. An identity store may be
supplied and is used read-only: listing identities answers a certificate
relationship, while requesting a signing capability or producing a signature to
prove one is prohibited, and an unreadable store is recorded as a failed lookup
rather than propagated as a verification failure.

**Accepted — hostile input and redaction.** Bounds are ZynSign policy, not
published limits: constructed nesting depth 16, certificate-bag entries 16,
signers 8, signed attributes 32, declared digest algorithms 8, identifier
values 64 bytes, signature values 1024 bytes, and the existing 4 MiB input and
payload caps. Nothing in a container is executed; no CLI or private API is
invoked. Diagnostics carry states, counts, algorithm identifiers, fingerprints,
and mapped platform error codes only — never container bytes, payload bytes,
certificate bodies, or foreign error text, which is why a foreign failure is
reduced to its CMS reason before it is stored.

**Deferred, recorded.** The CMS structure reader has its own bounded DER
scanner instead of sharing the certificate reader's private one. Their
structures, bounds, and failure taxonomies differ, and consolidating them
without a compiler in this environment was judged riskier than the duplication;
the cleanup is recorded here rather than performed blind. DER-encoded
`embedded.mobileprovision` handling is unchanged: profile bytes are read, never
modified or stripped, and archive inspection still does not read embedded
profiles. Trust evaluation, signing policy, compatibility decisions,
installation, persistence, and profile-management interfaces remain out of
scope, as does CMS *construction*.

**Evidence status.** Availability of each Apple symbol cited above is
**Verified** from Apple's platform documentation. The structure, ordering,
bounds, state separation, and redaction rules are **Observed** from this
repository's implementation. Whether the substitute verification path behaves
identically on a device — `SecCertificateCopyKey` agreement with the
certificate's own key fields, `SecKeyVerifySignature` acceptance of the
re-encoded attribute set, and behaviour for unusual certificates — remains
**Requires experiment** (E3, E4); the tests that would establish it are gated on
iOS and were not executed in the environment where this increment was written.
Signer-chain trust, revocation, Apple issuance rules, and every authorization
question remain **Unknown**.

## 8. Filesystem, Sandbox, and Document Handling

ZynSign runs inside the application sandbox. It has **no** unrestricted
filesystem access, and the architecture is designed around that rather than
compensating for it. The following constraints are **Accepted**; the specific
mechanisms at the end of this section are **Unresolved**.

- **Input arrives through user selection.** An IPA reaches ZynSign through a
  user-initiated document pick, an import from another application, or a
  file-provider URL. Access may be scoped to a user grant and may require
  explicit coordination with the providing process.
- **Working data lives in the application container.** Extraction, transformation,
  and packaging use application-owned directories with the protections the
  platform applies to those locations.
- **Storage is finite and reclaimable.** The system may purge temporary and
  cache-like data, and available space can change while a long operation is
  running. Copying an IPA, extracting it, and rebuilding it can require several
  times the archive's size at peak.
- **Cleanup is part of the operation, not an afterthought.** Imported archives,
  extracted trees, intermediate signature material, and produced artifacts all
  have a defined lifetime, and cleanup runs on success, on failure, and on
  cancellation.
- **Lifecycle interruption is expected.** The application can be suspended,
  backgrounded, terminated, or have its file access revoked mid-operation. No
  workflow may depend on unbounded background execution.
- **Failure must not leave sensitive residue.** A crash or forced termination must
  not leave private key material, profile data, or partially written artifacts in
  a location that outlives its purpose.

**Unresolved — requires dedicated feasibility research:** the concrete
mechanism for each of these, in particular security-scoped access to
user-selected locations, the correct temporary-directory strategy for large
archives, atomic replacement of a signed artifact, whether file coordination is
genuinely required for any supported input path (as opposed to merely defensive),
storage-pressure and low-disk handling, and crash-recovery semantics that are
neither silent nor dependent on leaving sensitive data behind. File coordination
is not introduced speculatively; it is added only where a real input path
requires it.

### Import Staging Decision

The document-import path settles two of the mechanisms above for its own
input path, and the decision is recorded here because every later workflow
that consumes an imported package builds on it.

**Accepted:** a user-selected package is staged exactly once — copied in
bounded chunks, never held whole in memory — into an application-owned
temporary directory whose file names are freshly minted artifact identifiers
alone, so no part of a selected document's name or content can influence
where staged bytes are written. Security-scoped access to the selected
document is acquired immediately before the copy and released when staging
ends, on every outcome; the grant is never persisted and never leaves the
platform layer. The system document picker restricts the choice to the
`.ipa` type, and the application layer applies the same extension policy as
a cheap gate; the extension is never trusted as evidence about content, and
only the archive and metadata examinations decide whether a staged file is a
valid package.

The staged archive's lifetime is explicit and ends inside the import use
case. It is discarded when staging fails, when the import is cancelled, and
when the package is rejected by examination. An accepted import's archive is
offered to the library, which either adopts it — moves it, under the same
identifier, into durable application-owned artifact storage (Section 15) —
or recognises it as content the library already holds, in which case the
staged copy is discarded. Whatever is left in the staging directory by an
interrupted process is cleared before the first import of the next one;
because adoption moves the file out of staging, nothing a record depends on
is ever there to be cleared. Nothing staged survives implicitly.

**Still Unresolved:** file coordination for provider-backed locations,
concurrent imports into shared staging space, storage-pressure handling, and
crash-recovery semantics beyond the clear-at-next-launch behaviour recorded
above.

## 9. Archive and IPA Handling

Archive processing is independent of the UI and independent of the signing and
installation stages. An imported IPA is treated as untrusted input, in the form
of a ZIP-compatible container whose contents are also untrusted. The threats
below must be handled by whichever implementation is chosen; the threats are
**Accepted** as in-scope, the implementation is **Unresolved**.

- **Path traversal and unsafe paths** — absolute paths, `..` components,
  drive-style prefixes, and paths that escape the extraction root.
- **Symbolic links** — links pointing outside the extraction root, links forming
  loops, and links whose target only exists after later extraction.
- **Duplicate and colliding entries** — identical names, names differing only by
  case or normalization, and file-versus-directory collisions.
- **Malformed archives** — corrupt central directory, truncated entries, bad
  checksums, inconsistent sizes, and unsupported container features.
- **Resource exhaustion** — entry-count bombs, size bombs, extreme compression
  ratios, and archives that are small on disk but enormous when expanded.
- **Unexpected metadata** — unusual permissions, ownership fields, timestamps,
  and platform-specific metadata that the platform cannot faithfully reproduce.
- **Malformed structured data** — plists with unexpected types or nesting, and
  bundles whose declared structure disagrees with their contents.
- **Malformed binary data** — executables that are unreadable, truncated, an
  unsupported format, or inconsistent with their declared metadata.
- **Unexpected nested content** — code-bearing content in locations the layout
  rules do not expect, and bundles nested to unexpected depth.

Rules, **Accepted**:

- Bounded resource limits are architectural policy, not implementation detail:
  the reader must be able to refuse work before or during extraction rather than
  discover exhaustion after it.
- Archive access is exposed behind a narrow boundary that returns domain types
  and structured diagnostics (Section 11).
- Archive structure alone never establishes that a package is valid, signed, or
  installable.
### Reading Decision

The container-reading capability is no longer undecided for the inspection
stage, and the decision is recorded here because it is architectural rather than
incidental.

**Accepted — reading:** ZynSign reads ZIP containers with an implementation it
owns, in the Platform layer, behind the `ArchiveReader` boundary. No third-party
archive library is introduced.

**Why a library was not selected.** The premise that a library would have to
supply this capability was re-examined rather than assumed. The platform was
checked first, as this document requires: Apple provides no container-level
archive interface on the product runtime, and the platform compression service
operates on compressed byte streams rather than on the container that holds
them, so no system interface answers the questions inspection asks. A library was
therefore a genuine candidate and is not rejected on principle — but the
capability inspection needs is a deliberately narrow subset: enumerate the
container's entries, refuse unsafe names before anything is read, enforce a
resource policy, and produce the content of one named entry within a bound. It
does not need writing, updating, spanning, or decryption. Against that subset,
introducing a general-purpose dependency would add a maintenance and security
obligation to the product, and would place the enforcement point for this
project's own resource policy outside this project's control. The architecture
already requires those limits to be enforceable *before or during* work rather
than discovered afterwards, and that requirement is easier to keep honest inside
an implementation whose only job is reading.

**Consequences, Accepted.** The implementation is a read-only inspector, not a
ZIP implementation, and its limits are stated rather than implied: it supports
the content encodings application packages use and reports everything else as
unsupported. It is reached only through the `ArchiveReader` port, so replacing it
— with a different engine, an optimized reader, or a library chosen later — is a
change in the composition root and one Platform type. Packaging will need a
writer, and that is a separate decision this does not settle; a writer has
different requirements, different risks, and different consequences, and it is
not implied by this one.

**Still Unresolved:** the writing side of packaging, and the extraction boundary
that later workflows will need. Neither exists yet, and neither may be inferred
from the reading decision above.

### Bundle Inspection Decision

The Applications area's bundle explorer is the first consumer of the archive
boundary after import, and how it reaches a bundle is an architectural
decision rather than a screen detail.

**Accepted — inspection reads the container's entry table; it does not
extract.** The library keeps each application as the package it was imported
from, so the application bundle exists only inside that container. The
explorer therefore derives the bundle's structure from the entry table
`ArchiveReader` already produces — names, kinds, and declared sizes, read
from the container's own records — restricted to the entries inside the
discovered bundle directory. No entry's content is read, nothing is extracted
to a filesystem, nothing is hashed, and no file inside the bundle is parsed:
not the information file, not an embedded profile, not the code-signature
records, not the executable. Enumerating a bundle costs the same whether its
files are small or enormous, and the extraction boundary that later workflows
may need remains as Unresolved as the Reading Decision left it; nothing here
may be read as a step toward it.

**Why no second reader or store.** The capability the explorer needs —
enumerate, restrict, describe — is a subset of what the archive boundary
already provides for import, and the bytes it describes are the bytes
`LibraryArtifactStore` already owns. A second reader would duplicate the
enforcement point for the resource policy and the path safety rules; a second
storage convention would duplicate the artifact-ownership rules of Section 15.
The use case (`IPABundleContentsInspection`) composes the existing library
use case, which reports whether the record's artifact is available as
recorded, with the existing `ArtifactArchiveReaderProvider` over library
storage, and nothing else. A record whose artifact is missing or no longer
matches the record is refused with a typed error before any container is
opened, and the detail screen offers the explorer only for an available
artifact.

**Path safety, Accepted.** Locations inside a bundle are a domain value
(`BundlePath`) relative to the bundle root, constructed under the same rules
as `ArchivePath`: relative, canonical, no `..` or `.` components, no empty
components, no NUL bytes or backslashes, bounded length. A location above the
root is not representable, so navigation cannot be asked to leave the bundle;
entries the container records outside the bundle — the payload directory,
sibling bundles, package-level metadata — are excluded by construction rather
than filtered after the fact, and entries whose recorded names fail the
safety rules have no location, are never listed, and are counted so their
existence is not concealed. Directories the container did not record are
implied from the entries beneath them, so the tree is complete whatever the
container omitted. Within a directory, entries are ordered deterministically
— directories first, then by name compared as Unicode scalars — so the same
package lists the same way on every device. The domain exposes no filesystem
object and no absolute path.

**Special entries, Accepted.** A symbolic link is listed as a link and
nothing more: its target is content, content is never read, and so a link is
never followed and can lead the explorer nowhere, inside the bundle or out of
it. An entry of a kind the reader does not model is listed as unsupported and
left alone. Neither is navigable, and neither is given a size, since the size
of a link is the length of a target the explorer does not know.

**Labels are descriptive, Accepted.** The explorer labels conventional
locations — the bundle information file, the declared executable, an embedded
provisioning profile, the code signature directory and its resource record,
the frameworks, plug-ins, and extensions directories — from name, location,
and kind alone, so they can be found among many resources. A label states
what a file at that location conventionally is. It is not evidence that the
file is well formed, that the application is signed, that any signature is
valid, or that the application is trusted or installable; the presence of a
code-signature directory is a filesystem observation and nothing else. This
holds the line of Section 13: the UI does not decide signature status, and
neither does a descriptive listing.

**Relation to later inspection.** Signature, profile, entitlement, and
executable inspection remain the subjects of feasibility research (Section 6)
and will need their own vocabulary and their own boundaries. The explorer
establishes where those objects are inside a bundle; establishing what they
contain or what they prove is not implied by it, and none of it may be
inferred from this decision.

## 10. Domain Layer

The domain layer holds ZynSign's rules and vocabulary. It is pure, deterministic,
and testable without a device, a simulator, a keychain, or a network. This is
**Accepted**. Domain concepts include:

- `IPA`, `ArchiveEntry`, `Bundle`, `ApplicationMetadata`
- `ApplicationRecord`, `ArtifactReference`, `ArtifactFingerprint`, and the
  duplicate policy over them
- `NestedCode` and its dependency ordering
- `CertificateMetadata`, `CertificateDistinguishedName`, `PublicKeyInfo`,
  `SignatureAlgorithm`, `CertificateFingerprint`, `CertificateValidity`,
  `CertificateTrustEvaluation`, `CertificateChain`, `Certificate` and
  `CertificateData` with explicit raw-bytes ownership boundary,
  `CodeSigningSuitability`, `SigningIdentity`, `SigningIdentityMetadata`,
  `SigningIdentityIdentifier`, `SigningKeyAvailability`,
  `SigningCapability`, `DigestAlgorithm`, `ProvisioningProfileInput`,
  `ProvisioningProfilePayload`, `ProvisioningProfileAuthenticityStatus`,
  `ProvisioningProfile`, `ProvisioningApplicationIdentifier`,
  `ProvisioningProfileEntitlements`, `ProvisioningProfileValue`,
  `ProvisioningProfileValidity`, and `ProvisioningProfileClassification`
- the CMS verification vocabulary: `CMSVerificationResult`,
  `CMSSignatureVerificationStatus`, `CMSSignerCertificateStatus`,
  `CMSSignerIdentifier`, `CMSDigestAlgorithm`, `CMSVerificationAlgorithm`,
  `CMSSignedAttributeObservation`, `CMSTrustEvaluationStatus`, the `CMSVerifier`
  and `CMSSignatureVerifier` ports, and `CMSFailure`; plus the certificate
  relationship vocabulary `ProvisioningProfileCertificateRelationship`,
  `CertificateMatchOutcome`, `LocalSigningIdentityRelationship`,
  `LocalSigningIdentityLookup`, and `CertificateRelationshipAnalyzer`
- `SigningConfiguration`, `PackagingPolicy`
- `ValidationResult`, `VerificationResult`, `Diagnostics`
- domain errors and their categories

The certificate and signing-identity foundation is **Accepted** for this
increment (Section 7). It establishes the distinction between certificate
metadata that can exist independently and signing identities that pair a
certificate with a private-key capability, without storing private-key bytes
in ordinary domain models.

Rules, **Accepted**:

- Domain types contain no platform objects: no key references, no certificates,
  no URLs or file handles handed over by a system service, no framework types.
- Domain algorithms — validation rules, metadata rules, bundle-identifier
  matching, entitlement compatibility, nested-code ordering, redaction,
  diagnostics construction — are executable in isolation and are the primary
  target of pure unit tests.
- Domain never performs I/O, keychain access, or cryptography itself. Where a
  rule needs a platform result, the result is passed in as a domain value.
- Domain distinguishes raw observed values from normalized or display values,
  and preserves provenance so that diagnostics can explain a decision.

## 11. Protocol Boundaries

A protocol exists here only when it marks a genuine seam. The table is
**Accepted** with respect to which boundaries exist; the *Feasibility* column is
carried forward from Section 6.

| Port | Boundary it marks | Declared in | Required for testing | iOS-specific | Feasibility |
| --- | --- | --- | --- | --- | --- |
| `ArchiveReader` | Untrusted container input, behind which parsing, limits, and content access live | Domain | Yes — substitutable with synthetic fixtures | Implementation is platform-dependent | **Reading implemented** for ZIP containers (Section 9) and reused, entry table only, by bundle inspection; extraction remains Unresolved |
| `PlistDecoder` | Parsing of untrusted structured data with typed diagnostics | Domain | Yes | No — not platform-specific in principle | Examined during the metadata increment: the platform property-list API is total and deterministic, so parsing lives inside the metadata reader in Domain, tested through its bytes. A separate port is introduced only if parsing becomes platform-bound or needs substitution |
| `CertificateParser` | Parsing of untrusted X.509 certificate data, with typed diagnostics, without trust evaluation | Domain | Yes — substitutable with synthetic DER fixtures | The reader is not Security-framework-specific. `SecCertificateCopyValues` is not available on iOS (**Verified**) | **Implemented** for metadata extraction by a bounded DER reader (Section 7); trust evaluation remains Requires feasibility research |
| `SigningCapability` | The single narrow abstraction where signing happens, returning signature bytes only, without exposing private-key material | Domain | Yes — stub capability keeps orchestration testable | Yes — key access is platform-bound, non-exportable keys expected | **Implemented** as protocol (Section 7); concrete Keychain implementation Requires feasibility research (items 2, 16) |
| `ProvisioningProfilePayloadDecoder` | CMS/container boundary that supplies decoded profile payload bytes without making metadata trusted | Domain | Yes — synthetic payload decoder | CMS handling is platform-constrained; no complete iOS CMS API is assumed | **Implemented and backed by a real verifier**: `CMSProvisioningProfilePayloadDecoder` supplies authenticated payloads from the CMS boundary, fails closed on rejected containers, and marks unevaluated ones `.notEvaluated` (Section 7) |
| `CMSVerifier` | Verification of one untrusted CMS container, returning staged evidence instead of a validity flag | Domain | Yes — substitutable with a stub verifier and synthetic containers | No platform object crosses it; the implementation is platform-bound | **Implemented** for SignedData by ZynSign's own bounded reader, because no CMS decoder exists on iOS (**Verified**); trust evaluation is not part of this port (Section 7) |
| `CMSSignatureVerifier` | The single narrow seam where one signature is checked against one certificate's public key | Domain | Yes — recording double keeps orchestration testable without a device | Yes — the concrete implementation uses Security key primitives and is compiled for iOS only | **Implemented** for RSA PKCS#1 v1.5 and ECDSA X9.62 over SHA-256 messages; unsupported combinations and missing mechanisms are reported, never skipped; on-device behaviour Requires experiment E4 |
| `ProvisioningProfileParser` | Interpretation of decoded provisioning-profile metadata as typed domain values | Domain | Yes — synthetic plist payloads | Property-list parsing is not platform-specific in principle | **Implemented** for the property-list payload; trust and authorization remain separate |
| `IdentityStore` | Resolution and presentation of available signing identities and their status, plus access to signing capability | Application | Yes — in-memory in tests | Yes — key access is platform-bound | **Protocol implemented** for this increment (Section 7); concrete Keychain store Requires feasibility research (items 2, 16); PKCS#12 import is separate capability |
| `SigningEngine` | The single place where code-signing blob assembly happens, and the only consumer of signing capability | Domain | Yes — a stub engine keeps orchestration testable | Yes | Requires feasibility research (items 1–7, 9, 10) |
| `SignatureVerifier` | Independent evaluation of an artifact, with no access to signing state | Domain | Yes | Yes — no system verifier may be assumed | Requires feasibility research (item 11) |
| `TemporaryStorage` | Controlled working space with lifetime, cleanup, and cancellation semantics | Application | Yes — in-memory or directory-backed | Partly — directories and lifecycle are platform-bound | Accepted as a boundary; mechanism Unresolved |
| `ApplicationRecordStore` | Persistence of non-sensitive library records: insert, update, fetch by identifier, list, delete | Application | Yes — in-memory in tests | No | **Implemented** as a versioned catalog file (Section 15) |
| `LibraryArtifactStore` | Ownership of the package bytes behind library records: describe a staged archive, adopt it into library storage, observe, remove, enumerate | Application | Yes — in-memory in tests | Partly — directories and moves are platform-bound | **Implemented** over application-owned storage (Section 15) |
| `DeviceInstaller` | Delivery of a signed artifact to a device | Application | Contingent | Yes | **Provisional** — may never exist (item 15); no implementation may be built against it before installation scope is decided |

Rules, **Accepted**:

- Ports return domain types and structured diagnostics; they do not leak
  implementation types to callers.
- Ports exist because the implementing layer is platform-bound, because the input
  is untrusted, or because tests must substitute behaviour. A protocol added for
  one of these reasons is not duplicated for superficial uniformity.
- No speculative ports. `DeviceInstaller` is retained in the table because
  installation is an identified, separately-scoped concern; it must not be
  implemented, stubbed into a workflow, or depended upon until installation scope
  is decided.

## 12. Application Layer

**Accepted**: the application layer owns workflow orchestration and is the only
place where stages are sequenced and composed.

- Use cases express user-visible operations (inspect a package, parse and
  structurally validate a decoded provisioning profile, verify a
  provisioning-profile container and report its staged evidence, produce a
  signed artifact, verify an artifact, prepare a package for export) in terms of
  domain logic and ports.
- Workflow state — progress, cancellation, per-stage outcome, recoverable versus
  terminal failure — is an application concern, not a UI concern and not a domain
  concern.
- Composition of concrete implementations happens here, and nowhere below.
- Privileged operations (key access, signing, installation) require explicit user
  intent and are invoked from the application layer, never as a side effect of
  inspection or of rendering.
- Long-running work is cancellable, and cancellation must run the same cleanup
  path as failure.

Detailed workflow sequencing is **Provisional** until the feasibility boundaries
that constrain it (Section 6) are closed.

## 13. UI Layer

The separation between presentation, application, and domain is retained and is
**Accepted**. The UI must not:

- parse or extract archives, or decompress untrusted content;
- read, modify, or construct Mach-O binaries;
- access private keys, key references, or raw certificate or profile bytes;
- call encryption, signing, or signature-construction APIs;
- communicate with devices or perform installation;
- evaluate provisioning-profile compatibility or entitlement rules;
- decide validity, signature status, or installability on its own.

The UI communicates through application-level use cases and state, and renders
outcomes, diagnostics, and identity status that those use cases produce. Detailed
screen design, navigation structure, and view-level architecture are out of scope
for this document.

## 14. Security Architecture

Security is a cross-cutting architectural concern, not a stage and not a layer.
The concerns below are **Accepted** as in scope for the architecture; the
mechanisms that address them are subject to the feasibility boundaries in
Section 6.

| Concern | Architectural position |
| --- | --- |
| Untrusted IPA input | Every stage that reads input treats it as hostile; inspection is designed to run with no privileged capability available. |
| Malicious archive structures | Path, link, duplicate-entry, and resource-exhaustion defences are enforced at the archive boundary, with limits that are policy rather than implementation trivia. |
| Malformed binary and structured data | Parsers fail closed, report structured diagnostics, and never fall back to a permissive interpretation. |
| Private-key protection | Key material is confined to the signing boundary, with no export, no logging, and no persistence outside the platform mechanism chosen after research. |
| Key access control | Access is scoped, requires explicit user intent, and is subject to whatever per-use authorization the platform offers. |
| Certificate and profile data | Treated as sensitive: parsed only as needed, displayed only as metadata, and redacted from diagnostics; raw profile payloads are not persisted by ZS-017. |
| Temporary files | Application-owned, restrictively used, and removed on success, failure, and cancellation. |
| Signed artifacts | Written to controlled locations, validated before being offered to the user, and not retained beyond their purpose without an explicit retention decision. |
| Logs and diagnostics | Redaction is a domain rule with tests; keys, credentials, profile bodies, device identifiers, and personal paths must not appear in output. |
| Crash cleanup | A crash must not leave secrets or partially written artifacts behind; recovery behaviour is defined rather than incidental. |
| Concurrent signing sessions | Concurrent privileged operations are constrained explicitly to avoid key-use races, temporary-space collisions, and confused progress reporting. |
| Data retention | Each category of data has a defined lifetime; retention longer than the operation requires must be a deliberate decision. |
| User-selected external files | Access is limited to what the user granted, for as long as it is granted, and nothing else in the container becomes reachable as a consequence. |
| Sandbox boundaries | ZynSign assumes it is confined and does not attempt to extend its reach, whether through private APIs, entitlements it cannot justify, or file tricks. |

**Accepted qualification:** architectural boundaries reduce accidental exposure.
They do not constitute a complete security boundary. Opaque types, access
control inside the process, and disciplined layering are engineering hygiene; the
enforceable guarantees come from the operating system, its sandbox, its key
storage and access-control mechanisms, and correct use of the APIs it provides.
No claim of security properties may rest on a type wrapper alone.

## 15. Persistence

The architecture requires that persistent data be classified:

| Class | Examples | Treatment |
| --- | --- | --- |
| Suitable for ordinary persistence | Application preferences, non-sensitive library records, display metadata, user-created labels and settings | Ordinary application storage; no special handling beyond correctness |
| Sensitive, requires special treatment | Private keys and any raw key material, signing credentials, raw certificate bodies, profile data where it is sensitive, device authentication or pairing material, temporary signing state | Not stored in ordinary application storage; storage mechanism, protection, and lifetime are decided by the research on Section 6 items 2, 3 and 16, and documented under `docs/security/` before implementation |

**Accepted:** persistence is never used as a shortcut for convenience with
sensitive material. If a value is classified sensitive, it belongs to the
mechanism chosen for secrets or it does not persist at all.

### Library Records Decision

The persistence increment settles the first class of the table — library
records — for the document-import path. The sensitive class remains
untouched: nothing in this decision stores, references, or provides a place
for key material, credentials, certificate bodies, or profile data, and the
record type has no field that could carry them.

**Record model, Accepted.** `ApplicationRecord` is a domain value type with
no framework, filesystem, archive, or storage dependency. It carries a stable
record identifier (distinct from the artifact identifier, so a record can
outlive a replacement of its bytes), the identity the package declared
(bundle identifier, declared names, marketing and build versions, preserved
exactly as declared and untrusted), the declared executable name, the
selected file's name as a provenance label, an `ArtifactReference` (artifact
identifier, byte count, and content fingerprint), an inspection summary (the
classification and the codes of any non-rejecting findings; finding details
are diagnostics and are not persisted), and import and last-updated
timestamps. A record can only be created from an artifact that passed
inspection; the constructor enforces it. The fingerprint is a SHA-256 digest
over the artifact's bytes and identifies bytes only: it is not a signature
and is never presented as evidence that a package is genuine, trusted, or
installable. Persistence of a record is not a trust statement about the
package.

**Storage mechanism, Accepted for this increment.** Records are kept in one
JSON catalog document, `Application Support/ZynSignLibrary/catalog.json`,
encoded with Foundation's `Codable` and replaced atomically on every change.
The document declares an explicit `schemaVersion`, currently `1`, and holds a
flat array of stored records whose every value is re-validated through the
domain's own rules when read. The reasons this was chosen over a database
framework: the record set is a small collection of flat values with no
relationships and no query pattern beyond "list" and "by identifier"; the
deployment target is still Unresolved (Section 6, item 17), and a catalog
file binds the application to nothing beyond Foundation; the schema version is
explicit and inspectable rather than implied by a model file; the store is
testable against a temporary directory with no container or context; and a
whole-file rewrite is proportionate to the volume a library of packages
reaches. The choice is confined behind `ApplicationRecordStore` and made in
the composition root; a database-backed store, should query or volume
requirements appear, replaces one platform type and one line of wiring.
Application Support was chosen because the system does not purge it, it is
private to the application container, and it is covered by the container's
default file protection.

**Artifact ownership, Accepted.** The bytes behind a record are owned by the
library, never by an external document provider. On admission the staged
archive is moved — a rename within the container — into
`Application Support/ZynSignLibrary/Artifacts/<artifact identifier>.ipa`, and
from then on the record's artifact reference is the only way the bytes are
reached; no provider URL, bookmark, or security-scoped grant is retained. A
record whose artifact is absent, or whose file size no longer matches the
recorded byte count, is listed with availability `missing` or
`inconsistent`, with its metadata intact for diagnosis; it is never repaired,
recreated, or reported as available, and the archive boundary refuses to open
what is not there. Removing an entry deletes the record first and the
artifact second. Replacing an artifact behind an existing record is not an
operation this increment provides: a later import of different bytes is a new
record, and a later import of identical bytes while the earlier artifact is
missing is likewise a new record with its own artifact, related to the stale
one, which stays until removed. Artifacts in library storage that no record
refers to — orphans — are detected on request and removed only on request.

**Duplicate and identity policy, Accepted.** The policy is a pure domain
function and is deterministic. A candidate whose fingerprint and byte count
match the artifact of a record whose artifact is currently held is the same
package, whatever its metadata declares, and is not recorded again; the
existing record is reported. A candidate whose bytes differ is a distinct
artifact and is recorded even when its bundle identifier, marketing version,
and build match an existing record: a rebuilt package is a different
package, and the relation — other versions of the same bundle, or the same
declared version with different content — is reported so the outcome can be
explained, never used to replace or suppress a record.

**Failure and cleanup, Accepted.** Admission is artifact first, record
second, so a record is never written for bytes the library does not hold. If
the record cannot be written after the artifact was adopted, the artifact is
removed again; if that removal fails, or the process ends between the two
steps, the artifact is an orphan, detectable as above. The two stores are
independent and no transactional guarantee across them is claimed. The
catalog itself is written atomically, so an interrupted write cannot leave a
truncated catalog; a failed write leaves the previously stored records, on
disk and in memory, as they were. A catalog that cannot be decoded, carries a
value the domain rejects, or declares a schema version this build does not
know fails closed: every operation reports a typed error, the file is left in
place for diagnosis, and it is never reset, truncated, or partially loaded. A
catalog newer than the build is reported as unsupported, not as damage.

**Migration, Accepted as a rule.** The schema version is read before the
record shape is assumed. When the schema changes, the version is incremented
and a conversion from each earlier version is added at the read boundary; no
conversion exists yet because no earlier version exists. No field is stored
in anticipation of a future need.

**Still Unresolved:** whether library storage should be excluded from device
backups, eviction or retention limits under storage pressure, repair or
replacement of a missing artifact as a user-facing operation, and deeper
library management (the Applications screen lists, imports, and deletes
records; no repair or replacement operation exists in this build).

## 16. Testing Architecture

The testing strategy is **Accepted** as a structure. Individual tests are only
claimed to be possible once the capability they exercise has been verified — a
test that cannot run is not evidence, and a passing test on the wrong platform
proves nothing about the product.

| Tier | Scope | Runs on | Covers |
| --- | --- | --- | --- |
| Pure unit tests | Deterministic logic with synthetic fixtures, no I/O | Host | Validation rules, metadata rules, bundle-identifier matching, entitlement compatibility logic, nested-code ordering, error construction, redaction, deterministic algorithms, diagnostics |
| Simulator tests | Application-layer workflows against simulated platform services | iOS/iPadOS simulator | Workflow state, cancellation, persistence behaviour, lifecycle handling, archive handling that does not require physical-device capabilities |
| Physical-device tests | Behaviour that depends on hardware, real key storage, or real platform policy | iPhone/iPad | Key storage and access control, hardware and security behaviour, device-specific APIs, actual signing feasibility, installation behaviour, sandbox and document-provider behaviour |
| Developer-side validation | Independent artifact inspection and fixture production | macOS / Xcode, outside the product runtime | Generating controlled signed fixtures, inspecting produced artifacts with platform tooling, compatibility experiments during feasibility research |

Rules, **Accepted**:

- **Pure tests carry the most weight, and are the only tier with no platform
  dependency.** Most correctness of ZynSign — validation, ordering, matching,
  redaction, diagnostics — is designed to be provable there.
- **Simulator results are not device results.** Simulated key storage, absence of
  hardware security, and differing document-picker behaviour mean a simulator
  pass says nothing about the corresponding device behaviour.
- **Physical-device tests are gated on feasibility.** A capability listed in
  Section 6 cannot have a passing test written for it until the underlying
  question is answered; writing the test first would convert an unverified
  assumption into apparent evidence.
- **Fixtures are synthetic and controlled.** No real signing material,
  credentials, profiles, or personal identifiers appear in tests or fixtures, in
  line with `SECURITY.md`. The CMS fixtures are SignedData messages assembled
  from test-only keys and certificates generated for this repository with
  OpenSSL, cross-checked with `openssl cms -verify`, and committed as public
  bytes only; the private keys existed solely to produce them and are not
  committed. Signature mathematics over those bytes runs only in the iOS-gated
  suite, because the primitives it uses do not exist elsewhere.
- **Developer-side validation is infrastructure, not product evidence.** Using
  macOS tooling to confirm that a produced artifact matches expectations is
  legitimate and useful; using it as a runtime path, citing it as proof that an
  on-device capability exists, or presenting a desktop-only test as a product
  test, is not.

## 17. Errors and Diagnostics

**Accepted:**

- Failures are typed and categorized rather than reduced to strings. Categories
  distinguish, at minimum: structurally invalid input, unsupported input,
  ambiguous input, capability unavailable on this platform, user-cancelled,
  storage or resource failure, and internal failure.
- "Unsupported" and "unavailable" are reported honestly. A capability that cannot
  be provided because the platform does not expose it must not be reported as a
  defect in the user's input.
- Each failure carries a user-facing explanation and, separately, diagnostic
  detail. Diagnostic detail is subject to the redaction rules of Section 14.
- Ambiguity is never resolved silently: where inspection cannot choose one
  interpretation, the outcome is an ambiguity report, and the affected content is
  not carried into signing.
- A boundary's failure vocabulary stays its own. `CMSFailure` describes container
  and signature outcomes, `ProvisioningProfileFailure` describes profile metadata
  outcomes, and `SigningIdentityFailure` describes identity outcomes; a payload
  that is not a property list is a profile failure even though CMS verification
  succeeded, and a container that cannot be decoded never reaches the profile
  vocabulary.
- Evidence and errors are separated deliberately. Structural refusals throw;
  a container that decoded and did not verify is returned as evidence, because
  "this signature does not verify", "no conclusion was reached", and "this
  input is not a CMS message" are three different facts a caller must be able to
  tell apart.

## 18. Architecture Decisions

Decisions retained from earlier analysis keep their status; decisions that
depend on iOS/iPadOS behaviour are recorded as *Provisional*, *Unresolved*, or
*Requires feasibility research* until the corresponding question is answered.

| # | Decision | Status |
| --- | --- | --- |
| 1 | iOS/iPadOS deployment target | **Unresolved** — product decision with architectural consequences (Section 6, item 17) |
| 2 | On-device signing feasibility | **Requires feasibility research** — items 1–7, 9, 10, 11 |
| 3 | Private-key storage and access | **Requires feasibility research** — items 2, 16 |
| 4 | Certificate handling | **Requires feasibility research** — item 3 |
| 5 | Provisioning-profile parsing and CMS verification | **Accepted for decoded-payload parsing in ZS-017 and for container signature verification in ZS-018; Requires feasibility research for signer-certificate trust and for authorization** — item 8 |
| 6 | Mach-O and code-signature handling | **Requires feasibility research** — items 5, 6 |
| 7 | Signature verification | **Requires feasibility research** — item 11 |
| 8 | IPA packaging | **Provisional** — ZynSign is responsible for producing its own package; format rules depend on item 12 and the deployment target |
| 9 | Installation mechanism | **Unresolved** — no known public application-facing mechanism (item 15); may be excluded from the first release |
| 10 | Persistence of library records | **Accepted** for this increment — value-typed `ApplicationRecord`, a versioned JSON catalog behind `ApplicationRecordStore`, library-owned artifact storage behind `LibraryArtifactStore`, content-based duplicate policy, artifact-first admission with cleanup on failure (Section 15); backup and retention treatment Unresolved |
| 11 | Archive implementation | **Accepted for reading** — ZIP container reading is implemented behind `ArchiveReader`, with no third-party dependency; **Unresolved for writing** (Section 9) |
| 12 | Nested-code rules | **Provisional** — innermost-first ordering is the intended direction; the complete location and exception set requires research (item 10) |
| 13 | Security and retention policy | **Provisional** — the prohibitions on key material in UI, logs, diagnostics, and ordinary persistence are **Accepted**; retention durations are Unresolved |
| 14 | Testing strategy | **Accepted** as a four-tier structure with feasibility gating (Section 16) |
| 15 | Developer-side validation tooling | **Accepted** — permitted for fixtures and independent validation, excluded from the runtime (Section 2) |
| 16 | Runtime platform is iOS/iPadOS | **Accepted** (Section 1) |
| 17 | Layer model and dependency direction | **Accepted** (Section 4) |
| 18 | Domain purity and no platform objects in Domain | **Accepted** (Sections 4, 10) |
| 19 | Signing does not imply installation | **Accepted** (Section 5) |
| 20 | Imported input is untrusted | **Accepted** (Sections 9, 14) |
| 21 | Private key material never reaches UI, logs, diagnostics, ordinary persistence, or Domain | **Accepted** (Sections 7, 14) |
| 22 | UI/application/domain separation and the UI prohibition list | **Accepted** (Section 13) |
| 23 | Ports declared by their consuming layer | **Accepted** (Sections 4, 11) |
| 24 | Installation in the first release | **Unresolved** |
| 25 | Import intake and temporary staging | **Accepted** for the document-import path — one bounded-chunk staging per import, identifier-addressed application-owned temporary storage, security-scoped access held only while copying, staged archives adopted by the library or discarded before the import returns (Section 8) |
| 26 | Persistence is not trust | **Accepted** — a library record states that a package passed inspection when imported and which bytes it refers to; the fingerprint identifies bytes only, declared metadata stays untrusted, and no record is evidence that a package is signed, genuine, or installable (Section 15) |
| 27 | Bundle inspection is read-only and descriptive | **Accepted** — the explorer derives a bundle's structure from the container's entry table through the existing `ArchiveReader` and library storage, with no extraction, content reading, hashing, or parsing; locations are bundle-relative `BundlePath` values that cannot name anything above the root; links and unsupported entries are listed, never followed; labels on conventional locations describe and do not establish signing, trust, or installability (Section 9) |
| 28 | Certificate and signing identity foundation | **Accepted** for this increment — platform-independent `CertificateMetadata`, `CertificateDistinguishedName`, `PublicKeyInfo`, `SignatureAlgorithm`, `CertificateFingerprint`, `CertificateValidity` that distinguishes parsing success from currently valid, `CertificateChain` leaf-first without trust evaluation, `CodeSigningSuitability` with explicit checks and unsuitability reasons, `SigningCapability` narrow protocol that returns signatures without exposing private-key bytes, `SigningIdentity` distinct from certificate with `SigningIdentityIdentifier` and `SigningKeyAvailability`, `IdentityStore` protocol in Application, `CertificateParser` port in Domain with `AppleCertificateParser` in Platform using a bounded DER reader because `SecCertificateCopyValues` is not available on iOS (**Verified**), PKCS#12 treated as separate capability not implemented, trust validation boundary not implemented and represented as `notEvaluated`, raw certificate bytes ownership boundary owned by Platform and not persisted in ordinary storage, no certificate-management UI, no signing engine, no private keys stored in application database (Section 7) |

| 29 | Provisioning-profile CMS verification | **Accepted** for this increment — SignedData is read by ZynSign's own bounded structure reader because `CMSDecoderCreate`, `CMSDecoderCopySignerStatus`, and `CMSSignerStatus` are documented for macOS/Mac Catalyst only and not for iOS (**Verified**); signatures are checked through the `CMSSignatureVerifier` port using `SecCertificateCopyKey` and `SecKeyVerifySignature` with hashing left inside the platform primitive; signed attributes are re-encoded as a `SET OF` and bound to the payload through the message-digest attribute before any signature check; the signer certificate is selected by serial and compared by SHA-256 fingerprint, never by name, label, or bag order; five states stay separate with trust `notPerformed` and authorization `notEvaluated`; payloads are parsed only after verification; identity stores are read-only and never asked for a signing capability; CMS construction, trust evaluation, signing policy, compatibility decisions, persistence, and profile interfaces remain out of scope (Section 7) |

## 19. Non-Goals of This Document

This document deliberately does not:

- contain or describe production code, project files, dependencies, or tests;
- select concrete signing algorithms, code-directory versions, or entitlement
  derivations before feasibility research;
- select an archive library or a certificate-handling dependency;
- specify UI design, navigation, or screen structure;
- design installation, or commit to installation being in any release;
- introduce abstractions that no identified boundary requires.

## 20. Related Documents

- [phase-0-discovery.md](phase-0-discovery.md) — findings, format notes, and
  research input that informs Sections 6 and 9 of this document.
- [README.md](README.md) — conventions for architecture documentation.
- [`SECURITY.md`](../../SECURITY.md) and [`docs/security/`](../security/) —
  handling of sensitive material, which Sections 7, 14, and 15 rely on.
- [`docs/testing/`](../testing/) — testing practice, of which Section 16 is the
  architectural part.
