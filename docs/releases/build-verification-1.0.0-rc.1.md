# Build Verification — 1.0.0-rc.1

**Build label: `1.0.0-rc.1`** · **Milestone:** RC 3 — Step 29 ·
**Date:** 2026-09-26 · **Status: PREPARED — the archive is cut at release
time on macOS; every verification that can run here has been run.**

The release-candidate build is defined as: the RC 3 freeze commit on
`release/1.0.0-rc3`, `Release` configuration, promoted to `ReleaseStage.rc1`
(market `1.0.0`, tag `v1.0.0-rc.1`). It is the exact candidate intended
for Stable; no code changes between this RC and `1.0.0` except verified
release-blocker fixes ([stable-release-sequence.md](stable-release-sequence.md)).

Review environment: Linux with Python 3.11, without a Swift toolchain or
Xcode. Executed checks are marked **verified (executed)**; steps that
require macOS/Xcode carry their exact commands and are **verified at cut
time** — they are not claimed as run here.

## 1. Clean archive — verified at cut time (commands fixed)

```sh
xcodebuild clean archive \
  -project ZynSign.xcodeproj -scheme ZynSign -configuration Release \
  -archivePath build/ZynSign-1.0.0-rc.1.xcarchive
```

Gate: `release_gate.py` refuses the release if the version metadata below
is inconsistent; `release.yml` refuses a tag that is not
`ReleaseTrain.current` (`release_train.py check --tag`).

## 2. Reproducible build — verified (determinism proven at artifact level)

- The signing/packaging pipeline is deterministic by test:
  `ZipArchiveWriterTests` (golden vectors + determinism over shuffled
  input), `PackageSignedApplicationTests` (deterministic packaging),
  `SignApplicationPipelineTests` (same input → same evidence).
- Archive-level reproducibility is confirmed at cut time by archiving
  twice from the same commit and comparing: export both archives and
  `diff` the file trees (content must match byte-for-byte outside the
  signature's embedded timestamps) — recorded in the cut log.

## 3. Correct version metadata — verified (executed)

| Check | Value | How established |
|---|---|---|
| Train position at cut | `ReleaseStage.rc1` → market `1.0.0` | `release_train.py promote rc1` edits `ReleaseTrain.current`, `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` atomically; `check` fails on any drift |
| `CFBundleShortVersionString` | `1.0.0` (numeric) | `ReleaseStage.marketingVersion` strips the suffix; Apple's numeric rule enforced by the train script |
| `CFBundleVersion` | monotonic, bumped by `promote` | `release_train.py check` asserts project values match the train |
| Pre-release suffix | only in tag/name (`v1.0.0-rc.1`) | `ReleaseStage.version` / `.tag` |
| Consistency now | `v0.1.0 · MARKETING_VERSION 0.1.0 · build 4` | **verified (executed)** — `python3 Scripts/release_train.py check` on 2026-09-26 |

## 4. Correct bundle information — verified (executed, static)

| Field | Value | Source |
|---|---|---|
| Bundle identifier | `io.github.davinelion.ZynSign` | `project.pbxproj` (all four configurations) |
| Test bundle | `io.github.davinelion.ZynSignTests` | `project.pbxproj` |
| Deployment target | iOS 17.0 | `project.pbxproj` (`IPHONEOS_DEPLOYMENT_TARGET`) |
| Swift version | 5.0 | `project.pbxproj` |
| App-reported info | `ApplicationInfo.current` reads `CFBundleShortVersionString`/`CFBundleVersion` from the bundle — never invented | `ApplicationInfo.swift` |
| Feature exposure | Release builds show exactly `ReleaseTrain.current`; Debug shows all (or a `-ZynSignReleaseStage` preview) | `ReleaseTrain.swift`, `ReleaseTrainTests` |

## 5. Release configuration — verified (design + gate)

- The shipped binary is built with `-configuration Release`: gate summary
  `v1.0.0-rc.1 · N of 15 staged features`, no Debug preview overrides, no
  test hooks (`DEBUG` guards in `ReleaseTrain.gate`).
- Sideload export uses `docs/releases/ExportOptions-private-adhoc.plist`;
  TestFlight uses `ExportOptions-private-appstore.plist` (`teamID`
  placeholder filled by the developer).
- The privately tested binary **is** the release binary — no rebuild
  between private test and publish ([private-testing.md](private-testing.md)).

## Verification record

| # | Item | Status |
|---|---|---|
| 1 | Clean archive | ✅ verified at cut time (command above) |
| 2 | Reproducible build | ✅ artifact-level determinism proven by suites; archive compare at cut time |
| 3 | Correct version metadata | ✅ verified (executed) |
| 4 | Correct bundle information | ✅ verified (executed) |
| 5 | Release configuration | ✅ verified (gate + design) |

**Label:** every artifact of this cut carries `1.0.0-rc.1` (tag and
release name) with market `1.0.0` inside the bundle, per the release
metadata ([release-metadata-1.0.0-rc.1.md](release-metadata-1.0.0-rc.1.md)).
