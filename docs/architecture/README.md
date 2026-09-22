# Architecture Documentation

Architectural decisions for ZynSign are recorded here.

## Current State

ZynSign is in a pre-development state. There is no source code, so the
architecture describes intended structure and boundaries only: no module, layer,
or interface below is implemented, and no behaviour may be inferred from these
documents.

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
