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

Everything else is intended structure only. The inspection stage is a partial
capability: it reads containers, classifies layout, and reads one bundle's
declared metadata; it does not verify signatures, parse profiles, inspect
executables, extract content, or produce a package. Library records are kept
across launches and are listed, imported, and removed in the Applications
area. No other workflow behaviour is implemented, and no behaviour may be
inferred from these documents.

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
