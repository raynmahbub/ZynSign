# ZynSign Architecture

## Status

This document defines the architecture of ZynSign: the platform it runs on, the
layers and boundaries the application is organised into, the decisions that are
settled, and the capabilities that are not yet established.

A sequence of implementation increments exists. The first is an Xcode application
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
The policy increment then adds the read-only decision over that evidence, and the
integration increment sequences the three — container verification, parsing and
structural validation, and policy — into one application-layer use case that takes
a profile and an application, identity, and configuration context and returns one
staged result. The integrated path can also receive the profile a bundle embeds:
a read-only intake reads that one entry through the existing archive boundary and
hands its bytes to the pipeline. The integration performs no trust evaluation, no
authorization, no signing, no persistence, and adds no profile-management,
entitlement, or installation interface; the bundle explorer still reads no entry
content, and nothing here is wired into the interface.
The signing-cryptographic-foundation increment then adds the generic
cryptographic primitives the signing stage will build on: a digest value and
digest boundary over CryptoKit's hashing primitives, a focused signing request
with explicit message-or-digest semantics, a pure signing engine that signs
through the ZS-016 capability, a structured signing result, a verification
boundary whose outcome distinguishes verified, does-not-verify,
not-performable, and no-conclusion, and a structured crypto failure
vocabulary. It is reachable from the application layer only, through a
use case that is not installed in the application environment, and a
successful operation means only that the generic cryptographic operation
completed — nothing about Apple code signing, trust, or installability
(Section 7, Cryptographic Signing and Verification Foundation).
The Mach-O inspection increment now adds a read-only byte parser for thin and
universal images, load commands, embedded signature SuperBlobs, indexed slots,
and versioned CodeDirectory metadata. It is reachable through an opt-in
application use case, not the bundle explorer or signing engine. Its explicit
bounds and unsupported-version results describe format structure only; they
are not verification, construction, policy, or an on-device acceptance claim.
See [Mach-O code-signature inspection](macho-inspection.md) for the evidence,
limits, and remaining questions.
The SuperBlob construction increment adds a separate typed container for
ZS-023 CodeDirectory bytes and validated opaque frames, with canonical ordering
and checked packed serialization. It reuses the inspection parser through a
standalone entry point, without inserting bytes into an executable or invoking
cryptographic signing. See [SuperBlob construction](superblob-construction.md)
for the ZS-024 format contract, opaque boundary, and remaining validation work.
The Mach-O code-signature region construction increment establishes the domain
and infrastructure to frame a serialized SuperBlob into a 16-byte-aligned
region, compute layout arithmetic, gate load-command capacity, reject existing
signatures by default, leave replacement and universal binary mutation explicitly
unsupported, and append the region through a narrow writer that preserves all
unrelated bytes. It does not invoke private keys, generate CMS, or claim platform
acceptance. See [macho-signature-region.md](macho-signature-region.md).
The signing-metadata increment adds the entitlement, requirements, and
resource-sealing layer the signing pipeline consumes: a typed entitlement model
over the existing property-list value tree whose unknown keys stay representable,
with one deterministic canonical serialization and an explicit separation of
decoded, structurally valid, provisioning-compatible, embedded, and
platform-authorized states; a requirements model that carries set framing and
expression bytes exactly, dispositions every state, refuses malformed values at
the embedding boundary, and interprets no expression language; a read-only
resource store boundary with deterministic ordering, explicit symlink policy,
bounds, and caller-supplied nested-code seals, producing the CodeResources
document over the `files2`/`rules2` subset with the v1 dictionaries an explicit
unsupported subset; and the derivation of CodeDirectory special slots 2, 3, and
5 under the ordering constraint that metadata bytes are serialized, digested,
and finalized into slots before the CodeDirectory is constructed, hashed, and
signed. Single-image and nested signing consume the layer through per-target
metadata that is never inherited, and verification holds a signed artifact to
the exact prepared metadata bytes. See [signing-metadata.md](signing-metadata.md).
The inspection stage is therefore a partial capability: it reads containers,
classifies layout, reads one bundle's declared metadata, describes a bundle's
structure, and can separately inspect a caller-supplied decoded profile payload
or caller-supplied Mach-O bytes. ZS-023 adds a separate, domain-level
CodeDirectory construction boundary with independent code-page hash vectors
and deterministic serialization coverage for a conservative version subset; it does not
embed the result into Mach-O or claim platform acceptance. See
[codedirectory-construction.md](codedirectory-construction.md).
Accepted imports are recorded and kept across launches and are listed, imported,
browsed, and removed in the Applications area; certificate and profile parsing
and identity modeling exist as domain foundation; provisioning-profile CMS
verification reports signature authenticity separately from trust and
authorization and is reachable from the application layer only, not from any
interface, and the integrated provisioning-profile pipeline — whose `valid` status
means only that every stage ZynSign implements reached its positive outcome — is
likewise reachable from the application layer only. The application-signing
workflow now exists at the same level: a nine-stage pipeline — integrity,
profile, discovery, extraction, nested signing, resource sealing,
main-executable signing, packaging, and independent verification — composes
the archive, provisioning, signing, packaging, and verification machinery
into the single order a signed container requires, with deterministic
packaging through a validated entry set and a stored-only ZIP writer, safe
extraction with confinement and an explicit link policy, and a pure
installation-capability assessment that reports installation as unavailable
with exact limitations. The pipeline is constructed at the composition root
and covered by unit tests, but it is not installed in the application
environment: no signing interface is composed until device validation
completes, no installation mechanism exists anywhere in the product, and no
suite in the increment was executed in the review environment. See
[application-signing-pipeline.md](application-signing-pipeline.md). The suites
have since passed on hosted CI, on a simulator. The external validation
increment then measured the signing output with Apple's developer tooling for
the first time: `codesign` accepts ZynSign's single-image signatures, rejects
the pipeline's bundles because it does not recognize the resource seal, and the
signature format fails Apple's documented iOS 15+ requirements. That is
developer-side evidence, not platform acceptance; see
[external-validation.md](external-validation.md).

