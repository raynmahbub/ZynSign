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
trust/authorization, or device communication. ZS-017 added bounded parsing of a
caller-supplied decoded profile payload. ZS-018 adds verification of the profile
CMS container: a bounded SignedData reader written because Apple's CMS decoder
family is documented for macOS and Mac Catalyst only, signature checking through
documented iOS key primitives behind a port, signer-certificate extraction, and
certificate relationship analysis by SHA-256 fingerprint. It does not evaluate
certificate-chain trust, authorize entitlements or devices, construct CMS,
persist profile data, read embedded profiles from an archive, or expose any
profile interface. ZS-019 adds a read-only policy stage over that evidence, and
ZS-020 integrates the three stages into one application-layer workflow whose
`valid` result states only that every stage ZynSign implements reached its
positive outcome. For that workflow one `embedded.mobileprovision` entry can be
read out of a package through the existing archive boundary, behind a bounded,
read-only intake; the bundle explorer still reads no entry content, no profile
state is persisted, no signing capability is requested, and no profile interface
exists. Production activation of the identity path remains gated by experiment E7,
and of the profile verification path by experiments E3 and E4. The security
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
- [provisioning-profiles.md](provisioning-profiles.md) — profile container
  bounds, what a verified CMS signature does and does not establish, signer
  selection and fingerprint matching, the payload parse gate, identity
  relationships without capability requests, the integrated pipeline boundary and
  its status rules, redaction, platform evidence, and validation gates.
