# RC 3 — Release Lock (Feature Freeze)

**Locked:** 2026-09-26 · **Milestone:** RC 3 — Step 29 (ZS-029) ·
**Freeze commit:** the commit that carries this document, subject
`chore: finalize RC3 release lock and production validation`
**Release-lock branch:** `release/1.0.0-rc3` (see *Release branch* below)

The implementation roadmap is complete. From this lock the codebase is
**feature frozen**: the only work that may land is listed under *Allowed
changes*. Everything else is refused, including work that looks trivially
related to an allowed fix.

## Allowed changes

| Class | Examples |
|---|---|
| **Bug fixes** | wrong results, broken flows, state corruption in a workflow |
| **Crash fixes** | force-unwrap failures, assertion failures, stuck states |
| **Performance fixes** | measured regressions in launch, scrolling, search, memory |
| **Compatibility fixes** | OS-version behavior, device-class layout, framework availability |
| **Documentation corrections** | text that disagrees with the implementation |

## Refused changes

- ❌ New features (including “small” ones and hidden entry points).
- ❌ Architecture changes (layers, ports, stores, pipeline stages).
- ❌ UI redesigns (restructures of navigation, design-language changes).
- ❌ Refactors with no defect they fix. A freeze is not the time to tidy.
- ❌ Test weakening. Tests are never relaxed to make an RC pass; a failing
  test is fixed or the defect it found is fixed (`docs/releases/version-strategy.md`).

Every pull request into the lock must declare its change class in the
`.github/pull_request_template.md` *Change class* section. A pull request
without an allowed class is not merged.

## Enforcement

1. **Review** — the change-class section of the pull request template is
   binding (see [CONTRIBUTING.md](../../CONTRIBUTING.md), *Feature Freeze*).
2. **CI release gate** — `.github/workflows/ci.yml` runs
   `Scripts/release_gate.py` in the `release-gate` job, which fails when the
   required gates (documentation set, version metadata, static hygiene,
   the end-to-end validation matrix, the QA sign-off) are not satisfied.
   `release.yml` runs the same script before publishing anything.
3. **No bypass** — the gate has no “skip” flag and the workflow has no
   continue-on-error path for it. A red required check blocks the release.

## Release branch

The designated release-lock branch for this freeze is:

```
release/1.0.0-rc3
```

It is cut from the freeze commit and protected: required status checks
(`Release gate`, `Build and test (Xcode)`, `Repository hygiene`), no force
push, no deletion, and no direct pushes — changes arrive only as
allowed-class pull requests:

```sh
git branch release/1.0.0-rc3 <freeze-commit>
git push origin release/1.0.0-rc3
# then in GitHub: Settings → Branches → protect release/1.0.0-rc3,
# require the checks above, dismiss stale approvals, block force pushes.
```

> **Session note.** The work in this milestone was produced on the session
> branch `arena/01a0df02-zynsign`, which is where reviewed work lands for
> this project (CONTRIBUTING.md, *Branch-Based Development*). The
> `release/1.0.0-rc3` ref is created and protected at release time by the
> developer, from the freeze commit named above — it is not created inside
> this session.

## What the lock covers

The freeze applies to `ZynSign/`, `Tests/`, `Scripts/`, `.github/`, and
`docs/`. Metadata edits required by the release sequence itself
(`Scripts/release_train.py promote`, CHANGELOG entries, release notes) are
release engineering and are allowed as documentation corrections.

## Lifting the lock

The freeze lifts only when the planned release sequence finishes at
`1.0.0` Stable ([stable-release-sequence.md](stable-release-sequence.md)).
Between the final approved RC and Stable, no code changes occur at all
except verified release-blocker fixes. After `1.0.0`, work resumes under
normal SemVer with the next milestone.
