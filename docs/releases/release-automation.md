# Release Automation

_The engineering-excellence release system: how a tag becomes a
professional release without anyone formatting anything by hand._

## The pipeline

```
                 ┌─────────────────────────────┐
 merged PRs ───► │ Release Drafter drafts the  │
 (labelled)      │ next release notes          │
                 └──────────────┬──────────────┘
                                │ maintainer runs
                                ▼
                 ┌─────────────────────────────┐
                 │ Prerelease Preflight        │  workflow_dispatch
                 │ meta → validate → guards →  │  (the full rehearsal;
                 │ lint → build → tests →      │   nothing published)
                 │ asset dry run               │
                 └──────────────┬──────────────┘
                                │ green → tag pushed
                                ▼
                 ┌─────────────────────────────┐
                 │ Release                     │  on tag v*
                 │ meta → quality gate →       │  (or workflow_dispatch)
                 │ build+test → assets →       │
                 │ publish                     │
                 └─────────────────────────────┘
```

If any gate fails, the release stops automatically; publishing is the
last job and runs only after everything before it passed.

## Which version a run releases

`Scripts/ci/release_meta.sh` is the first step of both workflows and the
only place the version is decided:

| Trigger | Version released |
| --- | --- |
| Tag push (`v1.0.0-rc.2`) | the tag's version |
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
  ReleaseTrain.current is v1.0.0-rc.2; the train's stops are: …
::error title=release-meta::v0.1.0-dev cannot be released — it is not the release train's current stop
     Release the current stop instead: v1.0.0-rc.2
```

`Scripts/ci/release_meta.sh --self-test` proves the derivation and every
refusal against the real train, and runs in `ci.yml` → hygiene, so a broken
release pipeline is caught on an ordinary push rather than at the moment
somebody tries to ship.

## Release quality gate

Before anything is published, `release.yml` verifies:

| Gate | Where |
| --- | --- |
| Requested version is the train's current stop (fails in the first job) | `Scripts/ci/release_meta.sh` |
| Tag is the release train's current stage | `Scripts/release_train.py check --tag` |
| Version consistency (`MARKETING_VERSION`, build number, deployment target) | `Scripts/ci/release_validate.sh` |
| CHANGELOG entry and release notes | `Scripts/ci/release_validate.sh` |
| Build and unit tests | `Scripts/ci/build.sh` |
| SwiftLint | `Scripts/ci/lint.sh` (preflight) |
| SwiftFormat check | `Scripts/ci/format.sh` (preflight) |
| Architecture Guard | `Scripts/ci/architecture_guard.sh` |
| Dependency allowlist | `Scripts/ci/dependency_check.sh` |
| Documentation | `Scripts/ci/docs_check.sh` |
| Secrets (policy + Gitleaks full history) | `Scripts/ci/security_scan.sh`, `gitleaks-action` |

## Release assets

Every release uploads exactly:

```
Release Assets
├── ZynSign.ipa          # archive artifact of the Release build (unsigned in CI)
├── ZynSign.sha256       # checksum of the IPA
├── BuildInfo.json       # version, build number, commit SHA, build date,
│                        # Swift version, Xcode version, supported iOS,
│                        # release channel, checksum, signed flag
└── ReleaseNotes.md      # docs/releases/notes-v{version}.md, or the
                         # CHANGELOG section when no notes file exists
```

The CI-built IPA is unsigned (`CODE_SIGNING_ALLOWED=NO` archive) and
marked `"signed": false` in `BuildInfo.json` — it is the reproducible
record of what the tag built. **The privately tested signed IPA remains
the public artifact:** the publish step never overwrites an existing
`ZynSign.ipa` on the release (see
[private-testing.md](private-testing.md) for the private → public
gate).

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
(`commitlint.config.js`) validates PR commits and titles in
`pr-quality.yml`, and a husky `commit-msg` hook validates locally.
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
4. Actions → **Prerelease Preflight** — leave the version empty to rehearse
   the train's current stop, or type the candidate explicitly.
5. Tag and push — the Release workflow gates and publishes. (Or run
   **Release** manually with an empty version for the same stop.)
