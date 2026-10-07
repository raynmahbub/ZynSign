# Branch Protection — Recommended Settings

_These settings are documented here and enabled **manually** in
the repository settings (Settings → Branches → Add branch protection
rule). The CI suite is designed so every check below exists as a status
check the moment protection is switched on._

## `main`

| Setting | Value | Why |
| --- | --- | --- |
| Require pull requests before merging | ✅ enabled | all changes get review |
| Required approvals | 1 | one reviewer minimum |
| Dismiss stale reviews on new pushes | ✅ enabled | reviewed code stays the merged code |
| Require status checks to pass | ✅ enabled | broken code cannot merge |
| Require branches to be up to date | ✅ enabled | merges are tested against current `main` |
| Required status checks | see table below | the engineering gate suite |
| Prevent force pushes | ✅ enabled | history is immutable |
| Prevent deletions | ✅ enabled | the branch cannot be removed |
| Do not allow direct pushes | ✅ enabled | everything goes through a PR |
| Include administrators | ✅ recommended | rules apply to maintainers too |

### Required status checks

GitHub matches a required check against the **job's display name**, so these
are the exact strings to enter in Settings → Branches → Add required status
check. Three workflows produce them; the checks themselves did not change
when the suite was consolidated, only the file they live in.

| Check (enter this string) | Workflow | Job |
| --- | --- | --- |
| `Build and test (Xcode)` | `01-build.yml` | `build-and-test` |
| `Lint and format` | `01-build.yml` | `lint-and-format` |
| `Repository hygiene` | `01-build.yml` | `hygiene` |
| `External validation (Apple tooling)` | `01-build.yml` | `external-validation` |
| `Enforce the layered architecture contract` | `02-quality.yml` | `architecture-guard` |
| `Enforce the dependency allowlist` | `02-quality.yml` | `dependency-validation` |
| `Links, images, orphans, markdown quality` | `02-quality.yml` | `docs-check` |
| `Repository secret policy` | `02-quality.yml` | `secret-policy` |
| `Gitleaks (full history)` | `02-quality.yml` | `gitleaks` |
| `Release train consistency` | `02-quality.yml` | `release-train` |
| `README freshness` | `02-quality.yml` | `readme-check` |
| `Conventional PR title` | `01-build.yml` | `pr-title` |
| `Conventional commit messages` | `01-build.yml` | `commitlint` |

`Complexity thresholds (warnings only)`, `Engineering Command Center`,
`Danger Swift review`, `Label the pull request` and the weekly
`Maintenance` sweep stay advisory — they measure and report, they do not
block. `External validation (Apple tooling)` **is** in the required list
above: it blocks when the harness itself cannot run — a red there is a red
worth reading, and every `codesign`/`otool` verdict lands in the report
either way. The job reports on every pull request unconditionally.
Formatting is repaired
with `Scripts/ci/format.sh apply`, a stale README with
`python3 Scripts/update_readme.py`, and the full dashboards with
`Scripts/ci/metrics_report.sh` — locally as a reviewable commit, or
automatically by the weekly `04-maintenance.yml` repair PR.

> Every required check must actually report on the pull request. A job that
> is skipped by an `if:` or excluded by a `paths:` filter never produces a
> check run, and a missing required check blocks the merge forever — so the
> jobs above run unconditionally on every pull request.

## `develop` (if introduced)

Mirror `main` except approvals: keep the same status checks, require
up-to-date branches, no force pushes, no direct pushes. ZynSign today
works single-branch (the release train gates features, not branches —
see [../releases/release-train.md](../releases/release-train.md)); add
`develop` only if the process adopts it.

## After enabling

1. Open a test pull request and confirm every required check above
   reports on it — a required check that never reports blocks merges
   forever.
2. Add `CODEOWNERS` review requests (`.github/CODEOWNERS` is already in
   place — protection makes the requests mandatory).
3. Watch one full release cycle: dry run, tag, quality gate, publish.
