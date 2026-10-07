<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../Assets/Brand/Logo/logo-lockup-dark.svg">
    <img src="../../Assets/Brand/Logo/logo-lockup.svg" alt="ZynSign" width="260">
  </picture>
</p>

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
  target for every pull request (branch pushes run the static Quality checks
  only); it first passed on 2026-09-24 (see
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

## Guides

- [QuickStart.md](QuickStart.md) — clone to a running build; the same path CI runs.
- [Build.md](Build.md) — project shape, configurations, settings that matter.
- [Testing.md](Testing.md) — suites, host vectors, audits, and what CI enforces.
- [Debugging.md](Debugging.md) — the error model, the Lab, and the diagnosis tools.
- [Troubleshooting.md](Troubleshooting.md) — common refusals and the typed answers behind them.

These document workflows that are already exercised — by CI, by the release
train, or by the documented release gate. A guide that stops matching reality
is a defect: fix the guide or the workflow in the same commit.

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
