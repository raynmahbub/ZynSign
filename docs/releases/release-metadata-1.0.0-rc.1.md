# Release Metadata — 1.0.0-rc.1

**Status: PREPARED — DO NOT PUBLISH YET.** These are the release assets
for the `1.0.0-rc.1` candidate. Publishing happens only through
`release.yml` from the protected release-lock branch after the QA sign-off
and the private device matrix.

## Version

| Field | Value |
|---|---|
| Release name | ZynSign 1.0.0-rc.1 — Release Candidate |
| Tag | `v1.0.0-rc.1` (GitHub **pre-release**) |
| `CFBundleShortVersionString` | `1.0.0` (numeric; the `-rc.1` suffix lives only in the tag) |
| `CFBundleVersion` | set at cut time by `Scripts/release_train.py promote` (monotonic; TestFlight requires it) |
| Source | the RC 3 freeze commit on `release/1.0.0-rc3` |
| Release train position | `ReleaseStage.rc1` — fixes only, no new features |
| Configuration | `Release` (exposes exactly `ReleaseTrain.current`) |
| Platform | iOS/iPadOS 17.0+ · iPhone & iPad |
| Bundle identifier | `io.github.davinelion.ZynSign` |
| Distribution | sideload / TestFlight only — not an App Store submission |
| Toolchain | Xcode 16+ (`xcodebuild`), Swift 5.0 language mode |

## Changelog

The authoritative history is [CHANGELOG.md](../../CHANGELOG.md). This
candidate covers the full train from `0.1.0-dev` through the RC 3
freeze: import and library, certificate and profile centers, the signing
engine and queue, entitlements and binary inspection, store browsing and
downloads, mission control and delivery hand-off, backup/recovery, and the
release-readiness infrastructure. The GitHub release body is
[notes-v1.0.0-rc.1.md](notes-v1.0.0-rc.1.md).

## Known Limitations

1. **No in-app installation** of arbitrary IPAs — platform fact
   (`noDeliveryMechanism`); delivery hand-off composes the OTA manifest,
   install link, and QR for user-run installation
   ([installation-compatibility.md](../architecture/installation-compatibility.md)).
2. **Pairing/JIT/Mux is never** composed (would require private
   entitlements; ADR-recorded).
3. **No off-device analytics or telemetry** — by design; the local
   activity journal is never transmitted.
4. **Signature format findings** — Apple's desktop `codesign` accepts
   single-image signatures but rejects the pipeline's bundle signatures,
   and the format fails Apple's documented iOS 15+ rules. High-priority,
   tracked to fix before Stable
   ([external-validation.md](../architecture/external-validation.md)).
5. **Real-device signing evidence** completes at the private device matrix
   before publish ([private-testing.md](private-testing.md)).
6. **Coverage gaps (accepted for RC):** Store Browser, Download Center,
   and export/backup paths lack dedicated behavioral suites
   ([blocker audit](../audits/2026-09-26-rc3-release-blocker-audit.md),
   Medium-2/3 — suites follow in `1.0.1`).

## Upgrade Notes

- **From any `0.1.0` train build (dev/alpha/beta/RC):** in-place upgrade,
  no action. Catalogs (library, collections, presets, queue, journal) are
  schema-versioned and forward-compatible; older schemas convert at read.
  No data is re-imported and no migration step runs.
- **From a side load of a different bundle identifier:** this is a
  separate app; export (library export, certificate JSON backups) and
  re-import if you need to move.
- **Downgrade:** not supported — a schema newer than the build is refused
  at read (fail closed), so keep the newest build once upgraded.
- **TestFlight users:** the build number must strictly increase; use the
  number stamped at cut time.

## Compatibility Notes

- **OS:** iOS/iPadOS 17.0+ (deployment target). iPad supported (drag &
  drop, multi-window standard behavior). macOS is developer tooling only,
  never a runtime.
- **Inputs:** `.ipa`/`.tipa`; `.zip` archives of packages; `.p12`/`.pfx`
  (PKCS#12, ≤ 10 MiB); `.mobileprovision`; AltSource `apps.json` feeds;
  `https`/`itms-services`/`manifest.plist` downloads.
- **Resource bounds:** ≤ 100 000 archive entries · nesting depth ≤ 32 ·
  4 MiB inspection reads · 512 MiB extraction · 10 MiB identity import.
- **Signing output:** deterministic packaging; XML entitlements (slot 5)
  by default; DER entitlements (`0x20400`, slots 5+7) opt-in for iOS 15+
  targets. Signed artifacts are delivered as `Documents/Signed/*.ipa`.
- **Verification claims:** ZynSign's verification is an independent
  on-device re-read of its own output. It is not Apple trust evaluation,
  not App Store acceptance, and not installability (limitation 4 applies).
- **Interoperability:** exports and reports are plain JSON/plist/QR;
  nothing requires another ZynSign install to consume.

## Release assets (prepared, not published)

| Asset | Source | Notes |
|---|---|---|
| GitHub Release `v1.0.0-rc.1` | `release.yml` on tag | Title “ZynSign 1.0.0-rc.1”; body `notes-v1.0.0-rc.1.md`; pre-release |
| CHANGELOG entry `## [1.0.0-rc.1]` | `Scripts/generate_changelog.py` | Auto-committed to the default branch on tag |
| Sideload IPA | private-test build (same commit, no rebuild) | The privately tested binary **is** the release binary |
| This metadata file | repository | Checked by `Scripts/release_gate.py` before publish |
