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

| Check | Workflow |
| --- | --- |
| `build-and-test` | `build-validation.yml` |
| `swiftlint` | `swiftlint.yml` |
| `swiftformat-check` | `swiftformat.yml` |
| `architecture-guard` | `architecture-guard.yml` |
| `dependency-validation` | `dependency-validation.yml` |
| `docs-check` | `docs-check.yml` |
| `secret-policy` / `gitleaks` | `security-scan.yml` |
| `pr-title` / `commitlint` | `pr-quality.yml` |

`complexity-check`, `dead-code` (Periphery), `quality-summary`, and the
labeling/stale bots stay advisory — they measure, they do not block.

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
