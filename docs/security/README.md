# Security Documentation

Detailed security documentation for ZynSign will live here.

## Current State

**Limited security-sensitive foundation exists.** ZynSign contains the
application foundation — shell, composition root, archive reading, library
records, bundle inspection — and the certificate and signing-identity domain
foundation: platform-independent certificate metadata, validity evaluation
that distinguishes parsing from current validity, chain representation
without trust evaluation, a narrow signing-capability abstraction that does
not expose private-key bytes, a distinct signing-identity model, an
identity-store boundary, and a certificate parser behind the
`CertificateParser` port. Metadata is read by a bounded DER reader.
`SecCertificateCopyValues` is not available on iOS and is not used.
An experimental Keychain registry/resolver and explicit signature primitive now
exist, without production composition or UI. They use existing protected keys;
there is no key import, application-signing engine, provisioning-profile
trust/authorization, or device communication. ZS-017 does add bounded parsing
of a caller-supplied decoded profile payload; it does not verify CMS, authorize
entitlements or devices, persist profile data, or read embedded profiles from
an archive. Production activation remains gated by experiment E7. The security
boundaries for private-key material, certificate and profile parsing as
untrusted input, and raw certificate bytes ownership are established in
[architecture.md](../architecture/architecture.md) Section 7. Nothing else
here should be read as describing implemented signing behaviour.

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

- [signing-identities.md](signing-identities.md) — capability boundary, experimental
  Keychain ownership/protection, platform evidence, and validation gates.
