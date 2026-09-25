# Private Test Build — ZynSign 0.1.0 Horizon

> Test privately, publish publicly. No tag is pushed public until the private build is green on your devices.

This document is the single checklist for the **private test** that gates the first public dev build. It is the professional way to ship: internal → external, with the same binary discipline.

## Release train scope

Each release on the [release train](release-train.md) switches on more of the
finished app. Test the **Release configuration**, which shows exactly
`ReleaseTrain.current`. For each release:

1. Check Settings → Diagnostics → Build → **Release** shows the expected tag
   (for example `v0.1.0 · 0 of 7 staged features`).
2. Run the matrix rows for features visible in this release. For `v0.1.0` that
   means Import, Library, Bundle Explorer, Files, Home, Settings, Diagnostics,
   and the honest Pairing/Analytics screens.
3. Confirm that features not yet released are **absent**: no App Store or
   Downloads tab, no Certificates row, no “Sign Application…”, no Mission Control
   card, no “Deliver…”, and no Activity Journal.
4. Re-run the rows for previously released features as a regression check.

Rows for features shipping later (Certificate, Smart Sign, Repository health,
Downloads, Mission Control, delivery hand-off, journal) become required in the
release that switches them on.

## Principle

* **Private build = same code, same version, no public tag.** It is built from `main` at the commit you intend to publish (Horizon `58e604c` + installation delivery hand-off, local activity journal, pairing/JIT/mux ADR; market `0.1.0` build `4`), with `MARKETING_VERSION 0.1.0` `CURRENT_PROJECT_VERSION 4`, but distributed only to your trusted testers.
* **Public build = same commit, same binary, new tag.** After private green, you push `v0.1.0` and publish the GitHub release. The market version does not change between private and public — the build is not rebuilt to avoid binary drift.

## When to run

Before any `v0.1.0` public tag. Private testing is **required** for 0.1.0 Horizon because it touches the signing pipeline, Keychain, `BackgroundURLSession`, and `ActivityKit`.

## Private build channels (pick one, or both)

### A — Ad-hoc IPA (sideload, no App Store Connect)

Fastest, no Apple review, stays off TestFlight.

```sh
# 1 — Clean, archive, export ad-hoc
xcodebuild clean archive -project ZynSign.xcodeproj -scheme ZynSign -configuration Release \
  -archivePath build/ZynSign-private.xcarchive \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=YOUR_TEAM_ID

xcodebuild -exportArchive -archivePath build/ZynSign-private.xcarchive \
  -exportPath build/private -exportOptionsPlist docs/releases/ExportOptions-private-adhoc.plist

# ExportOptions-private-adhoc.plist → method: ad-hoc, teamID, compileBitcode: false
# Result: build/private/ZynSign.ipa  (install via AltStore / Sideloadly / Apple Configurator)
```

*Share* `build/private/ZynSign.ipa` only in your private channel (DM / private TestFlight group is fine, public release is not). The IPA is not uploaded as a public GitHub release asset.

### B — TestFlight Internal (recommended for professional)

Private, review-free for internal testers, same binary review as public later.

1. **Apple Developer → App Store Connect → My Apps → ZynSign → TestFlight → Internal Testing** → create group `Horizon Private` → add your Apple IDs.
2. **Archive for App Store** (same as above but `method: app-store`):

```sh
xcodebuild clean archive -project ZynSign.xcodeproj -scheme ZynSign -configuration Release \
  -archivePath build/ZynSign-private.xcarchive

xcodebuild -exportArchive -archivePath build/ZynSign-private.xcarchive \
  -exportPath build/private-appstore -exportOptionsPlist docs/releases/ExportOptions-private-appstore.plist
# ExportOptions-private-appstore.plist → method: app-store
```

3. **Upload with Transporter / Xcode Organizer** (or `xcrun altool` / `notarytool` is for macOS; for iOS use Organizer or `fastlane pilot`):

```sh
xcrun altool --upload-app -f build/private-appstore/ZynSign.ipa -t ios -u YOUR_APPLE_ID
# or: fastlane pilot upload --ipa build/private-appstore/ZynSign.ipa --distribute_external false
```

4. **TestFlight → Internal Testing → Horizon Private → select build 0.1.0 (3)** → `Add Testers`.

No external review, no public page, no `v0.1.0` tag yet.

## Private test matrix (do not skip)

Test on **two real devices**: one iOS 17 (e.g., iPhone 13) + one iOS 18 (e.g., iPhone 15 Pro), plus Simulator smoke. Each row must be green before public.

