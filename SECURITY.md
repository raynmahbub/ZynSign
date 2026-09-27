<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/Brand/Banner/banner-dark.svg">
  <img src="Assets/Brand/Banner/banner-light.svg" alt="ZynSign — professional iOS sideloading platform" width="100%">
</picture>

</div>

# Security Policy

ZynSign is intended to work with signing material and user data. This document
sets out how sensitive material is handled during development and how to report
a security problem.

## Project State

ZynSign imports user-selected packages through bounded, security-scoped
staging, inspects them as untrusted input (archive structure, declared
metadata, read-only bundle listing), and keeps accepted packages as library
records. It can inspect untrusted public certificate bytes and record
metadata; that inspection does not handle private keys, does not persist
certificates, does not evaluate trust, and is not an application-signing
implementation. Untrusted profile containers are read under explicit bounds
and never executed. An experimental identity registry stores public
certificate bytes and opaque references in Keychain and resolves a
signature-only capability for existing protected keys. It is not composed
into the app; production activation requires physical-device validation.
ZynSign can read a provisioning-profile CMS container, verify its signature
with documented iOS key primitives, and relate the signer certificate to the
profile's own certificates by SHA-256 fingerprint; that path evaluates no
certificate chain, makes no authorization decision, persists nothing, and
has no interface. Below the interface, an experimental signing stack can
sign single Mach-O images and nested code through the same signature-only
capability boundary, with independent post-sign verification; it has no
interface, is not composed into the application, and is not a complete
application-signing workflow. There is no private-key import, no packaging
writer, no archive extraction, no installation mechanism, and no device
communication. See the [identity security design](docs/security/signing-identities.md)
for ownership, protection policy, and unverified platform behavior, the
[profile container security design](docs/security/provisioning-profiles.md)
for the CMS and pipeline boundaries, and the
[release security review](docs/security/release-review.md) for the final
review, the regression corpus, and accepted risks.

This policy describes how such material will be treated as the project develops,
and the rules that apply right now to the repository itself.

## Never Commit Secrets

Sensitive material must never enter the repository, in any file, in any
directory, at any point in history.

Never commit:

- **Secrets** — API keys, access tokens, refresh tokens, session tokens,
  passwords, passphrases, PINs, salts, or any other value used to authenticate.
- **Credentials** — Apple ID or developer account credentials, service account
  details, app-specific passwords, or any account material used to sign in to an
  external service.
- **Private keys** — signing keys, key stores, `.p12` / `.p8` / `.mobileprovision`
  contents, certificates, or any exported key material, whether or not it is
  encrypted.

Also avoid:

- real bundle identifiers, team identifiers, or provisioning profile UUIDs from
  a personal or production account;
- device identifiers (UDIDs) or other device-specific data;
- user data, application data, or anything extracted from a real device;
- internal URLs, hosts, or endpoints that are not meant to be public.

Committing a secret is treated as an incident even when the value is a test
value. Assume anything committed is public and permanent: removing a file in a
later commit does not remove it from history.

### If a Secret Is Committed

1. Treat the value as compromised. Revoke or rotate it immediately.
2. Tell the developer straight away, before doing anything else to the
   repository.
3. Let the developer decide how to remove it from history. Do not rewrite
   history or force-push on your own.

## Protecting Signing-Related Material

Signing material is the most sensitive category this project will handle. The
following applies now and will continue to apply as functionality is built.

- Keep signing material **out of the repository entirely**. It belongs in the
  developer's local environment, not in source control.
- Keep it out of logs, error messages, crash reports, and diagnostic output. Do
  not print key contents, profile contents, or account identifiers.
- Keep it out of tests and fixtures. Use clearly synthetic placeholder values in
  examples, and mark them as such.
- Keep it out of screenshots, issue reports, task reports, and commit messages.
- Do not copy signing material into temporary locations that outlive the
  operation, and do not leave it in build output or caches.
- Where the project later stores or reads such material, it must do so through
  platform-provided secure storage, and that design must be documented under
  [`docs/security/`](docs/security/) before it is implemented.

## Sensitive Dependencies

No third-party dependencies have been added. When dependencies are introduced,
each one will be recorded, and anything that touches keys, profiles, or device
communication will be justified in review before it is accepted.

## Security Review

Any change that touches authentication, cryptography, key handling, entitlements,
device communication, or file transfer requires explicit review by the developer
before it is committed, including a read of the full diff with attention to what
is written to disk, to logs, and to the network.

## Reporting a Vulnerability

Please report security issues privately. **Do not open a public issue.**

- Contact the project maintainer through a private channel — the private
  reporting address configured for this repository, or the maintainer directly.
- Include enough detail to reproduce: the affected component, the steps taken,
  and the observed versus expected behaviour.
- Do not include real signing material, real credentials, or real user data in
  the report. Use placeholder values and describe the sensitive part instead.
- Allow time for a fix before disclosing anything publicly.

Reports are taken seriously regardless of the reporter. Credit will be given on
request.

## Scope of This Policy

The rules above govern application code, development conduct, and repository
hygiene. Experimental identity storage is not production-validated. Security
review and the documented platform experiments remain required before activation.
