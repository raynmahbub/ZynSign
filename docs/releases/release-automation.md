# Release Automation

_The engineering-excellence release system: how a tag becomes a
professional release without anyone formatting anything by hand._

## The pipeline

```
                 ┌─────────────────────────────┐
 merged PRs ───► │ Release Drafter drafts the  │  release-drafter.yml
 (labelled)      │ next release notes          │
                 └──────────────┬──────────────┘
                                │ maintainer rehearses
                                ▼
                 ┌─────────────────────────────┐
                 │ 🚀 Release · dry_run: true  │  03-release.yml
                 │ meta → quality gate →       │  (every gate, every
                 │ build+test → assets →       │   asset, nothing
                 │ verdict                     │   published)
                 └──────────────┬──────────────┘
                                │ green → one tag pushed
                                ▼
                 ┌─────────────────────────────┐
                 │ 🚀 Release                  │  03-release.yml
                 │ meta → quality gate →       │  on tag v*
                 │ build+test → assets →       │
                 │ publish → verdict           │
                 └─────────────────────────────┘
```

One tag is the only manual step. If any gate fails, the release stops
automatically; publishing runs only after everything before it passed, and
the last thing in the log is a summary card rather than a wall of xcodebuild
output.

The rehearsal is the same workflow with `dry_run: true` — not a second
pipeline that can drift from the real one. It runs every gate and builds the
full asset set, then stops at the verdict without touching the public
release.

Every log and every summary speaks one language (Crystal Flow,
`Scripts/ci/crystal.sh`):

```
━━━━━━━━━━━━━━━━━━━━━━━━━━
🚀 Release • Assets • v0.1.0-dev.1
━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Application bundle: build/ZynSign.xcarchive/Products/Applications/ZynSign.app

━━━━━━━━━━━━━━━━━━━━━━━━━━
🚀 Release • Package
━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ ZynSign-v0.1.0-dev.1-unsigned.ipa
✓ ZynSign-v0.1.0-dev.1-SHA256.txt — 89768317ee224905…
✓ BuildPassport-v0.1.0-dev.1.json — 0 feature(s) visible, 19 staged later
✓ ReleaseNotes.md — curated notes (docs/releases/notes-v0.1.0-dev.1.md)
✓ MANIFEST.md — 5 asset(s) listed
```

The `0 feature(s) visible, 19 staged later` line is the release train, not a
build setting: a development stop exposes the core only, and every staged
feature stays compiled in until the stop that introduces it.

## Which version a run releases

`Scripts/ci/release_meta.sh` is the first step of both workflows and the
only place the version is decided:

| Trigger | Version released |
| --- | --- |
| Tag push (`v0.1.0-dev.1`) | the tag's version |
| `workflow_dispatch` with a version typed | that version |
| `workflow_dispatch` with the field left empty | the release train's current stop |

The train's current stop is read from `ReleaseTrain.swift` through
`python3 Scripts/release_train.py current` — no version is hardcoded in a
workflow, so a bare **Run workflow** always means "release what the code
says is next".

The same step refuses a version that cannot ship — a retired legacy tag
(`v0.1.0-dev`), a stop the train has already passed, a stop that has not
been promoted to yet, or a typo — and it refuses it in the *first* job, on
ubuntu, before any macOS runner is allocated:

```
✗ v0.1.0-dev is not a stop on the release train, so nothing can be released for it.
  ReleaseTrain.current is v0.1.0-dev.1; the train's stops are:
    v0.1.0-dev.1, v0.1.0-dev.2, v0.1.0-dev.3, v0.1.0, v0.1.0-alpha.1, …, v3.0.0
  The retired pre-launch tags (v0.1.0-dev, v0.1.1-dev, v0.2.0-dev) were deleted
  on 2026-09-29 and were never stages, so `promote` cannot move to them —
  a development stop is 0.1.0-dev.1, not 0.1.0-dev
::error title=release-meta::v0.1.0-dev cannot be released — it is not the release train's current stop
     Release the current stop instead: v0.1.0-dev.1
```

`Scripts/ci/release_meta.sh --self-test` proves the derivation and every
refusal against the real train, and runs in `01-build.yml` → hygiene, so a broken
release pipeline is caught on an ordinary push rather than at the moment
somebody tries to ship.

## Release quality gate

Before anything is published, `03-release.yml` verifies:

| Gate | Where |
| --- | --- |
| Requested version is the train's current stop (fails in the first job) | `Scripts/ci/release_meta.sh` |
| Tag is the release train's current stage | `Scripts/release_train.py check --tag` |
| Version consistency (`MARKETING_VERSION`, build number, deployment target) | `Scripts/ci/release_validate.sh` |
| CHANGELOG entry and release notes | `Scripts/ci/release_validate.sh` |
| Build and unit tests | `Scripts/ci/build.sh` |
| SwiftLint | `Scripts/ci/lint.sh` (🔨 Build, every commit) |
| SwiftFormat check | `Scripts/ci/format.sh` (🔨 Build, every commit) |
| Architecture Guard | `Scripts/ci/architecture_guard.sh` |
| Dependency allowlist | `Scripts/ci/dependency_check.sh` |
| Documentation | `Scripts/ci/docs_check.sh` |
| Secrets (policy + Gitleaks full history) | `Scripts/ci/security_scan.sh`, `gitleaks-action` |

