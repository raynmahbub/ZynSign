# RC 3 — Security Lockdown

**Date:** 2026-09-26 · **Milestone:** RC 3 — Step 29 ·
**Type:** one final security review of the frozen codebase.

Review environment: Linux with Python 3.11, without a Swift toolchain or
Xcode. Static review and hygiene scans were executed here; the suites named
below were executed on hosted CI. This lockdown composes and re-verifies
the six required areas against the shipped code and supplements — it does
not replace — the
[release security review](release-review.md), whose findings and accepted
risks stand.

## 1. Keychain handling — verified

- `SecureIdentityStore` holds signing identities with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, keys marked
  non-extractable (`kSecAttrIsPermanent`), and `kSecUseAuthenticationUI =
  fail` so resolution never prompts silently.
- Duplicate identities are rejected by SHA-256 certificate fingerprint;
  every resolution re-checks `association` and `capabilityState`
  (`IdentityAnnotations.swift`, `SecureIdentityStore.swift`).
- The identity store boundary never exposes private-key bytes
  (`SigningIdentityStorageBoundaryTests`, `CryptographicBoundaryTests`).
- Device-only integration coverage is opt-in
  (`KeychainIdentityIntegrationTests`) and is part of the private matrix.

**Status:** verified — no change since the release review.

## 2. Temporary file cleanup — verified

- Imports stage in `tmp` (relocatable via Settings → Advanced) and are
  adopted into `Application Support/ZynSignLibrary` only on confirmed
  settlement (`ImportHub`, `ImportStorageGuard`).
- Signing runs in per-operation working copies that are discarded on every
  outcome; retries always start clean (`SigningOperationExecutorTests`
  isolation assertions).
- Interrupted imports restore only from surviving working copies and sweep
  the rest (`ImportHub.restoreInterruptedImports`, `ImportHubTests`).
- Mission Control clears `tmp` older than 24 h and `Downloads` beyond
  500 MiB / 7 days (`MissionControlService`); Settings → Reset & Recovery
  can clear the workspace (`RecoveryActionKind.workspace`,
  `StorageManagementTests`).

**Status:** verified.

## 3. Backup encryption — verified (by design there is nothing secret to encrypt)

- The only backup artifact ZynSign writes is the **public certificate JSON
  backup** (`CertificateExportService.jsonBackup`): display name, subject,
  issuer, serial, SHA-256, validity dates, public-key algorithm and size,
  self-signed flag. It embeds an explicit note — *“Public metadata only —
  private key never exported.”* There is no key material to encrypt.
- Re-export of the original PKCS#12 container is intentionally out of
  scope; private keys never leave the Keychain
  ([signing-identities.md](signing-identities.md)).
- Provisioning profile originals stay inside the app sandbox and are never
  included in any export; exported entitlements reports are
  credential-free projections (Entitlements Studio export, §6).
- Everything ZynSign stores sits under iOS data protection for the app
  container; ZynSign adds no cloud backup, no sync, and no off-device copy.

**Status:** verified — backups contain public metadata only; the threat
“backup leaks secrets” is closed by construction.

## 4. Sensitive log removal — verified

- Executed scan on 2026-09-26: **zero** `print` / `NSLog` / `os_log` /
  `Logger(` / `dump` call sites exist in `ZynSign/` production code
  (`grep -rnE "(^|[^A-Za-z])(print\(|NSLog|os_log|Logger\()" ZynSign`).
- `DiagnosticLog` is opt-in (off by default) and carries a fixed category,
  a timestamp, and a closed-vocabulary slug — by contract no paths, no
  identifiers, no certificate/profile/entitlement/key material, no
  free-form text.
- Diagnostics and `ZynSignError` messages carry states, codes, counts, and
  fingerprints (SHA-256), never bytes or credentials.

**Status:** verified.

## 5. Private key protection — verified

- Private keys are created/imported only into the Keychain store above and
  are never serialized, copied to disk, or exported (hygiene scan refuses
  any `BEGIN … PRIVATE KEY` material in the repository; executed clean).
- Signing requests reference identities by identifier; the capability
  boundary (`SigningCapability`) never returns key bytes
  (`CryptographicSigningEngineTests`, `SecurityBoundaryTests`).
- Presets store a certificate **fingerprint**, never a key or password
  ([signing-presets.md](../architecture/signing-presets.md)).
- The external-validation export test generates a throwaway in-process RSA
  key that is never serialized (test-only; recorded in the release review).

**Status:** verified.

## 6. Report sanitization — verified

- Entitlements Studio JSON reports are credential-free projections with
  privacy omissions (no profile bytes, no identifiers); timestamps and
  fixed generator metadata only.
- Binary & Signature Inspector reports hold value reports only — never
  executable bytes; the only file written is the inspection report the user
  explicitly shares (`BinaryInspectorModel`).
- Certificate public JSON backups are §3. Export Center artifacts are the
  user's own signed IPAs; their records carry fingerprints, not paths, in
  diagnostics (`ExportRecord`).
- File names shown in diagnostics are sanitized
  (`ArchiveEntry` diagnostic-name sanitisation tests).

**Status:** verified.

## Leak check through normal workflows

Each normal workflow (import → inspect → sign → verify → export → deliver)
was traced for data egress: none writes key material, credentials, profile
bytes, or identifiers outside the sandbox; the only network surfaces are
the user-initiated repository health probe and downloads
([PRIVACY.md](../../PRIVACY.md)); no analytics, no telemetry, no crash
reporting SDK exists in the binary (WHAT_DOES_NOT_EXIST.md, *3 never*).

## Verdict

**Security lockdown complete.** No sensitive information can leak through
normal workflows at the verified level. Open security-adjacent items are
the Medium-1 scope item (packaging/extraction review) and High-2 (device
evidence) in the [blocker audit](../audits/2026-09-26-rc3-release-blocker-audit.md);
neither is a Critical blocker, and both are scheduled before Stable.
