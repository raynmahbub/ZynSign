# Release Checklist

The gate every release passes, in order. A step that did not run is an open
question — it blocks, it does not default to pass. This file is the visible
form of the process described in [release-train.md](release-train.md) and
[private-testing.md](private-testing.md); the tools it names do the checking.

## 1. Train consistency

- [ ] `python3 Scripts/release_train.py check` passes — the intended tag is `ReleaseTrain.current`.
- [ ] `python3 Scripts/release_train.py status` output matches what this release is supposed to switch on.
- [ ] CI is green on the release commit: build, tests, hygiene, host vectors, audits.

## 2. Version and bookkeeping

- [ ] `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `ZynSign.xcodeproj/project.pbxproj` match the release record (marketing purely numeric; the suffix lives only in the tag).
- [ ] `CHANGELOG.md` has an entry for this version (Keep a Changelog format) — `Scripts/generate_changelog.py` can add a missing one.
- [ ] `docs/releases/notes-v<version>.md` exists, written from [notes-template.md](notes-template.md) — no section skipped, *including* "What this release deliberately does not claim".
- [ ] The documentation freeze is respected: [documentation-freeze.md](documentation-freeze.md).

## 3. Private gate — before any public act

- [ ] A **Release** build (never Debug) was installed and exercised on the private matrix: [private-testing.md](private-testing.md).
- [ ] The matrix is all green on **two real devices** (one iOS 17, one iOS 18) plus a simulator smoke.
- [ ] The Compatibility Lab verdict on the release build is **Ready**; every *not run* check is named and accepted in the notes.
- [ ] The private binary and the future public release are the **same binary** — no rebuild between private test and tag.

## 4. Publish

- [ ] `git tag -a v<version> -m "ZynSign <version> <stage>" <tested-commit>` on `main`.
- [ ] The Release workflow completes: it refuses a non-train tag, and it creates/updates the GitHub Release with the notes file as its body (pre-release for alpha/beta/rc).
- [ ] The published notes state the honest limits — in-app installation unavailable, Pairing/JIT/Mux never, no off-device analytics — in the release's own words, not copied blindly.

## 5. After the tag

- [ ] The README status quote, version badge, and honest badge read the new release (`python3 Scripts/update_readme.py --check`).
- [ ] `docs/releases/README.md` "Current State" describes the new stop.
- [ ] Any release blocker found *after* the tag is recorded in `ReleaseBlockerRecord.registry` and reflected in [../hardening/release-blockers.md](../hardening/release-blockers.md) — never silently patched into the published notes.

## Rule of the gate

A step that cannot be completed is a **Blocked** release. There is no
"publish anyway" path in this file, and none anywhere else in the repository.
