# ZynSign 1.0.0-rc.1 — Release Candidate

> **Status: PREPARED — NOT PUBLISHED.** This is the release body for the
> `v1.0.0-rc.1` GitHub release. It is published by `release.yml` from the
> release-lock branch only after the gates in
> [qa-signoff-1.0.0-rc.1.md](qa-signoff-1.0.0-rc.1.md) are green and the
> private device matrix passes ([private-testing.md](private-testing.md)).

**Build:** `1.0.0-rc.1` — market `1.0.0` (numeric `CFBundleShortVersionString`),
build number set at cut time, tag `v1.0.0-rc.1`, GitHub **pre-release**.
**Source:** the RC 3 freeze commit on `release/1.0.0-rc3`
([release-lock-rc3.md](release-lock-rc3.md)).

## What is in this release

The complete ZynSign platform — every feature of the train, feature
complete since `v0.9.0-beta.1` and frozen at RC:

- **Import & Library** — Smart Import Hub (multi-select, share sheet, drag
  & drop, duplicate resolution), durable library with collections, smart
  scopes, stackable filters, and instant search; IPA Explorer with bounded
  read-only previews.
- **Certificate Studio** — `.p12`/`.pfx` import to the Keychain
  (`WhenUnlockedThisDeviceOnly`, non-extractable), readiness badges,
  public-metadata JSON export.
- **Provisioning Profile Manager** — import, expiry intelligence,
  five pre-sign compatibility checks, per-app suggestions.
- **Smart Sign** — nine-stage signing engine in an isolated working copy
  with independent verification, profile-derived entitlements, DER
  `0x20400` toggle, Live Activity; Professional Signing Queue; Intelligent
  Signing Presets.
- **Binary & Signature Inspector** — per-executable structure and
  signature verification reports, comparison, and credential-free export.
- **Entitlements Studio** — capability cards, profile comparisons, Smart
  Diagnostics, JSON reports.
- **Store Browser & Download Center** — AltSource feeds with repository
  health, background downloads with pause/resume/retry.
- **Mission Control, Delivery Hand-off, Activity Journal** — one-tap
  maintenance, OTA manifest + QR delivery, on-device journal.
- **Backup & Restore** — certificate public backups, Reset & Recovery,
  interrupted-import restore.

Full change history: [CHANGELOG.md](../../CHANGELOG.md) and
[release-metadata-1.0.0-rc.1.md](release-metadata-1.0.0-rc.1.md).

## Known limitations

- **No in-app installation** of arbitrary IPAs (platform fact,
  `noDeliveryMechanism`). Delivery hand-off helps you install through the
  platform's own routes. See
  [installation-compatibility.md](../architecture/installation-compatibility.md).
- **Pairing/JIT/Mux is never** composed (private entitlements).
- **No off-device analytics** — the activity journal never leaves the
  device.
- **External validation findings:** Apple's desktop `codesign` accepts
  ZynSign's single-image signatures but currently rejects the pipeline's
  full bundle signatures, and the emitted signature format fails Apple's
  documented iOS 15+ rules. Tracked as High (fix before Stable):
  [external-validation.md](../architecture/external-validation.md),
  [blocker audit](../audits/2026-09-26-rc3-release-blocker-audit.md).
- Signing with real developer identities on real devices completes at the
  private device matrix ([private-testing.md](private-testing.md)).

## Upgrade notes

- **From `0.1.0` Horizon train builds (any alpha/beta):** no action
  needed. Library catalogs, collections, preset catalogs, and queue
  journals are forward-compatible (schema 1 converts at read); nothing is
  re-imported and no data migration runs.
- **First install:** import a certificate and profile before signing; the
  wizard refuses to queue jobs until identities are ready.
- **Side-by-side:** installing an RC over an earlier build replaces it
  (same bundle identifier); your library stays.

## Compatibility notes

- **OS:** iOS/iPadOS 17.0+ (deployment target 17.0). iPhone and iPad
  supported; macOS is developer tooling only.
- **Formats:** `.ipa`/`.tipa` packages, `.zip` archives of packages,
  `.p12`/`.pfx` identities (≤ 10 MiB), `.mobileprovision` profiles,
  AltSource `apps.json` feeds, `https` / `itms-services` / `manifest.plist`
  downloads. Bounds: ≤ 100 k entries, depth ≤ 32, 4 MiB inspection reads,
  512 MiB extraction.
- **Distribution:** sideload / TestFlight only. Not an App Store
  submission; not signed for the App Store.
- **DER entitlements** (`0x20400`, slots 5+7) are opt-in for iOS 15+
  targets; default is classic XML slot 5.

## Verification summary

Validated in RC 3: all 12 core workflows end-to-end
([final-validation-rc3.md](../testing/final-validation-rc3.md)), security
lockdown ([rc3-security-lockdown.md](../security/rc3-security-lockdown.md)),
performance and accessibility certification, CI release gate with no
bypass, and the QA sign-off
([qa-signoff-1.0.0-rc.1.md](qa-signoff-1.0.0-rc.1.md)).

Per the release sequence ([stable-release-sequence.md](stable-release-sequence.md)),
this RC is the exact candidate intended for `1.0.0`; a further RC is cut
only for a verified release-blocker fix.
