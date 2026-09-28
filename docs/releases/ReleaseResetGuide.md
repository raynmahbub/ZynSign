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

The recommendation: **delete the three pre-launch releases and tags once,
then start fresh at `v0.1.0-dev.1`.** Keeping them is also a valid
decision — the automation works either way — but the version ordering
noise remains until they are removed.

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

The release train check must stay green — the train
(`ZynSign/Application/ReleaseTrain.swift` /
`Scripts/release_train.py`) is untouched by this cleanup.

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
  `.github/workflows/release.yml` (channel detection), so `latest`
  always points at the newest stable.
- **Release Drafter works perfectly** — the version resolver maps merged
  labels to the next `-dev.N` / patch / minor.
- **CI detects channels automatically** — `BuildInfo.json` records
  `releaseChannel` from the tag.
- **Rollbacks stay clean** — each tag is immutable; re-publishing means a
  new tag (`-dev.2`), never a moved tag.
- **Industry-standard SemVer** — order, comparison, and tooling all agree.

The release train remains the source of truth for *which features* each
tag switches on ([release-train.md](release-train.md)); the structure
above governs the *version numbers*. `Scripts/ci/release_validate.sh`
refuses any tag that disagrees with the train.

## Step 4 — Ship the first fresh release

```sh
python3 Scripts/release_train.py status     # confirm the current stage
# …private test first (docs/releases/private-testing.md)…
# run the preflight: Actions → Prerelease Preflight → version 0.1.0-dev.1
git tag -a v0.1.0-dev.1 -m "ZynSign 0.1.0-dev.1" && git push origin v0.1.0-dev.1
```

The tag triggers `release.yml`: quality gate → build + tests → assets
(`ZynSign.ipa`, `ZynSign.sha256`, `BuildInfo.json`, `ReleaseNotes.md`) →
publish. See [release-automation.md](release-automation.md).

## Notes

- Deleting a release does not delete any commit; the history stays intact.
- Anyone who installed a pre-launch build keeps it; the next fresh build
  simply has a new version.
- This guide lives at `docs/releases/ReleaseResetGuide.md`
  (repository convention keeps this directory lowercase).