| Area | Action | Pass if |
|---|---|---|
| **Import** | Files → pick `app.ipa` + `app.tipa` (50-200 MB), also a >500 MB | Staged, SHA-256 deduped, `Library` shows `isArtifactAvailable`, background `Downloads` handles `itms-services` |
| **Library** | Re-launch, check `isArtifactAvailable`, `Explore Bundle`, delete | Persists across kill, read-only listing correct, orphan sweep works |
| **Certificates** | `Settings → Certificates → Import` `.p12` 10 MiB + wrong password + duplicate | `WhenUnlockedThisDeviceOnly` + `ZStatusBadge ready/needsAttention`, `Export public JSON` shares, wrong password → `authorizationFailure`, duplicate → rejected |
| **Smart Sign** | `Library → Sign` with real cert + `.mobileprovision` (derive `N keys` preview) + `DER 0x20400` on/off + empty profile (should refuse at `profile` stage) | 9 stages → `Documents/Signed/*_signed.ipa` `Share`, `ZProgressRing` + `ZSigningStatusMachine` + Live Activity in-app badge, refusal `Refused at profile` no container |
| **Repository** | `App Store → Add Source` `https://qnblackcat.github.io/AltStore/apps.json` + bad URL → `Check Health` | `Fast <800ms` / `Slow` / `Offline` + `ms` + `ZStatusBadge`, bad URL → `Offline` |
| **Downloads** | Add `https://…/app.ipa` on device (LTE), lock, `Pause` → `Resume` → `Cancel`, kill app mid-download, relaunch | Background `com.zynsign.downloads` resumes, `Retry ×3`, survives backgrounding |
| **Mission Control** | `Home → Refresh Everything` (repeat 3×), check `tmp` + `Downloads` pruning | Report `Completed` + `N sources` + `N apps` + `N cleaned` + `ms`, no re-sign auto-triggered |
| **Honest screens** | `Settings → Installation` / `Pairing` / `Analytics` | `Unavailable` `Never` `None` + typed `InstallationLimitation`/`PairingLimitation`/`Guarantee` + `ZStatusBadge`; Installation screen describes the delivery hand-off; Pairing screen renders feasibility notes + ADR anchors |
| **Deliver hand-off** | Sign a package → `Deliver…` → enter a real HTTPS host → build manifest | `manifest.plist` + `itms-services://…` link + QR generated; `http://`/`file://` refused with a typed error; proxy shows **no** traffic from ZynSign |
| **Analytics journal** | Exercise import / sign / download → `Settings → Analytics` | Counts + recent activity appear; toggle off stops recording; Clear + Export work; proxy shows **no** outbound traffic |
| **Diagnostics** | `Settings → Diagnostics & Logs` | Redacted, no key/profile bytes, no `AnalyticsKit` traffic (Charles proxy shows none) |

Log results in `docs/releases/private-testing.md` (append a dated table) — the private build is green only when the matrix is all green.

## From private green to public publish

1. **Do not rebuild.** The public release is the *same commit* you privately tested (today: `arena/01a0d570-zynsign` HEAD — Horizon + hand-off/journal/ADR, `0.1.0`/`4`).
2. **Changelog ready?** `CHANGELOG.md` `0.1.0` must match the binary you tested (hand-off, journal, ADR included; notes at `docs/releases/notes-v0.1.0.md`).
3. **Tag and publish (one command after green):**

```sh
git tag -a v0.1.0 -m "ZynSign 0.1.0 Horizon — first public dev (private-tested)" HEAD
git push origin tag v0.1.0
gh release create v0.1.0 --target arena/01a0d570-zynsign \
  --title "ZynSign 0.1.0 Horizon — first public dev" \
  --notes-file docs/releases/notes-v0.1.0.md
# Attach the *same* IPA you privately tested only if you want an asset — otherwise sideload/TestFlight is the distribution
```

4. **Market version is already correct:** `MARKETING_VERSION 0.1.0` `CURRENT_PROJECT_VERSION 4` (`ZynSign.xcodeproj/project.pbxproj` …). For the next build, bump `CURRENT_PROJECT_VERSION` +1 (→ `5`); for next feature, bump `MARKETING_VERSION` per `version-strategy.md`.

## ExportOptions templates

Two plists live in `docs/releases/`:

* `ExportOptions-private-adhoc.plist` — `method: ad-hoc` — for DM sideload IPA.
* `ExportOptions-private-appstore.plist` — `method: app-store` — for TestFlight internal.

Both set `teamID: YOUR_TEAM_ID` (replace), `compileBitcode: false`, `signingStyle: automatic`.

## CI help

`.github/workflows/private-test-build.yml` builds `Release` on `macos-15` for `iphoneos`/`iphonesimulator`, runs `ci.yml` hygiene + `external_validation.py self-test`, and uploads `ZynSign-private.ipa` as a **private** workflow artifact (`retention-days: 7`, not a release). Trigger: `workflow_dispatch` on `arena/01a0d570-zynsign` only — never on `main`.

## Checklist before you push `v0.1.0` public

- [ ] Private matrix all green on 2 real devices (log appended below)
- [ ] `Product → Archive` succeeds (Release, `MARKETING_VERSION 0.1.0` `CURRENT_PROJECT_VERSION 3`)
- [ ] `Diagnostics` redacted, `Settings → Analytics` off-device `0 events sent` + 6 guarantees, journal Clear/Export work, Charles shows no telemetry
- [ ] `CHANGELOG.md` `0.1.0` matches binary, `README.md` `0.1.0` badges, `WHAT_DOES_NOT_EXIST.md` `9 wired · 3 never`
- [ ] No `/.ai/`, no `Generated by`, no private keys in `git diff`
- [ ] Tag `v0.1.0` annotated, `gh release` `--target arena/01a0d570-zynsign`

---

### Private test log (append here)

| Date (Asia/Dhaka) | Tester | Devices (iOS) | Build `0.1.0 (3)` | Result | Notes |
|---|---|---|---|---|---|
| 2026-09-25 | _you_ | iPhone — / iPhone — | `HEAD` | ☐ green / ☐ needs fix |  |
