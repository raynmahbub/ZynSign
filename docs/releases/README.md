<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../Assets/Brand/Logo/logo-lockup-dark.svg">
    <img src="../../Assets/Brand/Logo/logo-lockup.svg" alt="ZynSign" width="260">
  </picture>
</p>

# Release Documentation

The release process for ZynSign — private test first, public tag second.

## Current State

**Current development stop: `v0.1.0-dev.1` (market `0.1.0`, build `1`, 2026-09-29), `10 wired · 3 never`.** The release train restarted at its first development stop ([ReleaseResetGuide.md](ReleaseResetGuide.md)). The whole app is still built: the six-tab shell (Files / Library / Home / App Store / Downloads / Settings), import, Library, Certificate Studio (`.p12` + JSON export), Smart Sign (9 stages, CMS-derived entitlements, DER `0x20400` toggle, Live Activity), repository health Fast / Slow / Offline, resumable Download Center, Mission Control Refresh, **installation delivery hand-off (OTA manifest + install link + QR + operator guides)**, and the **local activity journal (on-device, never transmitted)** — wired via `CompositionRoot`, with `SigningState` / `ZynSignError` + `ZToast` exactly as built, plus the Compatibility Lab and the RC 2 polish pass (unified design system, guided onboarding, bespoke empty states, actionable error views, adaptive iPad layouts).

A development stop **exposes none of those staged features** in a Release build: what a user sees is the core — Files, Import, Library, Bundle Explorer, Home, Settings. Debug builds expose everything, so development is never blocked, and each later stop switches its features on in the planned order ([release-train.md](release-train.md)). The honest rows stay honest per [WHAT_DOES_NOT_EXIST.md](../product/WHAT_DOES_NOT_EXIST.md): in-app installation, Pairing/JIT/Mux, and off-device measurement are claimed-never (pairing via `docs/architecture/pairing-jit-mux-feasibility.md`).

The Xcode project declares `MARKETING_VERSION 0.1.0` `CURRENT_PROJECT_VERSION 1` (`ZynSign.xcodeproj/project.pbxproj`) and `ReleaseTrain.current` is `.dev1` — verify both with `python3 Scripts/release_train.py check`. The private binary and the public release are the same binary — no rebuild between private and public.

- Train history: the train ran `v0.1.0` → the alphas → the betas → `v1.0.0-rc.1` → `v1.0.0-rc.2` before the reset. That work is recorded in this directory's release notes and in `docs/audits/`, and the reset changed none of the code it produced.
- The pre-launch tags `v0.1.0-dev`/`v0.1.1-dev`/`v0.2.0-dev` at `58e604c` were **deleted on 2026-09-29**; the commit stays in history ([release-train.md](release-train.md), “Legacy tags — retired”).
- The engineering-excellence release system gates and publishes every tag automatically — see [release-automation.md](release-automation.md). The reset that started the permanent version structure is recorded in [ReleaseResetGuide.md](ReleaseResetGuide.md).
- The build is not signed for the App Store. Distribution is sideloading / TestFlight only; installation on iOS/iPadOS remains unavailable per [installation-compatibility.md](../architecture/installation-compatibility.md).
- See [CHANGELOG.md](../../CHANGELOG.md) and [version-strategy.md](version-strategy.md) for exactly what is claimed.

## Release train

The app is fully built but ships one release at a time. `0.1.0` shows Files, Import, Library and Bundle Explorer; each later tag switches on more. See **[release-train.md](release-train.md)** for the plan and the per-release commands. Everything below applies to every release on the train: private test first, same binary public.

## Private → Public Gate (how a professional dev release ships)

```
commit HEAD (the train's current stop + private test)  ──►  private build (TestFlight internal / ad-hoc IPA)
                                           private matrix all green (two real devices)
                                           ──►  push the tag → 🚀 Release publishes (assets + notes + changelog)
```

**Step 1 — Build privately (same commit, same version, no tag).** On your Mac:

```sh
xcodebuild clean archive -project ZynSign.xcodeproj -scheme ZynSign -configuration Release \
  -archivePath build/ZynSign-private.xcarchive

xcodebuild -exportArchive -archivePath build/ZynSign-private.xcarchive \
  -exportPath build/private -exportOptionsPlist docs/releases/ExportOptions-private-adhoc.plist
# → build/private/ZynSign.ipa  (install via AltStore / Sideloadly / Apple Configurator)
```

