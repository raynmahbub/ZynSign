<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../Assets/Brand/Logo/logo-lockup-dark.svg">
    <img src="../../Assets/Brand/Logo/logo-lockup.svg" alt="ZynSign" width="260">
  </picture>
</p>

# Release Documentation

The release process for ZynSign — private test first, public tag second.

## Current State

**Current stop: `v0.0.1-dev.2`, next stop `v0.0.1-dev.3`, `10 wired · 3 never`** — a development stop switches on no staged `ReleaseFeature` of its own, but that is not "the core only": a Release build shows the whole six-tab shell and the certificate, profile, repository and download surfaces behind it, because holding those back made the app look broken. What stays gated is the staged *work* — signing, presets, the queue, identity, installation, the workspace, Nova — and the gate map in [release-train.md](release-train.md) lists which checks are live. This stop exists to prove the pipeline and the core, not to ship features. ZynSign is an on-device iOS signing app: import an application package, inspect it, sign it with your own certificate and profile, and hand off the result — inside the app sandbox, with no desktop helper, no remote service and no analytics. The whole app is built: the six-surface shell (Files / Library / Home / App Store / Downloads / Settings), import, Library, Certificate Studio (`.p12` + public-JSON export), Smart Sign (9 stages, CMS-derived entitlements, DER `0x20400` toggle, Live Activity), repository health Fast / Slow / Offline, resumable Download Center, the **Entitlements Studio** and the **Developer Identity Center**, and the Compatibility Lab — with Mission Control Refresh, the **installation delivery hand-off (OTA manifest + install link + QR + operator guides)** and the **local activity journal (on-device, never transmitted)** compiled in and reachable in Debug, switching on at `beta1` — composed via `CompositionRoot`, with `SigningState` / `ZynSignError` + `ZToast` exactly as built.

An alpha stop **exposes the features its stage and every earlier stage introduce**: `v0.1.0-alpha.3` shows the core plus Smart Sign, the Signing Queue, Signing Presets, the Entitlements Studio and the Identity Center — while Certificate Studio, the Profile Manager, the App Store and the Download Center are already reachable in a Release build, because the `dev.3` shell change removed their last checks. That is the drift the train has to settle: either those four move to `v0.0.1`, or the gates go back on. The tab bar stays complete at every stop and saved landing preferences remain valid. Debug builds expose everything, so development is never blocked, and each later stop switches its features on in the planned order ([release-train.md](release-train.md)). The honest rows stay honest per [WHAT_DOES_NOT_EXIST.md](../product/WHAT_DOES_NOT_EXIST.md): in-app installation, Pairing/JIT/Mux, and off-device measurement are claimed-never (pairing via `docs/architecture/pairing-jit-mux-feasibility.md`).

The numbers are never written into prose here on purpose: run `python3 Scripts/release_train.py status` for the declared stop, its marketing version and build number, and `python3 Scripts/release_train.py check` to confirm the tag matches. The private binary and the public release are the same binary — no rebuild between private and public.

- The engineering-excellence release system gates and publishes every tag automatically — see [release-automation.md](release-automation.md). One tag is the whole manual step, and `dry_run: true` rehearses it.
- `docs/releases/notes-v<version>.md` is the file the published Release uses, and `Scripts/generate_changelog.py` promotes a curated `CHANGELOG.md` `[Unreleased]` entry into the release section without touching that notes file. Write the note before the tag; the pipeline will not write it for you.
- The build is not signed for the App Store. Distribution is sideloading / TestFlight only; installation on iOS/iPadOS remains unavailable per [installation-compatibility.md](../architecture/installation-compatibility.md).
- See [CHANGELOG.md](../../CHANGELOG.md) and [version-strategy.md](version-strategy.md) for exactly what is claimed.

## Release train

The app is fully built but ships one release at a time. `v0.0.1-dev.1` opened the core, `v0.0.1-dev.2` released with the gate closing on four entry points, and `v0.0.1-dev.3` — the last rehearsal before `v0.0.1` — is next. See **[release-train.md](release-train.md)** for the plan and the per-release commands. Everything below applies to every release on the train: private test first, same binary public.

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

For TestFlight internal, use `ExportOptions-private-appstore.plist` (`method: app-store`) and upload via Xcode Organizer — add testers to group `ZynSign Internal` (no external review). Templates live in [`ExportOptions-private-adhoc.plist`](ExportOptions-private-adhoc.plist) and [`ExportOptions-private-appstore.plist`](ExportOptions-private-appstore.plist) (`teamID: YOUR_TEAM_ID`).

Or trigger `.github/workflows/01-build.yml` manually (`workflow_dispatch` → `mode: private-ipa`, configuration **Release**) — the hygiene, build and test gates run first, then it archives and exports the ad-hoc IPA and uploads it as a workflow artifact (retention 7 days, **not** a release).

**Step 2 — Private test matrix.** See [private-testing.md](private-testing.md). Run the rows for the features the current stop *exposes* — for `v0.0.1-dev.2` that is the core only (Import / Library / Files / Bundle Explorer / Home / the honest rows / Diagnostics). No staged feature row is in scope until `v0.1.0-alpha.1`. All green on two real devices (one iOS 17, one iOS 18) plus simulator smoke. Log the result in that file.

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
- Market version (`CFBundleShortVersionString`) stays numeric on every stop — `0.0.1` for the development stops and the first build, `0.1.0` for the alphas, `0.9.0` for the betas, `1.0.0` for the RCs — with the pre-release suffix living only in the tag, as Apple expects.
- Build number (`CFBundleVersion`) bumps by 1 per release (`Scripts/release_train.py promote` does it) and restarts at `1` when the market version restarts, which is what TestFlight's monotonic-build rule is scoped to. `python3 Scripts/release_train.py status` prints the current pair; `ApplicationInfo.current` reads both and is covered by hygiene.

## Index

- [Checklist.md](Checklist.md) — the release gate, in order: train consistency, bookkeeping, the private matrix, publish, post-tag. An unchecked step blocks.
- [release-train.md](release-train.md) — which features each release switches on, and how to promote / check / tag.

- [version-strategy.md](version-strategy.md) — the development → alpha →
  beta → release-candidate → stable progression, exit criteria, and the
  current position (`v0.0.1-dev.2`, market `0.0.1` build `3`).
- [private-testing.md](private-testing.md) — the private build channels (ad-hoc IPA / TestFlight internal), the device matrix, ExportOptions templates, and the checklist that gates each release on the train.
- [ExportOptions-private-adhoc.plist](ExportOptions-private-adhoc.plist) — `method: ad-hoc` template for DM sideload.
- [ExportOptions-private-appstore.plist](ExportOptions-private-appstore.plist) — `method: app-store` template for TestFlight internal.
- [notes-v0.0.1-dev.1.md](notes-v0.0.1-dev.1.md)
- [screenshots.md](screenshots.md) — the App Store screenshot pack: five screens, two device classes, composed by `Scripts/compose_screenshots.py`. — the release notes the workflow attaches to this stop's GitHub release.