## Release assets

`Scripts/ci/release_assets.sh` generates the whole set from the tag, so every
filename carries the version and nothing is ever renamed by hand:

```
Release Assets
├── ZynSign-v0.1.0-dev.1-unsigned.ipa   # Payload/ zip of the archived .app
├── ZynSign-v0.1.0-dev.1-SHA256.txt     # checksum, `shasum -a 256 -c` layout
├── BuildPassport-v0.1.0-dev.1.json     # the build's fingerprint (internal)
├── MANIFEST.md                         # identity, provenance, assets, verify
└── ReleaseNotes.md                     # docs/releases/notes-v{version}.md,
                                        # else the CHANGELOG section
```

The Build Passport is the repository's fingerprint — what a developer needs
when something goes wrong in the field, and what a user never has to see:

```json
{
  "app": "ZynSign",
  "version": "0.1.0-dev.1",
  "tag": "v0.1.0-dev.1",
  "channel": "development",
  "artifact": "ZynSign-v0.1.0-dev.1-unsigned.ipa",
  "marketingVersion": "0.1.0",
  "buildNumber": "1",
  "commit": "1578a46",
  "buildDate": "2026-09-29T07:56:39Z",
  "xcode": "unknown",
  "swift": "unknown",
  "ios": "17.0",
  "signed": false,
  "checksum": "sha256:89768317…",
  "releaseTrain": "v0.1.0-dev.1",
  "featuresVisible": 0,
  "featuresStagedLater": 19
}
```

Every field is derived at build time — the toolchain from `xcodebuild`, the
versions from `project.pbxproj`, the feature counts from
`Scripts/release_train.py status`. Nothing is hardcoded, so the passport
cannot go stale the way a written-in version number does.

The sample above was captured from a rehearsal on a Linux host with no Xcode,
which is why `xcode` and `swift` read `unknown`: the script reports what it
could not determine instead of inventing a toolchain. On the macOS runner both
come from the real `xcodebuild -version` and `swift --version`.

The IPA is unsigned (`CODE_SIGNING_ALLOWED=NO` archive) and says so in the
passport, the manifest and the release notes. **The privately tested signed
IPA remains the public artifact:** the version-stamped name means the CI
artifact can no longer collide with it at all, and the publish step still
never overwrites a file that is already on the release (see
[private-testing.md](private-testing.md) for the private → public gate).

## Channels

The channel is detected from the version suffix by
`Scripts/ci/release_meta.sh` and recorded everywhere:

| Suffix | Channel | GitHub prerelease |
| --- | --- | --- |
| `-dev.N` | development | yes |
| `-alpha.N` | alpha | yes |
| `-beta.N` | beta | yes |
| `-rc.N` | release candidate | yes |
| _(none)_ | stable | no |

See [ReleaseResetGuide.md](ReleaseResetGuide.md) for the recommended
version progression and how to retire the pre-launch tags.

## Automatic changelog

`CHANGELOG.md` is appended automatically: the release workflow runs
`Scripts/generate_changelog.py` for the tag and commits the entry to the
default branch when missing. No manual editing is required; the
`[Unreleased]` section is the only hand-written part (per pull request).

## Release notes

Release notes are assembled from merged pull requests:

- **Release Drafter** (`.github/release-drafter.yml`) keeps a running
  draft on `main`, grouped by the nine label categories — ✨ Features,
  🚀 Improvements, 🐛 Bug Fixes, ⚡ Performance, 🎨 UI, ♻️ Refactors,
  🔒 Security, 📚 Documentation, 🛠 CI — with contributors and PR links.
- `.github/release.yml` mirrors the categories for GitHub's
  auto-generated notes.
- Curated notes stay possible: `docs/releases/notes-v{version}.md`
  always wins when present.

## Conventional Commits

Every commit message follows Conventional Commits; commitlint
(`commitlint.config.js`) validates PR commits and titles in the `commitlint`
and `pr-title` jobs of `01-build.yml`, and a husky `commit-msg` hook validates
locally.
Allowed types: `feat fix refactor perf docs ci test build chore style`.
Interactive authoring: `npm install && npm run commit` (Commitizen).

## Branch naming convention

| Type | Example |
| --- | --- |
| Feature | `feature/engineering-excellence` |
| Fix | `fix/install-health-crash` |
| Docs | `docs/release-guide` |
| Refactor | `refactor/design-system` |
| Release | `release/v0.1.0-alpha.1` |

## Shipping checklist (per release)

1. `python3 Scripts/release_train.py promote` — switch on the stage's features.
2. Update `CHANGELOG.md` `[Unreleased]` and `docs/releases/notes-v{version}.md`.
3. Private test (see [private-testing.md](private-testing.md)).
4. Actions → **🚀 Release** → `dry_run: true` — leave the version empty to
   rehearse the train's current stop. Every gate runs and the full asset set
   is built; nothing is published.
5. Tag and push — the same workflow gates and publishes. One tag, complete
   release.
