# Release Automation

ZynSign's release process is driven by the release train in `ZynSign/Domain/ReleaseTrain.swift`. The train—not a workflow input, draft, or changelog—decides which version may ship next. The release workflow validates that decision before it builds or publishes anything.

## Workflow

`.github/workflows/03-release.yml` runs for `v*` tag pushes and can be started manually. A manual dry run exercises the release gates and builds assets without publishing. A real run publishes the GitHub Release, then opens or updates a documentation PR to record the generated changelog on the default branch.

```text
meta → quality gate → build/archive → release assets + changelog artifact
                                          ↓
                         dry run: stop before publication
                         release: publish GitHub Release
                                  → changelog-sync PR
                                  → verdict
```

`Scripts/ci/release_meta.sh` derives the tag, marketing version, build number, channel, and prerelease flag from the release train. `Scripts/release_train.py check --tag` rejects tags that are not the current stop. The release workflow never treats a successful source build as proof of device-level signing or installation.

If publication succeeds but the follow-up changelog PR job fails, the GitHub Release is already live; the final verdict reports that partial outcome and the sync job must be rerun or repaired. A rerun does not overwrite curated release notes or discard newer `[Unreleased]` entries.

The verdict itself is decided by `Scripts/ci/release_verdict.sh`, which reads every job's result in pipeline order and names the first one that did not succeed. A gate that ends `cancelled` — GitHub's conclusion when a hosted runner was never acquired ("The job was not acquired by Runner of type hosted even after multiple attempts") or when the run was cancelled by hand — is reported as an infrastructure stop with a *Re-run failed jobs* hint, not as a fault in the commit; a gate that ends `failure` points at that job's log and artifacts. A dry run is only a complete rehearsal when every gate passed.

## Gates

Before publish, the workflow runs:

- Release-train/tag and version consistency checks (`Scripts/release_train.py`, `Scripts/ci/release_validate.sh`).
- Documentation and release-note validation.
- The macOS build and available unit tests (`Scripts/ci/build.sh`).
- SwiftLint, SwiftFormat, architecture-boundary, dependency-allowlist, and security checks.
- Host-side changelog tooling tests (`Tests/Host/test_generate_changelog.py`), also run in `01-build.yml`.

Passing those gates is CI evidence only. IPA installation, certificate import, signing, and UI crash reports still require appropriate simulator/device verification; see [private testing](private-testing.md).

## Version strategy

The release train owns feature promotion, marketing-version changes, build numbers, and the permitted order of development, alpha, beta, release-candidate, and stable stops. Use the documented promotion/check commands rather than editing a workflow's version. See [release-train.md](release-train.md) and [version-strategy.md](version-strategy.md) for the current stop, progression, and exit criteria.

`Scripts/ci/release_meta.sh --self-test` and `Scripts/release_train.py check` cover version derivation and tag validation in CI. Keep release-train metadata, `MARKETING_VERSION`, and the build number consistent before creating a release tag.

## Generated changelog and release notes

The assets job checks out full tag history and runs `Scripts/generate_changelog.py` for the candidate tag. The generator compares that tag with its previous release tag on first-parent history, categorizes Conventional Commits, separates breaking changes, links available PR numbers, filters automation-only commits, and promotes curated `[Unreleased]` text when present. An existing curated `docs/releases/notes-v{version}.md` takes precedence over generated notes.

The job uploads a `release-changelog` artifact containing:

- `CHANGELOG.md` — the proposed categorized changelog with the versioned entry.
- `notes-v{version}.md` — release notes used by the GitHub Release and included as `ReleaseNotes.md` in the asset set.

The publish job consumes `release-assets/ReleaseNotes.md`; it does not fall back to GitHub's unreviewed auto-generated notes. After publication, `sync-changelog` checks out the current default branch and uses `Scripts/apply_release_changelog.py` to prepare `CHANGELOG.md` and `docs/releases/notes-v{version}.md`, then stages them on the `automation/release-changelog-{version}` branch and opens or updates a PR from it. That tool preserves newer `[Unreleased]` work, is idempotent for an existing version entry, and does not replace an existing curated notes file. The sync job reruns `Scripts/ci/docs_check.sh` against the proposed tree before opening the PR. The workflow never pushes generated changelog edits directly to the default branch.

If the repository does not allow GitHub Actions to create pull requests (Settings → Actions → General → Workflow permissions), the sync job degrades instead of failing the published release: the automation branch stays pushed with the staged changelog, the job reports a warning, and the verdict card lists the branch and the next step. Provide a `RELEASE_CHANGELOG_TOKEN` secret (a PAT or app token) or enable the setting, then re-run the sync job — or open the PR from the staged branch manually.

To adjust hand-curated wording, add or edit the versioned notes file before the release run. Curated notes are source material for the artifact; the generated `ReleaseNotes.md` is what is attached to the published release.

## Assets

`Scripts/ci/release_assets.sh` creates a version-stamped artifact set from the archived app. Names are derived from the candidate tag, and the upload step does not overwrite an existing release asset.

```text
ZynSign-v{version}-unsigned.ipa
ZynSign-v{version}-SHA256.txt
BuildPassport-v{version}.json
MANIFEST.md
ReleaseNotes.md
```

The CI IPA is unsigned. Its manifest and build passport record provenance and signing state; it is not a privately signed or device-verified build. A signed test build must follow the separate controls in [private-testing.md](private-testing.md).

## Categories and Conventional Commits

`.github/release-drafter.yml` maintains a draft grouped by PR labels. The published release notes are instead generated from the tag's commit history, so both PR titles and commit messages should use the configured Conventional Commit types:

`feat`, `fix`, `refactor`, `perf`, `security`, `docs`, `ci`, `test`, `build`, `chore`, `style`, `revert`, `release`.

`commitlint.config.js` enforces the allowed types; the local commit hook is installed with `npm install`, and interactive authoring is available with `npm run commit`. Use `release:` for release-only metadata changes; generated release history filters those commits from user-facing notes. Use the `ignore-for-release` label for PRs that Release Drafter should omit from its draft.

## Release run checklist

1. Confirm the intended stage and feature promotion in the release-train documentation.
2. Update curated `[Unreleased]` wording or add `docs/releases/notes-v{version}.md` only when it improves the generated notes.
3. Complete required private testing and review of release assets.
4. Run **Release** with `dry_run: true`; inspect the gates and downloaded `release-assets` artifact.
5. Push the tag for the current train stop (or start the validated non-dry-run workflow, if configured for that path).
6. Confirm the GitHub Release is live and merge the generated changelog-sync PR after review.
7. Verify the published signed/unsigned status, checksum, assets, and any required device-level install/signing scenarios independently.