For TestFlight internal, use `ExportOptions-private-appstore.plist` (`method: app-store`) and upload via Xcode Organizer — add testers to group `Horizon Private` (no external review). Templates live in [`ExportOptions-private-adhoc.plist`](ExportOptions-private-adhoc.plist) and [`ExportOptions-private-appstore.plist`](ExportOptions-private-appstore.plist) (`teamID: YOUR_TEAM_ID`).

Or trigger `.github/workflows/01-build.yml` manually (`workflow_dispatch` → `mode: private-ipa`, configuration **Release**) — the hygiene, build and test gates run first, then it archives and exports the ad-hoc IPA and uploads it as a workflow artifact (retention 7 days, **not** a release).

**Step 2 — Private test matrix.** See [private-testing.md](private-testing.md). Run the rows for the features the current stop *exposes* — for `v0.1.0-dev.1` that is the core (Import / Library / Files / Bundle Explorer / Home / the honest rows / Diagnostics); the staged-feature rows belong to the stops that switch them on. All green on two real devices (one iOS 17, one iOS 18) plus simulator smoke. Log the result in that file.

**Step 3 — Publish (one tag after green, no rebuild):**

```sh
TAG="$(python3 Scripts/release_train.py current --tag)"
git tag -a "$TAG" -m "ZynSign ${TAG#v} (private-tested)" HEAD
git push origin "$TAG"
```

That push is the whole manual step, and the tag always comes from the train —
no version is retyped. `.github/workflows/03-release.yml` then runs the quality
gate, builds and tests, generates the version-stamped asset set
(`ZynSign-v{tag}-unsigned.ipa`, `ZynSign-v{tag}-SHA256.txt`,
`BuildPassport-v{tag}.json`, `MANIFEST.md`, `ReleaseNotes.md`), and publishes
the GitHub release using `docs/releases/notes-v{tag}.md` when that file exists —
generating notes and a CHANGELOG entry when it does not. Rehearse the whole
thing first with Actions → 🚀 Release → `dry_run: true`.

The market version does not change between private and public — the build you tested **is** the release.

## Recording Changes

Notable changes are recorded in [CHANGELOG.md](../../CHANGELOG.md) at the
repository root, under `[Unreleased]`, as they are made. That file is the source
of truth for what has changed; this directory documents the process around
turning those changes into a release.

## Conventions

- Document a release process that has actually been performed and verified. Do
  not write it ahead of the first real release.
- Release artifacts must never contain secrets, credentials, private keys,
  provisioning profiles, or user data. See [SECURITY.md](../../SECURITY.md).
- Market version (`CFBundleShortVersionString`) stays numeric on every stop — `0.1.0` for the development stops and the alphas, `0.9.0` for the betas, `1.0.0` for the RCs — with the pre-release suffix living only in the tag, as Apple expects.
- Build number (`CFBundleVersion`) bumps by 1 per release (`Scripts/release_train.py promote` does it) and restarts at `1` when the market version restarts, which is what TestFlight's monotonic-build rule is scoped to. `python3 Scripts/release_train.py status` prints the current pair; `ApplicationInfo.current` reads both and is covered by hygiene.

## Index

- [Checklist.md](Checklist.md) — the release gate, in order: train consistency, bookkeeping, the private matrix, publish, post-tag. An unchecked step blocks.
- [release-train.md](release-train.md) — which features each release switches on, and how to promote / check / tag.

- [version-strategy.md](version-strategy.md) — the development → alpha →
  beta → release-candidate → stable progression, exit criteria, and the
  current position (`v1.0.0-rc.2`, market `1.0.0` build `5`).
- [private-testing.md](private-testing.md) — the private build channels (ad-hoc IPA / TestFlight internal), the device matrix, ExportOptions templates, and the checklist that gates each release on the train.
- [ExportOptions-private-adhoc.plist](ExportOptions-private-adhoc.plist) — `method: ad-hoc` template for DM sideload.
- [ExportOptions-private-appstore.plist](ExportOptions-private-appstore.plist) — `method: app-store` template for TestFlight internal.
- [notes-v1.0.0-rc.1.md](notes-v1.0.0-rc.1.md) · [notes-v1.0.0-rc.2.md](notes-v1.0.0-rc.2.md) — the release-candidate notes the workflow attaches to each GitHub release.
