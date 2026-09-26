# Stable Release Sequence

**Status after RC 3 (2026-09-26):** the implementation roadmap is complete
and the codebase is feature frozen
([release-lock-rc3.md](release-lock-rc3.md)). The next step is not another
feature task — it is executing the planned release sequence below, starting
with internal `0.1.0-dev` builds and progressing through Alpha, Beta, RC,
and finally `1.0.0` Stable.

## The sequence

| Stage | Versions | Purpose |
|---|---|---|
| Internal development | `0.1.0-dev` | Internal development builds |
| Alpha | `0.1.0-alpha.1` → `0.1.0-alpha.n` | Feature completion |
| Beta | `0.9.0-beta.1` → `0.9.0-beta.n` | Stability & testing |
| Release candidate | `1.0.0-rc.1` → `1.0.0-rc.n` | Release candidates |
| Stable | `1.0.0` | Stable |
| Maintenance | `1.0.1+` | Maintenance updates (SemVer) |

This is the progression in
[version-strategy.md](version-strategy.md) (exit criteria per stage) and
[release-train.md](release-train.md) (which features each tag switches on,
and the `release_train.py` tooling that keeps code, version, and tag in
step).

## Rules

1. **One release at a time.** Each stop is promoted
   (`python3 Scripts/release_train.py promote`), private-tested, then
   tagged. The privately tested binary is the public binary — no rebuild.
2. **Stages only move forward.** `promote` refuses to move backwards;
   features accumulate and are never taken away.
3. **A further RC is cut only for a verified release-blocker fix** — never
   because time has passed
   ([version-strategy.md](version-strategy.md), *Release Candidate*).
4. **No code changes between the final approved RC and Stable** except
   verified release-blocker fixes. Documentation corrections and release
   metadata remain allowed.
5. **Stable ships only when Critical blockers reach zero** and the High
   items in the [blocker audit](../audits/2026-09-26-rc3-release-blocker-audit.md)
   are done.
6. **Every tag is gated.** `release.yml` refuses a tag that is not
   `ReleaseTrain.current`; the `release-gate` CI job (no bypass) requires
   build, tests, static analysis, the validation matrix, and the QA
   checklist. Alpha/beta/RC tags are GitHub pre-releases; `1.0.0` is not.

## RC 3 hand-off — what exists now, what runs next

Already prepared (this milestone):

- Feature freeze + protected release-lock branch plan
  ([release-lock-rc3.md](release-lock-rc3.md)).
- End-to-end validation, blocker audit, security lockdown, performance and
  accessibility certification (see the docs index below).
- `1.0.0-rc.1` release metadata and notes
  ([release-metadata-1.0.0-rc.1.md](release-metadata-1.0.0-rc.1.md),
  [notes-v1.0.0-rc.1.md](notes-v1.0.0-rc.1.md)) — prepared, not published.
- Build verification and the completed QA sign-off
  ([build-verification-1.0.0-rc.1.md](build-verification-1.0.0-rc.1.md),
  [qa-signoff-1.0.0-rc.1.md](qa-signoff-1.0.0-rc.1.md)).
- The CI release gate (`Scripts/release_gate.py`, `release-gate` job) —
  active.

Next actions, in order:

```sh
# 0. Cut and protect the release-lock branch from the freeze commit
git branch release/1.0.0-rc3 <freeze-commit> && git push origin release/1.0.0-rc3
#    (GitHub → Settings → Branches: require 'Release gate', 'Build and test',
#     'Repository hygiene'; block force pushes; no direct pushes)
#    Prerequisite: hosted Actions must be able to start jobs again (billing
#    — see docs/testing/final-validation-rc3.md, "Hosted CI record") before
#    the required checks can go green.

# 1. Internal development builds (private-test-build.yml / ad-hoc IPA)
#    then promote one stage at a time:
python3 Scripts/release_train.py promote        # e.g. alpha1
python3 Scripts/release_train.py status

# 2. Per release: private matrix (docs/releases/private-testing.md),
#    CHANGELOG entry + docs/releases/notes-v<version>.md, merge, then:
git tag -a v<version> -m "ZynSign <version>"
git push origin v<version>                      # release.yml does the rest
```

Legacy GitHub releases (`v0.2.0-dev` marked Latest, `v0.1.1-dev`,
`v0.1.0-dev`) are cleaned up at publish time per
[release-train.md](release-train.md), *Legacy tags*.

## After Stable

SemVer applies: `1.0.1` patch/security fixes (including the deferred items
from the blocker audit), `1.1.0` backward-compatible features (new
`ReleaseFeature` gates resume; the freeze lifts), `2.0.0` breaking
changes.
