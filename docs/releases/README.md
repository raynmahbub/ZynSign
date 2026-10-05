# Release Guide

ZynSign follows the source-controlled [release train](release-train.md). Do not choose a version independently: inspect the current stop with `python3 Scripts/release_train.py status`, then use the train's promotion and validation commands.

## Release sequence

1. **Select the stop:** review the feature map and exit criteria in [version strategy](version-strategy.md). Promote only when the prior stop's requirements are met.
2. **Prepare and review:** update source, tests, and any curated `[Unreleased]` wording or `docs/releases/notes-v{version}.md`. Keep user-facing changes in Conventional Commits so generated notes are meaningful.
3. **Verify privately:** follow the [private device-test gate](private-testing.md). CI and source audits do not substitute for physical-device import, certificate, signing, or OTA hand-off checks.
4. **Rehearse:** run **Release** with `dry_run: true`. Inspect the gates and `release-assets` artifact; a rehearsal publishes nothing.
5. **Publish:** create the current train tag or run the validated non-dry-run workflow. The release workflow builds version-stamped assets, attaches categorized release notes, and does not overwrite existing release assets.
6. **Review changelog sync:** after publication the workflow opens or updates a PR for `CHANGELOG.md` and `docs/releases/notes-v{version}.md`. Review and merge it; generated edits are never pushed directly to the default branch.

If publication succeeds but the changelog-sync job fails, the release is already live. Repair or rerun the sync job; the generated changelog tools are idempotent and preserve newer `[Unreleased]` work.

## Reference

- [Release train](release-train.md) — ordered versions, feature exposure, and commands.
- [Release automation](release-automation.md) — CI gates, artifacts, generated notes, and PR sync.
- [Version strategy](version-strategy.md) — SemVer rules and stage exit criteria.
- [Private testing](private-testing.md) — device matrix and publication blocker.
- [Checklist](Checklist.md) — release-specific readiness checks.
- [Screenshot plan](screenshots.md) — marketing capture rules; check every screen against the current train before using it.
- [Historical release notes](notes-v0.0.1.md) — notes for the first stable train stop.
- [Alpha 1 release notes](notes-v0.1.0-alpha.1.md) — notes for the Alpha 1 release.
- [Alpha 2 release notes](notes-v0.1.0-alpha.2.md) — notes for the Alpha 2 release: the signing workflow opens on the Storefront shell.
