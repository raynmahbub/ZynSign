# ZynSign Architecture

## Status

This document defines the architecture of ZynSign: the platform it runs on, the
layers and boundaries the application is organised into, the decisions that are
settled, and the capabilities that are not yet established.

The first implementation increment now exists: an Xcode application target with
a SwiftUI application shell, a composition root, a minimal pure domain layer,
and a unit-test target. That foundation establishes the layer boundaries of
Section 4 and implements no workflow capability. Everything beyond that
foundation is documentation of intended structure, and nothing described here
should be read as a claim that any behaviour works.

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
| 4 | CMS / PKCS#7 signature construction | Apple's signed-data encoding services are documented for macOS and are not documented for iOS; whether any supported equivalent exists is unverified. If none exists, the format must be built or supplied by a dependency. |
| 5 | CodeDirectory generation and modification | Which code-directory versions, hash types, special slots, and code-limit/page-size conventions the target platform requires and accepts. |
| 6 | Code-signature blob embedding | Constructing and replacing the signature region of a Mach-O binary, including load-command layout, segment offset and alignment rules, and fat/universal binaries. |
| 7 | Entitlement handling | Building entitlement blobs, the relationship between profile-derived entitlements and binary entitlements, and which entitlement data forms the platform expects. |
| 8 | Provisioning-profile interpretation | The profile is signed structured data; parsing it is distinct from validating the container signature, and both are required before a profile can be trusted for authorization decisions. |
| 9 | Resource sealing | Reproducing the resource-seal form the platform evaluates, including how rules have changed across OS versions and which resources are sealed. |
| 10 | Nested-code handling | Deterministic discovery and signing order for frameworks, dynamic libraries, extensions, plug-ins, nested bundles, and nested applications, including exception cases. |
| 11 | Signature verification | The system code-signing validation services used on macOS are not assumed available to iOS applications. On-device verification may have to be implemented, with all of the format knowledge that implies. |
| 12 | IPA packaging | Archive writing and the layout, ordering, permissions, symlinks, and metadata the platform expects in a redistributable package. |
| 13 | Archive reading capability | Which archive container features can be read reliably on-device, and what resource limits can be enforced while reading. Implementation choice stays **Unresolved** until the deployment target is fixed. |
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
- **The archive implementation strategy is Unresolved.** No container-level
  archive capability for the deployment target has been confirmed, and no
  dependency is selected here. The decision depends on the deployment target, the
  container features that must be supported, the resource limits that must be
  enforceable, and the packaging requirements of Section 5. Selecting a library
  for completeness would prejudge all of those.

## 10. Domain Layer

The domain layer holds ZynSign's rules and vocabulary. It is pure, deterministic,
and testable without a device, a simulator, a keychain, or a network. This is
**Accepted**. Domain concepts include:

- `IPA`, `ArchiveEntry`, `Bundle`, `ApplicationMetadata`
- `NestedCode` and its dependency ordering
- `CertificateMetadata`, `SigningIdentity` metadata, `ProvisioningProfile`
- `SigningConfiguration`, `PackagingPolicy`
- `ValidationResult`, `VerificationResult`, `Diagnostics`
- domain errors and their categories

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
| `ArchiveReader` | Untrusted container input, behind which parsing, limits, and extraction live | Domain | Yes — substitutable with synthetic fixtures | Implementation is platform-dependent | Unresolved (Section 6, item 13) |
| `PlistDecoder` | Parsing of untrusted structured data with typed diagnostics | Domain | Yes | No — not platform-specific in principle | Accepted as a boundary; implementation Unresolved |
| `ProfileParser` | Interpretation of provisioning-profile data as authorization input | Domain | Yes | Container validation likely platform-dependent | Requires feasibility research (item 8) |
| `IdentityStore` | Resolution and presentation of available signing identities and their status | Application | Yes | Yes — key access is platform-bound | Requires feasibility research (items 2, 16) |
| `SigningEngine` | The single place where signing happens, and the only consumer of usable key material | Domain | Yes — a stub engine keeps orchestration testable | Yes | Requires feasibility research (items 1–7, 9, 10) |
| `SignatureVerifier` | Independent evaluation of an artifact, with no access to signing state | Domain | Yes | Yes — no system verifier may be assumed | Requires feasibility research (item 11) |
| `TemporaryStorage` | Controlled working space with lifetime, cleanup, and cancellation semantics | Application | Yes — in-memory or directory-backed | Partly — directories and lifecycle are platform-bound | Accepted as a boundary; mechanism Unresolved |
| `ApplicationRecordStore` | Persistence of non-sensitive library records and preferences | Application | Yes | No | Accepted as a boundary; technology Unresolved (Section 15) |
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

- Use cases express user-visible operations (inspect a package, produce a signed
  artifact, verify an artifact, prepare a package for export) in terms of domain
  logic and ports.
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
| Certificate and profile data | Treated as sensitive: parsed only as needed, displayed only as metadata, and redacted from diagnostics. |
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

Persistence technology is **Unresolved** and is not selected here. Choosing a
technology requires requirements that do not yet exist: query patterns, data
volume, migration expectations, synchronization needs, and confirmation of what
is available on the deployment target chosen for item 17 in Section 6.

The architecture does require that persistent data be classified:

| Class | Examples | Treatment |
| --- | --- | --- |
| Suitable for ordinary persistence | Application preferences, non-sensitive library records, display metadata, user-created labels and settings | Ordinary application storage; no special handling beyond correctness |
| Sensitive, requires special treatment | Private keys and any raw key material, signing credentials, raw certificate bodies, profile data where it is sensitive, device authentication or pairing material, temporary signing state | Not stored in ordinary application storage; storage mechanism, protection, and lifetime are decided by the research on Section 6 items 2, 3 and 16, and documented under `docs/security/` before implementation |

**Accepted:** persistence is never used as a shortcut for convenience with
sensitive material. If a value is classified sensitive, it belongs to the
mechanism chosen for secrets or it does not persist at all.

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
  line with `SECURITY.md`.
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
| 5 | Provisioning-profile parsing | **Requires feasibility research** — item 8 |
| 6 | Mach-O and code-signature handling | **Requires feasibility research** — items 5, 6 |
| 7 | Signature verification | **Requires feasibility research** — item 11 |
| 8 | IPA packaging | **Provisional** — ZynSign is responsible for producing its own package; format rules depend on item 12 and the deployment target |
| 9 | Installation mechanism | **Unresolved** — no known public application-facing mechanism (item 15); may be excluded from the first release |
| 10 | Persistence | **Unresolved** — technology deferred until requirements exist (Section 15) |
| 11 | Archive implementation | **Unresolved** — deferred until deployment target and archive capability requirements are established (Section 9) |
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

## 19. Non-Goals of This Document

This document deliberately does not:

- contain or describe production code, project files, dependencies, or tests;
- select concrete signing algorithms, code-directory versions, or entitlement
  derivations before feasibility research;
- select an archive library, a persistence technology, or a certificate-handling
  dependency;
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
