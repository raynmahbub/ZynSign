# Private Test Build — ZynSign (every stop on the release train)

> Test privately, publish publicly. No tag is pushed public until the private build is green on your devices.

This document is the single checklist for the **private test** that gates every release on the [release train](release-train.md). The current candidate is whatever `python3 Scripts/release_train.py current --tag` prints. Never retype it: read it from the train, so this document cannot drift from the code — the version once written into this sentence outlived the stop it named, which is the drift the rule exists to prevent. It is the professional way to ship: internal → external, with the same binary discipline.

## Release train scope

Each release on the [release train](release-train.md) switches on more of the
finished app. Test the **Release configuration**, which shows exactly
`ReleaseTrain.current`. For each release:

1. Check Settings → Diagnostics → Build → **Release** shows the expected tag
   (for example `v0.1.0-alpha.3 · 10 of 19 staged features`). That string is
   `ReleaseGate.summary`, derived from the train — never retype it here.
2. Run the matrix rows for the features visible in this release. For a
   development stop (`v0.0.1-dev.1` through `v0.0.1`, none of which introduces a
   staged `ReleaseFeature`) that is the **core only**: Import,
   Library, Files, Bundle Explorer, Home, the honest rows, and Diagnostics.
   An alpha or beta stop adds every feature the train shows as visible; run
   those rows too — a stop that introduces a feature owes it a private test.
3. Confirm that features not yet released are **absent**: no App Store or
   Downloads tab, no Certificates row, no “Sign Application…”, no Mission Control
   card, no “Deliver…”, and no Activity Journal.
4. Re-run the rows for previously released features as a regression check.

Rows for features shipping later (Certificate, Smart Sign, Repository health,
Downloads, Mission Control, delivery hand-off, journal) become required in the
release that switches them on.

## Principle

* **Private build = same code, same version, no public tag.** It is built from `main` at the commit you intend to publish (the release-train state you are about to tag), carrying the `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` that `python3 Scripts/release_train.py status` prints for the current stop — for `v0.1.0-alpha.3` that is market `0.1.0`, build `2` — but distributed only to your trusted testers.
* **Public build = same commit, same binary, new tag.** After private green, you push the current stop's tag and `🚀 Release` publishes the GitHub release. The market version does not change between private and public — the build is not rebuilt to avoid binary drift.

## When to run

Before any public tag on the train. Private testing is **required** for every candidate because the app touches the signing pipeline, Keychain, `BackgroundURLSession`, and `ActivityKit`.

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

1. **Apple Developer → App Store Connect → My Apps → ZynSign → TestFlight → Internal Testing** → create group `ZynSign Internal` → add your Apple IDs.
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

4. **TestFlight → Internal Testing → ZynSign Internal → select build 0.0.1 (1)** → `Add Testers`.

No external review, no public page, no public tag yet.

## Private test matrix (do not skip)

Test on **two real devices**: one iOS 17 (e.g., iPhone 13) + one iOS 18 (e.g., iPhone 15 Pro), plus Simulator smoke. Each row must be green before public.

| Area | Action | Pass if |
|---|---|---|
| **Import** | Pick `app.ipa` + `app.tipa` (50-200 MB) three ways — the Import Hub's own button, Files → ⌄ → *Import*, and a share sheet / *Open In* from the Files app — plus a >500 MB package | Each way opens the Import Hub (the picker appears after the sheet settles, never silently), the item reaches *Ready to Import*, **Add to Library** stores it, `Library` shows `isArtifactAvailable`; a hand-off from another app opens the hub once ZynSign is in the foreground |
| **Library** | Re-launch, check `isArtifactAvailable`, `Explore IPA`, open one file, delete | Persists across kill, tree and stats match the package, the preview does not modify it, orphan sweep works |
| **Certificates** | `Settings → Signing → Certificates → Import` a real `.p12` / `.pfx` with its password, then the wrong password, then the same file again | The password sheet appears after the picker closes; the identity lists with `ZStatusBadge ready` and can sign; *Export public JSON* shares; wrong password → `authorizationFailure`; the second import is refused as a duplicate. **Protection is read from the Keychain, not assumed**: `WhenUnlockedThisDeviceOnly` where the platform accepts the importer's upgrade request, the Keychain's default `WhenUnlocked` where it does not — both are unreadable while the device is locked, which is the requirement. An identity that arrives but shows *unsupported* is the case to report, with the exact status |
| **Smart Sign** | `Library → Sign` with real cert + `.mobileprovision` (derive `N keys` preview) + `DER 0x20400` on/off + empty profile (should refuse at `profile` stage) | 9 stages → `Documents/Signed/*_signed.ipa` `Share`, `ZProgressRing` + `ZSigningStatusMachine` + Live Activity in-app badge, refusal `Refused at profile` no container |
| **Repository** | `App Store → Add Source` `https://qnblackcat.github.io/AltStore/apps.json` + bad URL → `Check Health` | `Fast <800ms` / `Slow` / `Offline` + `ms` + `ZStatusBadge`, bad URL → `Offline` |
| **Downloads** | Add `https://…/app.ipa` on device (LTE), lock, `Pause` → `Resume` → `Cancel`, kill app mid-download, relaunch | Background `com.zynsign.downloads` resumes, `Retry ×3`, survives backgrounding |
| **Mission Control** | `Home → Refresh Everything` (repeat 3×), check `tmp` + `Downloads` pruning | Report `Completed` + `N sources` + `N apps` + `N cleaned` + `ms`, no re-sign auto-triggered |
| **Bundle Explorer** | Library → an imported app → *View Bundle* (and Sign → *Explore IPA*), then open a file and a nested folder in the tree | The explorer opens without a force close on phone and iPad, and its details push rather than nesting a second navigation container. This row exists because the failure it guards is invisible to the static audits: the pushed screen was correct on its own and the screen it built owned a `NavigationStack`, which is a runtime crash. `audit_navigation_stack.py` now follows that construction chain, and this row is where the fix is confirmed on a device |
| **Shell & Settings** | Open every tab — the bar should show Files, Library, Home, Store, Downloads, Features, Settings where the stage exposes them — then `Settings` and each of its ten categories | Every destination the build exposes has its own tab, `Settings` opens its category list with no force close, and no tab is reached through a system *More* list. This row exists because the failure it guards is invisible to the static audits: UIKit's own bar draws five items and folds the rest into a *More* list it **pushes**, and a pushed tab view that owns a `NavigationStack` (`RootView.tabContent`) crashes at runtime. The shell draws its own bar (`ShellTabBar`) so that ceiling decides nothing; if a build ever shows a tab inside a *More* list, or a destination the stage exposes has no tab, the build has the bug this row catches |
| **Honest screens** | `Settings → Installation` / `Pairing` / `Analytics` | `Unavailable` `Never` `None` + typed `InstallationLimitation`/`PairingLimitation`/`Guarantee` + `ZStatusBadge`; Installation screen describes the delivery hand-off; Pairing screen renders feasibility notes + ADR anchors |
| **Deliver hand-off** | Sign a package → `Deliver…` → enter a real HTTPS host → build manifest | `manifest.plist` + `itms-services://…` link + QR generated; `http://`/`file://` refused with a typed error; proxy shows **no** traffic from ZynSign |
| **Analytics journal** | Exercise import / sign / download → `Settings → Analytics` | Counts + recent activity appear; toggle off stops recording; Clear + Export work; proxy shows **no** outbound traffic |
| **Diagnostics** | `Settings → Diagnostics & Logs` | Redacted, no key/profile bytes, no `AnalyticsKit` traffic (Charles proxy shows none) |

