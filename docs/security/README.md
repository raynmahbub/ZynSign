# Security Documentation

Detailed security documentation for ZynSign will live here.

## Current State

**No security documentation exists yet, because no security-sensitive
functionality exists yet.** ZynSign is in a pre-development state and contains no
source code. There is no signing implementation, no key handling, no credential
storage, no certificate or provisioning profile processing, and no device
communication. Nothing here should be read as describing implemented behaviour.

## Read First

The binding rules are at the repository root and apply now:

- [SECURITY.md](../../SECURITY.md) — never commit secrets, credentials, or
  private keys; how signing-related material is protected; and how to report a
  vulnerability privately.

## What Will Live Here

Documents are added when the functionality they describe is being designed or
built, not before:

- Threat model for the areas the project touches.
- Key, certificate, and provisioning profile handling design.
- Storage and lifecycle of sensitive material at rest and in memory.
- Logging and diagnostics rules — what may and may not be written out.
- Entitlements and permission rationale.
- Device communication and file transfer considerations.

## Conventions

- Describe the security properties of code that exists, and label planned work
  as planned.
- Security designs are reviewed by the developer before implementation.
- Never include real signing material, credentials, private keys, provisioning
  profiles, real identifiers, device identifiers, or user data. Use clearly
  marked synthetic placeholders. See [SECURITY.md](../../SECURITY.md).

## Index

No documents yet.
