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
check. Eight workflows produce them; the checks themselves did not change
when the suite was consolidated, only the file they live in.

| Check (enter this string) | Workflow | Job |
| --- | --- | --- |
| `Build and test (Xcode)` | `ci.yml` | `build-and-test` |
| `Lint and format` | `ci.yml` | `lint-and-format` |
| `Repository hygiene` | `ci.yml` | `hygiene` |
| `Enforce the layered architecture contract` | `quality.yml` | `architecture-guard` |
| `Enforce the dependency allowlist` | `quality.yml` | `dependency-validation` |
| `Links, images, orphans, markdown quality` | `quality.yml` | `docs-check` |
| `Repository secret policy` | `quality.yml` | `secret-policy` |
| `Gitleaks (full history)` | `quality.yml` | `gitleaks` |
| `README freshness` | `quality.yml` | `readme-check` |
| `Conventional PR title` | `pr-quality.yml` | `pr-title` |
| `Conventional commit messages` | `pr-quality.yml` | `commitlint` |

`Complexity thresholds (warnings only)`, `Engineering Command Center`, the
`External validation (Apple tooling)` measurement, the weekly Periphery
dead-code scan, and the labeling/stale/README-repair jobs stay advisory —
they measure and report, they do not block.

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

1. Confirm the maintenance workflow can still publish dashboards. With
   direct pushes blocked, it falls back to opening a pull request
   automatically (its design supports both).
2. Add `CODEOWNERS` review requests (`.github/CODEOWNERS` is already in
   place — protection makes the requests mandatory).
3. Watch one full release cycle: preflight, tag, quality gate, publish.