Log results in `docs/releases/private-testing.md` (append a dated table) — the private build is green only when the matrix is all green.

## From private green to public publish

1. **Do not rebuild.** The public release is the *same commit* you privately tested — `main` HEAD, carrying the market version and build number that `python3 Scripts/release_train.py status` prints.
2. **Changelog and notes ready?** `CHANGELOG.md` must have a section for the version you are about to tag, and `docs/releases/notes-v{version}.md` should exist. `Scripts/ci/release_validate.sh` checks both: a missing section or notes file is a warning and `🚀 Release` will generate one, but a release that skips the changelog is a process error, so write them.
3. **Tag and publish (one tag after green):**

```sh
TAG="$(python3 Scripts/release_train.py current --tag)"
git tag -a "$TAG" -m "ZynSign ${TAG#v} (private-tested)" HEAD
git push origin "$TAG"
```

   Pushing the tag is the whole manual step. `🚀 Release` then runs the quality gate, builds and tests, generates `ZynSign-v{tag}-unsigned.ipa`, `ZynSign-v{tag}-SHA256.txt`, `BuildPassport-v{tag}.json`, `MANIFEST.md` and `ReleaseNotes.md`, and publishes the GitHub release. Rehearse it first with Actions → 🚀 Release → `dry_run: true`. Do **not** hand-run `gh release create` for a train stop — that is how a release ends up carrying assets no gate produced.

4. **Market version is already correct:** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `ZynSign.xcodeproj/project.pbxproj` are written by the train (`0.0.1` / `1` for `v0.0.1-dev.1`). For the next stop, `python3 Scripts/release_train.py promote` sets `ReleaseTrain.current` and `MARKETING_VERSION`, and bumps `CURRENT_PROJECT_VERSION` +1.

## ExportOptions templates

Two plists live in `docs/releases/`:

* `ExportOptions-private-adhoc.plist` — `method: ad-hoc` — for DM sideload IPA.
* `ExportOptions-private-appstore.plist` — `method: app-store` — for TestFlight internal.

Both set `teamID: YOUR_TEAM_ID` (replace), `compileBitcode: false`, `signingStyle: automatic`.

## CI help

`.github/workflows/01-build.yml` in `mode: private-ipa` builds `Release` on `macos-15` for `iphoneos`, after the same hygiene, build and unit-test gates every commit gets, and uploads `ZynSign-v{tag}-Release-private.ipa` as a **private** workflow artifact (`retention-days: 7`, not a release). Trigger: `workflow_dispatch` on the commit you intend to tag (normally `main`), with configuration **Release**. The version in the artifact name comes from `Scripts/release_train.py current --tag`, never from a typed value. Debug exposes every feature regardless of the release train, so it is not release evidence.

## Checklist before you push the tag public

- [ ] Private matrix all green on 2 real devices (log appended below) — the rows for the features this stop exposes
- [ ] `Product → Archive` succeeds (Release, with the `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` that `release_train.py status` prints)
- [ ] `Diagnostics` redacted, `Settings → Analytics` off-device `0 events sent` + 6 guarantees, journal Clear/Export work, Charles shows no telemetry
- [ ] `CHANGELOG.md` has a section for this version, `python3 Scripts/update_readme.py --check` is green, `WHAT_DOES_NOT_EXIST.md` counts match the README badge (`10 wired · 3 never`)
- [ ] No `/.ai/`, no `Generated by`, no private keys in `git diff`
- [ ] Tag annotated and taken from `release_train.py current --tag`; publishing is left to `🚀 Release`, never to a hand-run `gh release create`

---

### Private test log (append here)

| Date (Asia/Dhaka) | Tester | Devices (iOS) | Build (`market (build)`) | Result | Notes |
|---|---|---|---|---|---|
| 2026-09-25 | _you_ | iPhone — / iPhone — | `HEAD` | ☐ green / ☐ needs fix |  |