Nothing else in this document is a claim that any behaviour works. Every
feasibility boundary in Section 6 remains open except where noted here, and
the installation stage is documentation of intended structure only: signing,
verification, and packaging are implemented below the interface, and
installation does not exist at all.

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
| 6 | Code-signature blob embedding | Constructing and replacing the signature region of a Mach-O binary, including load-command layout, segment offset and alignment rules, and fat/universal binaries. Read-only parsing of thin/fat headers, `LC_CODE_SIGNATURE`, SuperBlobs, and CodeDirectory fields exists ([Mach-O inspection](macho-inspection.md)); it does not close the embedding/construction feasibility boundary or establish device acceptance. |
| 7 | Entitlement handling | Building entitlement blobs, the relationship between profile-derived entitlements and binary entitlements, and which entitlement data forms the platform expects. |
| 8 | Provisioning-profile interpretation | The profile is signed structured data; parsing it is distinct from validating the container signature, and both are required before a profile can be trusted for authorization decisions. Parsing and container signature verification are implemented and kept as separate states, and ZynSign's own policy rules for using an authenticated profile with an application, an identity, and a requested configuration are implemented as predicates over that evidence (Sections 7 and 12); signer-certificate **trust**, revocation, Apple issuance, and platform authorization — whether the platform will accept a configuration that satisfies those predicates — remain open and are not claimed. |
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

### Provisioning Profile Policy Validation

**Accepted for ZS-019 — a read-only policy stage.** The stage answers one
question: can this authenticated provisioning profile be used with this
application, this signing identity, and this requested signing configuration,
under the policy rules ZynSign implements? It answers with a structured result
and nothing else: it does not sign, modify a profile, rewrite an entitlement,
edit an `Info.plist`, change a bundle identifier, touch a Keychain item, install
anything, or persist its result. `ProvisioningPolicyValidationContext` is a pure
domain value assembled from evidence that already exists — a parsed profile with
its staged authenticity, the certificate relationship from ZS-018, application
metadata and the bundle identifier being signed, optional identity metadata, the
requested signing configuration, the device and platform context, and an
injectable `EvaluationClock`. No interface state can enter it, no key material
can be carried by it, and no identity-store call happens inside the validator.

**Observed — categories and three-state findings.** `ProvisioningPolicyValidator`
evaluates nine categories in a fixed order: authenticity, validity, profile
class, bundle identifier, team identifier, certificate, entitlements, platform,
and device. Each category is `satisfied`, `violated`, or `indeterminate`, and
the result carries every meaningful finding rather than stopping at the first
failure; a category with no finding at all is indeterminate, never satisfied.
`indeterminate` means no rule could be applied — it is neither a pass nor a
violation. The overall outcome is `compatible` only when every category is
satisfied, `incompatible` when any category is violated, and `indeterminate`
otherwise. Authenticity gates every other category: no policy rule speaks about
a payload that is not authenticated, so those categories stay indeterminate, and
a rejected container is the one authenticity violation that makes the result
incompatible.

**Accepted — identifier matching is modelled once.**
`ProvisioningIdentifierCompatibility` is the single rule for the profile's
application identifier, and both the bundle-identifier check and the
`application-identifier` claim check ask it, so the two cannot drift apart.
Exact scope is component equality. A trailing wildcard is a prefix test at a
component boundary: `TEAM123456.com.example.*` covers the bundle identifier
`com.example.app`, and `TEAM123456.*` covers every bundle identifier, while
`com.example.*` never covers `com.exampleOther.app` (**Inferred** from the App ID
form Apple documents; not measured against the platform). A full
`application-identifier` claim is compared as text plus the same scope
*including* the application-identifier prefix, and is never re-parsed, so a
claim cannot widen the scope by carrying a wildcard of its own. When the
profile's value has no explicit application-identifier prefix, only text
equality is decisive and every other comparison is indeterminate: ZynSign does
not split an identifier at a boundary the profile does not state. An
unrecognised or disagreeing profile value is never normalised into a match.

**Accepted — team identity comes from structured evidence only.** The profile
side of the team comparison is the set of team identifiers the profile declares,
including the `com.apple.developer.team-identifier` claim when present. The
identity side uses only certificate subject organizational-unit values that
carry the exact structure of a team identifier (ten upper-case ASCII
alphanumerics); display names, common names, labels, and issuer text are never
read as team evidence. When no structured candidate exists the comparison is
indeterminate — "the identity's team could not be established" is a different
fact from "the identity's team is wrong" — and a missing structured claim on the
requested side cannot turn an unknown into a success.

**Accepted — certificate evidence is layered, not re-derived.** The certificate
category consumes the ZS-018 relationship instead of re-reading any container.
It reports separately whether the profile names certificate references, whether
the profile's own fingerprint set was available for comparison, whether the
container's signer is one of the profile's certificates, whether the signing
identity's certificate is one of them, and whether the identity's key is
reported available, associated, and ready. A signer outside the profile's
certificate set is recorded as indeterminate — authenticity remains the CMS
boundary's finding — and an unavailable key is an open question about the
identity, never a malformed profile and never a certificate mismatch. "Identity
unavailable", "certificate mismatch", and "profile mismatch" stay three distinct
outcomes, and the validator never requests a signing capability, so no signature
is produced to prove key possession.

