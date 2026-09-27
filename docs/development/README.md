# Development Documentation

Guides for working on ZynSign will live here.

## Current State

The repository contains an Xcode project (`ZynSign.xcodeproj`) with an
iOS/iPadOS application target (`ZynSign`) and a unit-test target
(`ZynSignTests`).

- **Toolchain requirement:** Xcode 16 or later. The project uses synchronized
  folder groups instead of per-file project entries, so sources are picked up
  directly from the `ZynSign/` and `Tests/ZynSignTests/` directories.
- **Platform:** the product runtime is iOS/iPadOS (iPhone and iPad). macOS is
  developer tooling only, never a runtime platform.
- **Deployment target:** the project currently builds against iOS 17.0. This
  is a provisional build setting; the deployment-target decision remains open
  in the architecture (Section 6, item 17) and the setting is expected to
  change when that decision is made.
- **Build and test:** open the project in Xcode and use Product ▸ Run /
  Product ▸ Test, or the equivalent `xcodebuild` invocation against the
  shared `ZynSign` scheme. Hosted CI runs the same build and unit-test
  target on every push; it first passed on 2026-09-24 (see
  [continuous-integration.md](continuous-integration.md)).
- **External validation:** the opt-in export test and the Apple-tooling
  harness, run locally or by the `external-validation` CI job, are
  described in
  [external-validation.md](../architecture/external-validation.md).

## Read First

Development practice is defined at the repository root, and applies today:

- [CONTRIBUTING.md](../../CONTRIBUTING.md) — task scoping, branch-based
  development, testing expectations, code review, diff review, and Conventional
  Commits.
- [SECURITY.md](../../SECURITY.md) — handling of signing material, credentials,
  and private keys.

Version control actions are performed by the developer. See
[CONTRIBUTING.md](../../CONTRIBUTING.md).

## What Will Live Here

- Environment and toolchain setup.
- How to build and run the project locally.
- Coding conventions specific to the codebase.
- Debugging and diagnostics notes.

## Conventions

- Write instructions that were actually followed and verified. Record the
  toolchain versions used.
- Do not document a workflow that has not been run.
- Never include real credentials, tokens, private keys, or account identifiers
  in examples. Use clearly marked placeholders. See
  [SECURITY.md](../../SECURITY.md).

## Index

- [continuous-integration.md](continuous-integration.md) — the CI workflow
  definition, what each job establishes, what it explicitly does not claim,
  and how to run the same checks locally.

## Release readiness

See [Release Readiness Center](release-readiness.md) for validation scope, scoring,
privacy, performance boundaries and the remaining simulator/device acceptance checklist.
