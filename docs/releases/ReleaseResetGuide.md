# Release Reset Guide

_How to retire the pre-launch releases and start the permanent release
structure. Every step is manual and reversible —
**nothing here is ever deleted automatically**._

## Why this guide exists

Three GitHub releases were published during early pre-launch development:

| Tag | Title | Published |
| --- | --- | --- |
| `v0.1.0-dev` | ZynSign 0.1.0-dev Genesis + 0.1.1 Real entitlements | 2026-09-24 |
| `v0.1.1-dev` | ZynSign 0.1.1-dev Real entitlements (1/10) | 2026-09-24 |
| `v0.2.0-dev` | ZynSign 0.2.0-dev Horizon — first dev build | 2026-09-24 |

They belong to the pre-launch era, before the engineering-excellence
release system existed. They do not fit the permanent release
structure below, and their version numbers collide with it (`v0.2.0-dev`
is ahead of `v0.1.0-dev.1` in SemVer ordering, which confuses Release
Drafter's version resolver and `latest` detection).

The reset was **executed on 2026-09-29**: the three pre-launch releases and
their tags were deleted, and the train restarted at `v0.1.0-dev.1`. The steps
below are kept as the record of what was done, and as the procedure for any
future reset.

## Step 1 — Delete the releases

Each command deletes the GitHub Release **and** its tag (`--cleanup-tag`).

```sh
gh release delete v0.2.0-dev --cleanup-tag --yes
gh release delete v0.1.1-dev --cleanup-tag --yes
gh release delete v0.1.0-dev --cleanup-tag --yes
```

Prefer to delete releases and tags separately (for review):

```sh
gh release delete v0.2.0-dev --yes
git push --delete origin v0.2.0-dev
git tag -d v0.2.0-dev 2>/dev/null || true
# repeat for v0.1.1-dev and v0.1.0-dev
```

## Step 2 — Verify the cleanup

```sh
gh release list                       # expect: empty
git ls-remote --tags origin           # expect: no v0.1.x-dev / v0.2.x-dev tags
python3 Scripts/release_train.py check
```

Deleting releases never touches the train
(`ZynSign/Application/ReleaseTrain.swift` /
`Scripts/release_train.py`), so this check stays green through step 2.

Starting fresh at `v0.1.0-dev.1` **did** need one train change, and it is the
part of this guide that was not obvious until it was attempted: the train had
no development stop, so `Scripts/ci/release_meta.sh` and
`Scripts/ci/release_validate.sh` refused the tag even though
`release_meta.sh` already knew the `development` channel (its self-test asserts
`channel_for 0.1.0-dev.1` → `development`). Step 4 was therefore unexecutable
until the train gained the phase step 3 describes.

What changed on 2026-09-29:

- `ReleaseStage` gained `.dev1`, `.dev2`, `.dev3` (`0.1.0-dev.1…3`) ahead of
  `.horizon`, each with an empty `introducedFeatures` — a development stop
  proves the pipeline and exposes no staged feature.
- `ReleaseTrain.current` moved `.rc2` → `.dev1`.
- `MARKETING_VERSION` `1.0.0` → `0.1.0`; `CURRENT_PROJECT_VERSION` `5` → `1`
  (a new marketing version restarts the build number, which is what
  TestFlight's monotonic-build rule is scoped to).
- `ReleaseTrainTests` gained the three stops and
  `testTheResetKeptTheWholeFeaturePlanIntact`.

The **feature plan was not rewritten.** Every stage after Development keeps
exactly the features it always had, so `promote` switches them back on in the
planned order; a Debug build exposes all of them throughout, and
`-ZynSignReleaseStage <stage>` previews any stop. Nothing built was given up to
restart the version numbers.

## Step 3 — Start fresh with the permanent structure

Recommended progression from here to stable, and beyond:

| Stage | Versions |
| --- | --- |
| Development | `v0.1.0-dev.1` → `v0.1.0-dev.2` → `v0.1.0-dev.3` |
| Alpha | `v0.1.0-alpha.1` → `v0.1.0-alpha.2` → `v0.1.0-alpha.3` |
| Beta | `v0.9.0-beta.1` → `v0.9.0-beta.2` |
| Release Candidate | `v1.0.0-rc.1` → `v1.0.0-rc.2` |
| Stable | `v1.0.0` |
| After stable | `v1.0.1` (patch) · `v1.1.0` (minor) · `v2.0.0` (major) |

Why this structure:

- **GitHub understands prereleases.** `-dev`, `-alpha`, `-beta`, `-rc`
  suffixes are flagged `--prerelease` automatically by
  `.github/workflows/03-release.yml` (channel detection), so `latest`
  always points at the newest stable.
- **Release Drafter works perfectly** — the version resolver maps merged
  labels to the next `-dev.N` / patch / minor.
- **CI detects channels automatically** — the Build Passport records
  `releaseChannel` from the tag.
- **Rollbacks stay clean** — each tag is immutable; re-publishing means a
  new tag (`-dev.2`), never a moved tag.
- **Industry-standard SemVer** — order, comparison, and tooling all agree.

The release train remains the source of truth for *which features* each
tag switches on ([release-train.md](release-train.md)); the structure
above governs the *version numbers*. `Scripts/ci/release_meta.sh` refuses
any version that disagrees with the train in the first job of both release
workflows, and `Scripts/ci/release_validate.sh` re-checks it in the quality
gate.

## Step 4 — Ship the first fresh release

```sh
python3 Scripts/release_train.py status     # confirm the current stage
python3 Scripts/release_train.py current    # the version the workflows will use
# …private test first (docs/releases/private-testing.md)…
# rehearse it: Actions → 🚀 Release → dry_run: true, version left empty —
# Scripts/ci/release_meta.sh takes the current stop from the train, and a
# typed version is rejected unless it is that stop
git tag -a v0.1.0-dev.1 -m "ZynSign 0.1.0-dev.1" && git push origin v0.1.0-dev.1
```

The tag triggers `03-release.yml`: quality gate → build + tests → assets
(`ZynSign-v{tag}-unsigned.ipa`, `ZynSign-v{tag}-SHA256.txt`,
`BuildPassport-v{tag}.json`, `MANIFEST.md`, `ReleaseNotes.md`) →
publish. See [release-automation.md](release-automation.md).

## Notes

- Deleting a release does not delete any commit; the history stays intact.
- Anyone who installed a pre-launch build keeps it; the next fresh build
  simply has a new version.
- This guide lives at `docs/releases/ReleaseResetGuide.md`
  (repository convention keeps this directory lowercase).