**Accepted — validity and platform reuse existing models.** Validity is decided
by the existing `ProvisioningProfileValidity` states against the injected clock,
with inclusive boundaries; an expired or not-yet-valid profile and a malformed
date interval are violations, while missing dates remain indeterminate because
absence is not misordering. Platform comparison uses the existing
`ProvisioningProfilePlatform` values and either the platforms the caller states
explicitly or the application's declared device families mapped to platform
spellings (**Inferred**; the family values are documented, the mapping to
profile platform strings is ZynSign's). An unrecognised platform spelling in the
profile makes the comparison indeterminate rather than a mismatch, and nothing
here claims platform support on Apple's behalf.

**Accepted — device constraints are never fabricated.** ZynSign does not read a
device identifier on this path and does not assume that the running device is
authorized because the profile lists devices. A device comparison happens only
when a trustworthy identifier was supplied by the caller; otherwise the category
is indeterminate and the question is deferred to installation-time evidence. A
profile that both declares that it provisions all devices and carries a device
list is reported as inconsistent rather than resolved in either direction, and a
profile that provisions all devices or carries no device list is reported as
having no device comparison to make — not as a grant.

**Accepted — entitlement comparison is typed, deterministic, and not a policy
table.** Requested claims are compared against the profile's `Entitlements`
allowlist per key, in key order, with property-list types preserved. Every
requested claim must appear in the allowlist (**Verified** — TN3125), while the
allowlist may carry claims the request does not make. Values are compared under
established rules: identical strings, booleans, integers, reals, sequences, and
string-keyed dictionaries match; a differing value of the same form is a
conflict; an integer and a real are not coerced into each other; a requested
value the allowlist does not carry is a conflict; data, dates, and structures
whose significance is not established are reported as unsupported or
incomparable instead of being approved. Array order and multiplicity are not
assumed to be interchangeable, so an element-wise subset is an open question
rather than a pass, and nested dictionaries are compared for the keys the
request actually claims. `get-task-allow` has its own rule: absence is not
`false`, a request for `true` where the profile carries no claim is a violation,
a request for `false` where the profile authorizes `true` is an open question
because the record does not establish whether a disclaimed value must appear
literally, and a contradiction between the typed preference and the claim set is
reported rather than resolved. Three keys — `application-identifier`,
`com.apple.developer.team-identifier`, and `get-task-allow` — are decided by
their dedicated rules and never by the generic ones. Nothing here strips,
rewrites, or synthesizes an entitlement, and nothing here claims that a claim
appearing in the allowlist will be enforced or accepted by the platform.

**Accepted — application composition and presentation.**
`ValidateProvisioningConfigurationUseCase` orchestrates the stage: it takes the
staged verification result, the application's metadata, the identifier being
signed, an optional identity identifier, the requested configuration, and the
device and platform context; it resolves identity metadata read-only through
`IdentityStore`; and it returns a `ProvisioningPolicyValidationResult`. It never
throws for a policy outcome, because a profile that is not authenticated is a
result and not an error in the caller's request. No signing capability is
requested, no key handle is resolved, and nothing is persisted. A `summary`
renders the result for presentation — overall state, category states, trust and
authorization states, and one already-redacted sentence per non-satisfied
category — and carries no identifiers, fingerprints, values, or bytes. There is
no policy interface in this increment and no Sign, Re-sign, Install, or Generate
Profile control.

**Trust boundary, Accepted.** A `compatible` result means one thing: the
configuration satisfies the policy rules implemented by ZynSign. It is not
platform authorization, not an installation result, not a signature, and not
Apple's approval. `trustEvaluation` remains `notPerformed` and `authorization`
remains `notEvaluated` on this path, and the result deliberately exposes no
`isValid`, `isInstallable`, or `isTrusted` flag that would collapse the
distinction. Diagnostics carry states and codes only — no identifiers, values,
fingerprints, bytes, or credentials.

**Deferred, recorded.** Whether the platform's wildcard, entitlement,
device-provisioning, and profile-class rules match the predicates implemented
here remains Unknown; the predicates are stated where they live instead of being
presented as Apple policy. Device authorization needs installation-time
evidence. Whether a trustworthy device identifier can be obtained at all, and
which entitlements the platform will enforce, remain open questions in
`on-device-signing-feasibility.md`. A policy result is derived from the profile,
the application, the identity, the configuration, and the current time, so it is
never persisted and any caller that retains one defines its own invalidation.
Performance work is deferred deliberately: a context is evaluated once per
request, the profile and the certificate relationship are read rather than
re-parsed, and no caching is introduced before it can be measured.

**Evidence status.** The category model, the three-state findings, the
identifier rule, the team-identifier rule, the certificate separations, the
entitlement rules, the redaction rules, and the application composition are
**Observed** from this repository's implementation. Allowlist inclusion is
**Verified** (TN3125). Wildcard scope and the mapping from declared device
families to platform spellings are **Inferred**. Numeric non-coercion and the
caution around array order are policy choices this repository makes, not
platform statements. Platform acceptance, entitlement enforcement, device
authorization, and Apple's own profile-class rules remain **Unknown or Requires
experiment**; no iOS build, device, or simulator was available in the
environment where this stage was written, and its suite was not executed there.

### Provisioning Profile Pipeline Integration

**Accepted for ZS-020 — integration composes, it does not re-implement.** The
pipeline is `ValidateProvisioningProfileUseCase`, and it owns no validation rule.
It sequences the stages that already exist — ZS-018's container verification and
certificate relationship, ZS-017's parser and structural validator, and ZS-019's
policy validator behind `ValidateProvisioningConfigurationUseCase` — and its own
code consists of running them in order, reading what each reported, and
aggregating. Nothing from ZS-017, ZS-018, or ZS-019 was copied or replaced: bundle
identifiers, wildcards, entitlement values, certificates, expiries, and team
identifiers are still decided only where they were decided before, so each stage
stays independently testable and the pipeline cannot become a second, subtly
different validator. It adds no port, because it introduces no new seam: every
input it needs already arrives through one that Section 11 declares.

**Observed — the stage order is the security order.** A run is

    profile input → CMS verification → authenticated payload → profile parsing
        → structural validation → signer certificate → certificate relationship
        → policy validation → integrated result

and the ordering is not configurable here. Parsing a payload before verifying the
container is not a step this pipeline can request: the container boundary it calls
parses only what its signature verified, so unauthenticated profile metadata is
never produced, never handed to a policy rule, and never reported as a fact about
an application. Where a stage cannot run, the run records `notAttempted` or
`indeterminate` rather than filling the gap, and a container that decoded but did
not verify still yields staged evidence, because "rejected", "not evaluated", and
"not a CMS message" are three different facts.

**Accepted — one result per run, with every stage kept separate.**
`ProvisioningProfilePipelineResult` carries what was given (origin and acquisition,
as `ProvisioningProfilePipelineInputState`), an outcome per
`ProvisioningProfilePipelineStage` (`passed`, `failed`, `indeterminate`, or
`notAttempted`), the untouched evidence of each stage (`ProvisioningProfileVerification`
and `ProvisioningPolicyValidationResult`), the aggregated findings, and one
integrated status. There is no `isValid`, `isTrusted`, `isSigned`, or
`isInstallable` field, and no single Boolean collapses the stages: discovered,
parsed, structurally valid, authenticated, related, and compatible remain six
separate statements, and a `ProvisioningProfilePipelineSummary` renders them
separately for presentation.

**Accepted — the status rules, stated exactly.** `invalid` when at least one
finding is `rejected`: a rejected or undecodable container, a payload that is not
a parsable profile, a structurally rejected profile, or a violated policy rule.
`unsupported` when nothing was rejected and at least one finding is `unsupported`:
a container form or payload format ZynSign deliberately does not handle, or a
declared digest/signature pair it does not map onto an operation. `valid` when every
required stage passed and the policy evaluation returned `compatible` — and because
`compatible` requires that every policy category be satisfied, a deferred device
question, an unanswered entitlement question, or an unavailable verification
mechanism makes `valid` impossible rather than automatic. `indeterminate` otherwise.
`profileInput` is a required stage for `valid`; "bytes were obtained" is its
positive outcome, so absence or unreadability never reads as validity. A `valid`
status is the last thing this pipeline can say and says only that ZynSign's own
implemented stages passed; it is not a claim that iOS would accept, install, or
authorize anything.

**Accepted — an absent profile is an absence, not a verdict.** `notFound` (nothing
supplied and no `embedded.mobileprovision` entry recorded), `unusable(failure)` (an
entry was found and could not be read, with the reason from
`ProvisioningProfilePipelineAcquisitionFailure`), and `bytes` are three distinct
inputs, and the first two end a run at acquisition with `indeterminate`: an App
Store package legitimately carries no embedded profile, and a package ZynSign
cannot open says nothing about any profile. The pipeline never converts a
read failure into a malformed-profile finding, an unavailable mechanism into a
defect in the user's input, or an unresolved question into either a pass or a
failure.

**Observed — failure aggregation without a new vocabulary.** Each finding names its
stage and carries that stage's own code — `CMSFailure`,
`ProvisioningProfileFailure`, `ProvisioningProfileValidationIssueCode`, or
`ProvisioningPolicyFindingCode` — plus the sentence the stage wrote, so a caller can
diagnose "CMS passed, certificate relationship passed, bundle identifier failed,
one entitlement unapproved, validity passed" without rerunning any stage. Three
codes are the pipeline's own: `profileNotFound`, for an input that was never there;
`containerEvidenceUnavailable`, for a run whose boundary produced no evidence object
to read states from; and `payloadNotParsed`, for a payload left unparsed because its
container did not verify. Architecture Section 17 requires that a boundary's
failure vocabulary stay its own; a fourth vocabulary here would be free to drift
from the three it reports on.

**Accepted — certificate evidence is reported, not re-decided.** The pipeline
exposes whether a signer certificate exists, whether the profile carries certificate
references, whether the two correspond (`certificateCorrespondence`), how the
locally listed identities relate (`signingIdentityRelationship`, from ZS-018's
read-only listing), and the key availability that listing reported — and it
deliberately does not make a signer/profile mismatch fatal. ZS-019 records that
mismatch as an open question in its certificate category, and for good reason: a
profile whose container was signed by an issuer it does not list among its
developer certificates is the ordinary shape of a real profile, so promoting the
observation to `invalid` would be a false positive while promoting it to `valid`
would be unsupported. The relationship stage therefore reports `failed` as a
descriptive answer to its own question, and the status rules take their verdict from
the policy stage alone.

**Accepted — one unit of work per question, and nothing persisted.** A run performs
one container verification, one payload parse, one structural validation, one
relationship analysis, and one policy evaluation; no stage is rerun to render a
summary, and the result exposes each stage's evidence so a caller never repeats the
work. No cache is introduced, because there is nothing measured to justify one, and
the result is derived from the profile, the application, the identity, the
configuration, the clock, and the device context a caller has — so it goes stale by
construction and is never persisted. The profile bytes, the parsed entitlements,
the application metadata, and the identity metadata are read, never mutated; no
Keychain record, key reference, password, or private key crosses any boundary here.

**Accepted — the artifact boundary stays the archive boundary.**
`BundleProvisioningProfileIntake` is how an embedded profile reaches the pipeline:
it asks the library's own `ArtifactArchiveReaderProvider` for the record's
container, reads the entry table, resolves the primary application bundle through
`ApplicationBundleDiscovery` — reporting ambiguity rather than choosing a
candidate — and reads at most one entry, `embedded.mobileprovision`, within the
tighter of the archive's inspection-read bound and the profile input bound. It
reuses the role vocabulary ZS-013 established for that location and adds no reader,
no store, no extraction, no filesystem path in its result, and no conclusion:
whether those bytes are a profile, whether they are authenticated, and whether
they suit the application are the pipeline's questions. The explorer remains a
listing of structure that opens nothing, and its label for that location still says
so. A record whose artifact is missing or no longer matches what was recorded is
reported as unreadable input, and no container is opened for it.

**Trust boundary, Accepted.** Successful integration means: the container's
signature verified for the payload that was parsed, that payload satisfies
ZynSign's structural rules, and the configuration satisfies the policy rules
ZynSign implements. It does not mean the signer's certificate is trusted or
Apple-issued, that a chain reaches an anchor, that a private key was ever used or
even present, that the entitlements will be enforced, that the device is
provisioned, or that the platform will accept or install anything.
`trustEvaluation` stays `notPerformed` and `authorization` stays `notEvaluated` on
every path, and diagnostics inherit the redaction rules of the stages they compose:
states, outcomes, codes, bounded counts, and fingerprints — no identifiers, values,
bytes, keys, or credentials.

**Deferred, recorded.** Whether the platform's wildcard, entitlement, device, and
profile-class rules agree with the predicates ZS-019 implements remains Unknown, and
whether a trustworthy device identifier can be obtained at all remains an open
question of the feasibility record; the pipeline inherits both rather than
answering either. Whether real Apple-signed profiles behave as the fixture containers
behave is measured by experiments E3 and E4, not by this increment. Composing an
interface, persisting a status, and reading a profile from an extracted bundle tree
are deliberately not done here.

**Evidence status.** The stage sequence, the result shape, the status rules, the
aggregation, the non-mutation, and the intake's bounds are **Observed** from this
repository's implementation. The mapping from a stage's typed failure to a finding
severity is this repository's own conservatism. No iOS build, device, or simulator
was available in the environment where this increment was written, and its suites
were not executed there, so nothing here is platform evidence.

### Cryptographic Signing and Verification Foundation

**Accepted for ZS-021 — a generic cryptographic foundation, not a
code-signing engine.** This increment establishes the reusable primitives the
signing stage's construction work will consume: hashing, cryptographic
signing, signature verification, signing-key capability use, certificate and
identity metadata references, algorithm compatibility, signing requests,
signing results, and structured crypto failures. It is explicitly not Apple
code signing: nothing here reads, locates, or modifies a Mach-O binary,
constructs a CodeDirectory or a SuperBlob, assembles a signature slot, signs a
bundle, generates `CodeResources` or an `IPA` package, installs anything, or
generates a provisioning profile. A success reported by any of these
primitives means one thing only — the requested generic cryptographic
operation completed — and the types are shaped so that no field can collapse
that into a statement about code-signing validity, trust, or installability.
The signing and installation stages of Section 5 remain documentation of
intended structure.

**Accepted — the algorithm model keeps its parts distinct.**
`PublicKeyAlgorithm` (RSA, EC, unknown), `DigestAlgorithm` (SHA-1, SHA-256,
SHA-384, SHA-512), and `SigningAlgorithm` are three different axes, and
`SigningAlgorithm` is the single value that binds them with the operation's
input semantics: each case states its key family, the digest it works on
(`digestAlgorithm`, SHA-256 for every current operation), its input semantics
(message versus pre-computed digest, through `digestLength`), and its
signature encoding (PKCS#1 v1.5 or DER X9.62). An operation is performed
under exactly the value that was requested: an unsupported combination, a
digest of a different algorithm, or a message presented to a digest operation
is a structured `CryptoFailure`, never a substitution or a downgrade, and
SHA-1 is never selected for signing even though it is computable as a digest.

**Accepted — the digest primitive is a value with a stated algorithm.**
`Digest` carries the algorithm and the exact digest bytes; its initializer
returns `nil` for bytes of any other length, so a value that is not a digest
of its algorithm cannot be constructed. `hexString` is a rendering of the
bytes for diagnostics and identifiers, never a substitute. `MessageDigest` is
declared in Domain, and its implementation is `CryptoKitMessageDigest` in
Platform: CryptoKit's SHA-256/SHA-384/SHA-512 are documented for iOS 13 and
`Insecure.SHA1` for iOS 13 as well (**Verified** — Apple CryptoKit
documentation), both under the iOS 17 deployment target, so no third-party
hashing library is introduced. The digest operation's one-shot API hashes the
data the caller already holds; streaming hashing is deliberately deferred to
the stage that will need page- and resource-scale inputs, rather than added
before it is measured. SHA-1 exists in the vocabulary because legacy
code-signing formats use it; nothing in this increment claims it is an
acceptable signing digest.

**Accepted — the signing request is focused and carries no key material.**
`SigningRequest` names exactly four things: the identity whose capability
performs the operation (`SigningIdentityIdentifier`), the operation
(`SigningAlgorithm`), the data with its semantics explicit
(`SigningInput.message(Data)` or `SigningInput.digest(Digest)`), and optional
diagnostic context (`SigningOperationContext`, a bounded label of at most 128
characters without line breaks). It carries no private key, no password, no
key reference or locator, no filesystem path, and no knowledge of Mach-O,
bundles, profiles, or interfaces, so it stays reusable by the later
code-signing construction. `validate()` states the rules: a message operation
takes a message, a digest operation takes a digest, and a digest must be one
the operation works on. The engine re-checks these before any capability is
consulted.

**Accepted — signing happens through the existing capability boundary.**
`CapabilitySigningEngine` (behind the `CryptographicSigningEngine` port in
Domain) is pure: it validates the request, checks that the capability's key
family matches the operation, that the capability is available, and that the
operation is one the capability supports — in that order, with each failure a
distinct `CryptoFailure` — and then asks the capability for exactly one
signature. The private key never crosses this boundary: the engine holds no
key, no key reference, and no key bytes; only the data and the explicit
operation go across, and only signature bytes come back. A structured
failure the capability reports keeps the identity boundary's own
`SigningIdentityFailure` reason, because key-state facts belong to that
boundary; a foreign, unstructured failure is reduced to `signingFailure` and
its text is never retained. An empty signature is `malformedSignature`. The
engine's result deliberately carries no certificate fingerprint: the
capability exposes no certificate, so the application layer attaches that
reference.

**Accepted — the signing result is structured and redacted by construction.**
`SigningResult` is an all-`let` value with an explicit memberwise
initialization: signature bytes, the operation used, its digest algorithm,
the identity reference, the key family the capability reported, the
certificate fingerprint when the caller can supply one, the signed digest
when the request carried one, and the operation context. Its diagnostic
rendering carries the operation's facts and byte counts — never the
signature bytes, never the signed data, never any key or credential.

**Accepted — verification is a separate boundary with explicit outcomes.**
`CryptographicSignatureVerifier` is the verification counterpart of
`SigningCapability`: it takes only public material — a signature, the bytes
the signature claims to cover (explicitly a message or a digest), the
selected operation, and a certificate — and returns a
`SignatureVerificationOutcome`. The four outcomes are deliberately four
different facts: `valid` (the signature was produced by the private key
matching the certificate's public key), `invalid` (it does not verify),
`unsupported(reason)` (this build cannot perform the operation), and
`failed(reason)` (no conclusion was reached). A non-verifying signature is a
normal outcome, not an exception, so a caller can distinguish "does not
verify" from "could not be checked". The port never touches a private key and
never requests a signing capability, so a signing-side bug cannot silently
validate itself (Section 5). `AppleSignatureVerifier` in Platform checks with
`SecKeyVerifySignature` (**Verified** — documented iOS 10.0+) under the
operation `SigningAlgorithm` selects, reading the public key from the
presented certificate with `SecCertificateCreateWithData` (iOS 2.0+) and
`SecCertificateCopyKey` (iOS 12.0+), both **Verified** from Apple Security
documentation. Hashing stays inside the platform primitive: a message is
handed over whole under a message-based operation, and a digest as-is under a
digest-based one. The outcome mapping reuses the CMS boundary's
mismatch/status detection, so a plain mismatch is `.invalid`, a platform that
cannot perform the check is `.unsupported` or `.failed(.platformLimitation)`,
and a certificate whose own key family does not match the operation is
`.unsupported(.incompatibleKey)` before any platform primitive is consulted.
`UnavailableCryptographicSignatureVerifier` is the honest fallback on
non-iOS targets: every verification is reported unavailable, never skipped.
A `.valid` outcome establishes only the cryptographic fact named above — not
that the certificate is trusted, Apple-issued, in a chain, or that anything
is code signed.

**Accepted — the identity boundary is unchanged and still owns the key.**
Signing reaches the private key only through the ZS-016 `IdentityStore` →
`SigningCapability` path: `CryptographicSigningUseCase` validates the
request, resolves the capability through the store, invokes the engine, and
attaches the certificate reference best-effort — an identity the store can
no longer describe does not fail an already-produced signature, it simply
goes without the reference. The private key remains inside the store's
platform mechanism on every path; no operation here requests, receives, or
records key bytes, and a removed registration still never deletes a borrowed
key. This use case is not installed in the application environment: the
identity store is not composed into the app until its device validation
completes, and no interface consumes a signature result yet.

**Accepted — the failure vocabulary is its own.** `CryptoFailure` describes
what the cryptographic boundary decides: `unsupportedAlgorithm`,
`incompatibleKey`, `invalidInput`, `malformedSignature`,
`certificateUnavailable`, `signingFailure`, `verificationFailure`,
`capabilityUnavailable`, `platformLimitation`, and `unexpectedFailure`,
mapped onto the existing `DiagnosticCategory` values. `ZynSignError` carries
the reason alongside the identity, profile, and CMS vocabularies, and a
failure the identity boundary decided keeps its own reason when it crosses a
capability rather than being restated in this vocabulary. User messages are
fixed per reason and free of detail; diagnostic detail stays redacted;
foreign error text is never retained (Section 17).

**Out of scope, stated.** Mach-O parsing or mutation, CodeDirectory,
SuperBlob, and signature-slot construction, page hashing, CMS construction,
nested signing, `_CodeSignature` and `CodeResources`, IPA repackaging,
installation, provisioning-profile generation, `.p12` import, Secure Enclave
implementation, `codesign` or any shell or subprocess, private APIs, a fake
signing UI, and third-party crypto libraries without a demonstrated need are
all excluded from this increment, and none of them may be inferred from it.

**Evidence status.** The algorithm model, the request/result/verification
shapes, the engine's check order, the outcome model, the failure vocabulary,
and the redaction rules are **Observed** from this repository's
implementation. API availability for `SecKeyVerifySignature`,
`SecCertificateCreateWithData`, `SecCertificateCopyKey`, and the CryptoKit
hashing primitives is **Verified** from Apple documentation. On-device
behaviour of the signing and verification primitives — protected-key
signing through the Keychain adapter, `SecKeyVerifySignature` over the
fixture signatures, and per-use authorization — remains **Requires
experiment** (E1 and E4), and the test suites that would establish it were
not executed in the environment where this increment was written; no
device, simulator, or Keychain result is claimed here.

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
- the policy-validation vocabulary: `ProvisioningPolicyValidationContext`,
  `SigningConfiguration`, `SigningGetTaskAllowPreference`,
  `RequestedGetTaskAllowClaim`, `ProvisioningPolicySigningIdentity`,
  `ProvisioningDeviceContext`, `ProvisioningPolicyPlatformScope`,
  `ProvisioningIdentifierCompatibility` with
  `ProvisioningIdentifierCompatibilityOutcome`, `ProvisioningEntitlementComparator`
  with `ProvisioningEntitlementComparisonOutcome` and
  `ProvisioningEntitlementEvaluation`, `ProvisioningPolicyValidator`,
  `ProvisioningPolicyValidationResult`, `ProvisioningPolicyCategoryResult`,
  `ProvisioningPolicyCategory`, `ProvisioningPolicyStatus`,
  `ProvisioningPolicyOutcome`, `ProvisioningPolicyFinding`, and
  `ProvisioningPolicyFindingCode`
- the cryptographic signing and verification vocabulary: `Digest` and the
  `MessageDigest` port, `SigningInput`, `SigningOperationContext`,
  `SigningRequest`, `SigningResult`, the `CryptographicSigningEngine` port
  and `CapabilitySigningEngine`, `SignatureVerificationOutcome`, the
  `CryptographicSignatureVerifier` port and
  `UnavailableCryptographicSignatureVerifier`, and `CryptoFailure`
- `PackagingPolicy`
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
| `SigningCapability` | The single narrow abstraction where signing happens, returning signature bytes only, without exposing private-key material | Domain | Yes — stub capability keeps orchestration testable | Yes — key access is platform-bound, non-exportable keys expected | **Implemented** as protocol (Section 7); concrete Keychain implementation Requires feasibility research (items 2, 16); consumed by the ZS-021 generic signing engine as well as the future code-signing engine |
| `ProvisioningProfilePayloadDecoder` | CMS/container boundary that supplies decoded profile payload bytes without making metadata trusted | Domain | Yes — synthetic payload decoder | CMS handling is platform-constrained; no complete iOS CMS API is assumed | **Implemented and backed by a real verifier**: `CMSProvisioningProfilePayloadDecoder` supplies authenticated payloads from the CMS boundary, fails closed on rejected containers, and marks unevaluated ones `.notEvaluated` (Section 7) |
| `CMSVerifier` | Verification of one untrusted CMS container, returning staged evidence instead of a validity flag | Domain | Yes — substitutable with a stub verifier and synthetic containers | No platform object crosses it; the implementation is platform-bound | **Implemented** for SignedData by ZynSign's own bounded reader, because no CMS decoder exists on iOS (**Verified**); trust evaluation is not part of this port (Section 7) |
| `CMSSignatureVerifier` | The single narrow seam where one signature is checked against one certificate's public key | Domain | Yes — recording double keeps orchestration testable without a device | Yes — the concrete implementation uses Security key primitives and is compiled for iOS only | **Implemented** for RSA PKCS#1 v1.5 and ECDSA X9.62 over SHA-256 messages; unsupported combinations and missing mechanisms are reported, never skipped; on-device behaviour Requires experiment E4 |
| `MessageDigest` | Digest computation over arbitrary byte input, with the algorithm stated on the result | Domain | Yes — the platform mechanism is substituted in pure tests | No — CryptoKit's hashing primitives are documented for the deployment target, and the implementation is platform-bound to Apple's primitives | **Implemented** by `CryptoKitMessageDigest` (SHA-1, SHA-256, SHA-384, SHA-512); a digest is a value with its exact bytes, hex is presentation only (Section 7) |
| `CryptographicSigningEngine` | The single place where a generic cryptographic signature is produced from a validated request through a capability | Domain | Yes — a recording capability keeps the engine testable without a key | No — the engine is pure; the key access it reaches is the ZS-016 capability's | **Implemented** as the pure `CapabilitySigningEngine`; signs only through `SigningCapability`, never holds key material, and substitutes no algorithm (Section 7) |
| `CryptographicSignatureVerifier` | The single narrow seam where one generic signature is checked against one certificate's public key, returning an explicit outcome value | Domain | Yes — recording double keeps callers testable without a device | Yes — the concrete implementation uses Security key primitives and is compiled for iOS only; the fallback reports unavailable rather than skipping | **Implemented** for RSA PKCS#1 v1.5 and ECDSA X9.62 over SHA-256, message and digest inputs, with valid/invalid/unsupported/failed kept separate; on-device behaviour Requires experiment E4 (Section 7) |
| `ProvisioningProfileParser` | Interpretation of decoded provisioning-profile metadata as typed domain values | Domain | Yes — synthetic plist payloads | Property-list parsing is not platform-specific in principle | **Implemented** for the property-list payload; trust and authorization remain separate |
| `IdentityStore` | Resolution and presentation of available signing identities and their status, plus access to signing capability | Application | Yes — in-memory in tests | Yes — key access is platform-bound | **Protocol implemented** for this increment (Section 7); concrete Keychain store Requires feasibility research (items 2, 16); PKCS#12 import is separate capability |
| `SigningEngine` | The single place where code-signing blob assembly happens. Consumes signing capability alongside the ZS-021 generic cryptographic signing engine, which serves the signing stage's generic operations | Domain | Yes — a stub engine keeps orchestration testable | Yes | Requires feasibility research (items 1–7, 9, 10) |
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
- The policy-validation stage of Section 7 added no port, deliberately: it is
  pure domain logic over values that already exist, its platform-bound inputs
  (`IdentityStore` metadata, the CMS boundary, the certificate relationship)
  arrive through seams that are already declared, and it requests no signing
  capability. The absence of a port there is a decision, not an omission.

## 12. Application Layer

**Accepted**: the application layer owns workflow orchestration and is the only
place where stages are sequenced and composed.

- Use cases express user-visible operations (inspect a package, parse and
  structurally validate a decoded provisioning profile, verify a
  provisioning-profile container and report its staged evidence, evaluate a
  signing configuration against an authenticated profile, produce a signed
  artifact, verify an artifact, prepare a package for export) in terms of domain
  logic and ports.
- The integrated provisioning-profile pipeline is orchestrated here and decided
  nowhere else: `ValidateProvisioningProfileUseCase` runs the container boundary,
  the parser and structural validator, and the policy evaluation in that order,
  records an outcome per stage, aggregates each stage's own findings, and assigns
  one `ProvisioningProfilePipelineStatus` by the rules recorded in Section 7. It
  owns no validation rule of its own, throws for no validation outcome, mutates no
  input, and persists no result.
- Policy validation is orchestrated here and decided in Domain:
  `ValidateProvisioningConfigurationUseCase` assembles a
  `ProvisioningPolicyValidationContext` from a staged verification result,
  application metadata, a bundle identifier, read-only identity metadata, the
  requested configuration, and the device and platform context, and returns the
  domain validator's structured result. It performs no signing, requests no
  signing capability, persists no result, and never turns a policy outcome into a
  thrown error.
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
| Pure unit tests | Deterministic logic with synthetic fixtures, no I/O | Host | Validation rules, metadata rules, bundle-identifier matching, entitlement compatibility logic, provisioning-policy category evaluation and aggregation, nested-code ordering, error construction, redaction, deterministic algorithms, diagnostics |
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

The external validation harness (ZS-031) is the first standing instance of the
developer-side tier. An opt-in simulator test exports artifacts signed through
the production use cases with a throwaway in-process key, and a host harness
judges them with `codesign`, `otool`, and OpenSSL on a hosted macOS runner,
compares them with `codesign`'s own ad hoc signing of the same inputs, and
records every verdict. The CI job is measurement, not a gate. See
[external-validation.md](external-validation.md).

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
  outcomes, `SigningIdentityFailure` describes identity outcomes, and
  `CryptoFailure` describes generic cryptographic signing and verification
  outcomes; a payload that is not a property list is a profile failure even
  though CMS verification succeeded, a container that cannot be decoded never
  reaches the profile vocabulary, and a protected-key failure the identity
  boundary decided keeps its own reason when it crosses a signing capability
  rather than being restated in the crypto vocabulary.
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

| 30 | Provisioning-profile policy validation | **Accepted** for this increment — read-only policy evaluation over an authenticated profile, application metadata, identity metadata, a requested signing configuration, and platform/device context; nine three-state categories with `compatible`/`incompatible`/`indeterminate` overall; authenticity gates every other category; one identifier rule shared by the bundle-identifier check and the `application-identifier` claim check, with wildcard scope as a component-boundary prefix test and no split without an explicit application-identifier prefix; team identity only from structured organizational-unit evidence; certificate evidence layered on ZS-018 with container-signer, identity-certificate, and key-availability facts kept separate; validity and platform from existing models with an injected clock; device comparison only with a trustworthy identifier and no fabricated value; typed per-key entitlement comparison with allowlist inclusion (**Verified** — TN3125), no coercion, no array-order assumption, explicit `get-task-allow` semantics, and unsupported or indeterminate outcomes instead of defaults; structured aggregation of every meaningful finding; redacted diagnostics; policy logic in Domain with `ValidateProvisioningConfigurationUseCase` orchestration read-only, no persistence, no signing, and no policy interface; trust stays `notPerformed` and authorization stays `notEvaluated`; platform acceptance, entitlement enforcement, and device authorization remain separate and unclaimed (Section 7) |
| 31 | Provisioning-profile pipeline integration | **Accepted** for this increment — one application-layer use case sequences ZS-017 parsing and structural validation, ZS-018 container verification and certificate relationship, and ZS-019 policy validation into a single staged result, with the security order fixed so that a payload is parsed only after its signature verified and no policy rule is applied to an unauthenticated payload; seven stage outcomes (`passed`/`failed`/`indeterminate`/`notAttempted`) plus aggregated findings that carry each stage's own code vocabulary rather than a fourth one; integrated status `valid`/`invalid`/`indeterminate`/`unsupported` under the stated rules, with `valid` requiring every required stage to pass and policy to be `compatible`, and a signer/profile certificate mismatch kept as ZS-018 evidence rather than promoted into a verdict; absent and unreadable profiles distinguished from malformed and incompatible ones, and never reported as an invalid application; a read-only embedded-profile intake over the existing `ArchiveReader`, `ApplicationBundleDiscovery`, and library-storage boundaries with one bounded entry read and no extraction, no second reader, and no second store; one container verification, one parse, one relationship analysis, and one policy evaluation per request with no caching; no signing engine, no Mach-O or entitlement mutation, no persistence, no trust evaluation, no authorization, and no interface; trust stays `notPerformed` and authorization stays `notEvaluated` (Section 7) |
| 32 | Generic cryptographic signing and verification foundation | **Accepted** for this increment — a focused signing request with explicit message-or-digest semantics and no key material, a pure signing engine that signs only through the ZS-016 capability and substitutes no algorithm, a structured all-let signing result whose diagnostics carry facts and counts but never signature bytes or signed data, a digest value with its algorithm stated and exact-length enforcement over CryptoKit's documented hashing primitives, a verification boundary whose `valid`/`invalid`/`unsupported`/`failed` outcomes are four distinct facts and whose implementation checks with documented Security key primitives under the requested operation, and a `CryptoFailure` vocabulary that stays its own while identity-boundary reasons keep their own vocabulary across a capability; key material never crosses any new boundary, and success means only that the generic operation completed — never Apple code-signing validity, trust, or installability; Mach-O, CodeDirectory, SuperBlob, page hashing, CMS construction, nested signing, `CodeResources`, IPA repackaging, installation, profile generation, `.p12` import, Secure Enclave, shell or subprocess, private APIs, a fake signing UI, and third-party crypto libraries are all out of scope; on-device behaviour remains **Requires experiment** E1/E4 (Section 7) |
| 33 | Read-only Mach-O code-signature foundation | **Accepted** for this increment — a bounded parser over supplied bytes models thin 32/64-bit headers in both byte orders, fat32/fat64 slice tables and explicit architecture selection, load commands including `LC_CODE_SIGNATURE`, delimited SuperBlob entries and known indexed blobs, and CodeDirectory versions `0x20001` through `0x20600` with strings, hash metadata, special-slot positions, and version-gated optional fields. Unknown load commands, CPU families, hashes, and blob slots remain descriptive; malformed/truncated/unsupported inputs have structural errors. It does not read archive entries, change the explorer, verify digests/CMS/trust/authorization, or construct or mutate executable/signature data. Read-only parsing does not close feasibility items 5 or 6; see [Mach-O inspection](macho-inspection.md). |
| 34 | CodeDirectory construction and page hashing | **Accepted** for this increment — a value-typed constructor supports only CodeDirectory versions `0x20001` and `0x20200`, the published SHA-1/SHA-256/truncated-SHA-256/SHA-384 hash types, exponent-encoded page sizes, explicit code limits, negative special-slot representation, bounded big-endian serialization, and deterministic ordinary-page hashing through the existing digest port. It does not construct SuperBlobs, CMS, requirements, entitlements, CodeResources, or Mach-O changes, and it makes no iOS/iPadOS acceptance claim; see [codedirectory-construction.md](codedirectory-construction.md). |
| 35 | Mach-O code-signature region construction | **Accepted** for this increment — 16-byte-aligned `MachOCodeSignatureRegion` framing over validated ZS-024 SuperBlob serialization, `MachOCodeSignatureRegionLayout` arithmetic separating code limit from file length, `MachOCodeSignatureInspector` distinguishing absent, valid, and malformed existing signature states, default rejection of existing signatures with replacement unsupported, load-command capacity gating over verified zero header padding and `__LINKEDIT` virtual slack, universal binary mutation unsupported, and a narrow append-only `MachOCodeSignatureWriter` that preserves unrelated bytes byte-for-byte; no CMS, private-key signing, or platform acceptance is claimed; see [macho-signature-region.md](macho-signature-region.md). |
| 36 | Signing metadata: entitlements, requirements, and CodeResources | **Accepted** for this increment — a typed entitlement model over the existing `ProvisioningProfileValue` tree with unknown keys preserved, no enumerated entitlement vocabulary, dates excluded rather than coerced, bounds enforced, and five separate states (decoded, structurally valid, provisioning-compatible through a bridge that reuses the ZS-020 policy validator alone, embedded with `platformAuthorization` explicitly `notEvaluated`, and platform-authorized, which no local operation claims); one canonical XML property-list serialization (fixed header, ascending UTF-8 key bytes, tab indentation, one element per line, no value transformation) framing the `0xFADE7171` blob, with XML and binary payloads accepted on read and OpenStep refused; a requirements model carrying set framing and expression bytes verbatim with dispositions absent/presentAndParsed/presentButUnsupported/malformed/generated/verified, expressions never interpreted or generated, framing validated (magic, length, offset, overlap, duplicate-kind, count bounds) and malformed values refused at the embedding boundary before any cryptographic operation; a read-only `ResourceContentStore` port with in-memory and directory stores, deterministic ascending-path sealing, exact stored bytes hashed as `hash2`, symlink fail-closed-or-exclude policy with links never followed, caller-only exclusions recorded as omissions that are never serialized, and caller-supplied nested-code `cdhash` seals (first 20 bytes of the SHA-256 CodeDirectory digest) that the generator never signs or re-derives; the CodeResources document over `files2`/optional caller `rules2` with v1 `files`/`rules` an explicit `unsupportedTopLevelKey` refusal, deterministic serialization through the one canonical serializer, and a parser accepting any legal plist spelling of the supported subset; special-slot derivation for slots 2/3/5 with digest inputs covering the complete embedded blobs for 2 and 5 and the CodeResources file bytes for 3 (**Observed**), contiguous zero-placeholder construction that never invents slot 1; pipeline ordering fixed so metadata is prepared and slots finalized before the CodeDirectory is constructed, hashed, and signed; per-target nested metadata never inherited, with metadata failures reported at the metadata stage (`signingMetadataFailure`) and leaving the staged artifact untouched; read-only inspection classifying embedded entitlements, requirements, and slot-3 state without mutating or verifying anything; structured per-stage errors with paths and counts but never contents or key material; no third-party dependency; byte-exact agreement with Apple's serializers, requirement-expression semantics, platform acceptance, and device behaviour all remain open and recorded as experiments (Section 7); see [signing-metadata.md](signing-metadata.md) |
| 37 | External validation of signing output | **Accepted** for this increment — developer-side validation (decision 15) as a standing, non-gating CI job: an opt-in export test signs synthetic inputs through the production use cases with a throwaway in-process RSA key and the production verifier and writes public material only; a standard-library host harness judges the exports with `codesign`, `otool`, `ditto`, `unzip`, and OpenSSL, evaluates Apple's documented iOS 15+ format rules, compares against `codesign`'s ad hoc signing of the same inputs with differences labeled expected, input-dependent, or divergence, and compares tamper verdicts; results live in a known-divergence register cited by run; no external tool is called from product code, no credential exists anywhere, and no verdict is presented as platform acceptance, trust, or installability ([external-validation.md](external-validation.md)) |

## 19. Non-Goals of This Document

This document deliberately does not:

- contain or describe production code, project files, dependencies, or tests;
- make a platform-acceptance claim for the conservative construction subset,
  or select entitlement derivations, before feasibility research;
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
