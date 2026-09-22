# Architecture Documentation

Architectural decisions for ZynSign are recorded here.

## Current State

ZynSign is at the start of development. An Xcode application target with a
SwiftUI shell, a composition root, minimal domain types, and a unit-test target
establishes the layer boundaries the architecture describes. The archive layer
the inspection stage depends on has since been added — bounded ZIP container
reading behind the `ArchiveReader` boundary, application-bundle discovery, and
structural validation of a package's layout — and its decision is recorded in
Section 9 of [architecture.md](architecture.md). The application metadata layer
has also been added — extraction and validation of the metadata a bundle
declares in its bundle information file, behind a pure domain reader and an
application-layer use case — and the decision to parse property lists inside
the metadata reader rather than behind a `PlistDecoder` port is recorded in
Section 11 of [architecture.md](architecture.md).

The document-import workflow has also been added: user-driven selection of
an `.ipa` file through the system document picker, one security-scoped,
bounded-chunk staging of the selected document into application-owned
temporary storage addressed by the artifact identifier, and examination of
the staged archive through the existing inspection use cases. The staging
decision — including the staged archive's explicit lifetime — is recorded in
Section 8 of [architecture.md](architecture.md).

Application persistence has also been added: accepted imports become durable
library records held in a versioned catalog file, their archives are adopted
into application-owned artifact storage, and a content-based duplicate policy
decides whether an import is already held. The persistence decision — record
model, storage mechanism and why it was chosen, artifact ownership, duplicate
policy, failure and cleanup behaviour, and the migration rule — is recorded in
Section 15 of [architecture.md](architecture.md). The Applications area now
presents that library: it lists the records with each record's current
artifact availability, imports another package through the existing
document-import workflow, opens a detail screen per record, and removes a
record together with the package file behind it.

Bundle inspection has also been added: from a record's detail screen, a
read-only explorer lists the files and folders inside the application bundle
— names, bundle-relative locations, kinds, declared sizes, and descriptive
labels on conventional locations — derived from the package's entry table
through the existing archive boundary. The decision — why the explorer reads
the entry table rather than extracting, why it introduces no second reader or
store, how bundle-relative paths keep navigation inside the bundle, how links
and unsupported entries are treated, and why labels describe without
establishing signing or trust — is recorded in Section 9 of
[architecture.md](architecture.md).

The certificate and signing-identity foundation has also been added: a
platform-independent certificate metadata model, validity evaluation that
distinguishes parsing success from current validity, chain representation
without trust evaluation, a narrow signing-capability abstraction that does
not expose private-key bytes, a distinct signing-identity model, an
identity-store boundary, and a certificate parser behind the
`CertificateParser` port using Apple Security framework APIs where available.
The decision — why certificate and signing identity are distinct, how the
parsing boundary treats input as untrusted, how the private signing
capability stays behind a security boundary, how the identity-store and
trust-validation boundaries are separated, why PKCS#12 is a separate
capability, and what platform questions remain unresolved — is recorded in
Section 7 of [architecture.md](architecture.md).

An experimental secure identity registry and Keychain signing-capability adapter
now refine that foundation. They remain uncomposed pending physical-device E7
validation. See the [security design](../security/signing-identities.md) for
protection semantics, ownership, API evidence, and import limitations.

The provisioning-profile parsing increment now adds a bounded raw-input and
CMS-decoder port, a decoded-payload property-list parser, typed entitlement and
metadata values, injected-clock period validation, and an application-layer
inspection use case. It intentionally does not unwrap or verify CMS, inspect an
embedded profile through the archive workflow, authorize entitlements, or
persist profile data. The decision is recorded in Section 7 of
[architecture.md](architecture.md).

Everything else is intended structure only. The archive inspection stage is a
partial capability: it reads containers, classifies layout, reads one bundle's
declared metadata, and describes a bundle's structure; it does not verify
signatures, inspect executables, extract content, or produce a package. The
separate profile payload pipeline can parse decoded profile metadata, but it
does not establish authenticity or authorization. Library records are kept
across launches and are listed, imported, browsed, and removed in the
Applications area. Certificate parsing and identity modeling exist as domain
foundation; no application-signing, verification, packaging, or installation is
implemented. No other workflow behaviour is
implemented, and no behaviour may be inferred from these documents.

## Index

- [architecture.md](architecture.md) — the normative architecture. Runtime
  platform, layer model, workflow boundaries, protocol boundaries, security and
  persistence positions, testing architecture, and the decision table.
- [phase-0-discovery.md](phase-0-discovery.md) — technical discovery findings on
  IPA structure, signing material, code signing, nested code, repackaging, and
  installation. Findings feed the feasibility boundaries in the architecture
  document, which is authoritative where the two differ.

## Classification

Architecture documents state the status of each decision and each
platform-dependent assumption, using: **Accepted**, **Provisional**,
**Unresolved**, or **Requires feasibility research**. A capability is not treated
as available on iOS/iPadOS because an equivalent capability exists on another
Apple platform.

## What Will Live Here

- **Architectural Decision Records (ADRs).** One file per decision, numbered
  sequentially, capturing the context, the decision, and its consequences.
- **Component overviews.** Written once components exist and are stable enough
  to describe.
- **Data flow and lifecycle notes.** Written once the relevant behaviour is
  implemented.

## Conventions

- One decision per document; keep them short.
- Suggested naming: `NNNN-short-title.md`, for example `0001-example-decision.md`.
- Supersede rather than delete: mark an outdated record as superseded and link to
  its replacement.
- Describe what the system does, not what it might do. Planned work is marked as
  planned.
- State platform dependencies explicitly and mark anything unverified for
  iOS/iPadOS as unresolved.
- Never include secrets, credentials, private keys, provisioning profiles, real
  identifiers, or user data. See [SECURITY.md](../../SECURITY.md).
