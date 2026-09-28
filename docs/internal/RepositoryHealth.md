# Repository Health

_Generated 2026-09-27 by `Scripts/ci/metrics_report.sh` at commit `a6ddcbd` (`arena/01a0e4b5-zynsign`).
The weekly maintenance workflow keeps this dashboard current._

## Overview

| Metric | Value |
| --- | --- |
| Swift files | 818 |
| Swift lines of code | 206504 |
| Test files | 207 |
| Unit tests | 2709 |
| Documentation pages | 93 |
| External dependencies | 0 |
| Release readiness score | **100%** (6/6 checks) |

## Build Status

| Check | Status |
| --- | --- |
| Architecture Guard | ✅ pass (0 violations) |
| Dependency validation | ✅ pass |
| Documentation check | ✅ pass (0 broken links, 4 orphaned pages) |
| Secret policy | ✅ pass |
| Complexity guard | ✅ pass (152 findings — warnings only) |
| Dead code scan (heuristic) | 277 candidate(s) (cached full scan) |
| Release train | ✅ pass |

Current train: Current release : v1.0.0-rc.2  (stage .rc2) Xcode project   : MARKETING_VERSION 1.0.0 · build 5 

## Release Readiness

| Gate | Result |
| --- | --- |
| Architecture boundaries | ✅ pass |
| Dependency allowlist | ✅ pass |
| Documentation links and images | ✅ pass |
| Secret policy | ✅ pass |
| Release train consistency | ✅ pass |
| CHANGELOG Unreleased section | ✅ pass |


## Largest Swift Files

| File | Lines |
| --- | --- |
| ZynSign/Presentation/ApplicationDetailView.swift | 1993 |
| ZynSign/App/CompositionRoot.swift | 1711 |
| ZynSign/Presentation/ApplicationLibraryView.swift | 1648 |
| ZynSign/Domain/NestedCodeDiscovery.swift | 1458 |
| Tests/ZynSignTests/ProvisioningPolicyValidationTests.swift | 1419 |
| ZynSign/Application/ValidateProvisioningProfile.swift | 1390 |
| ZynSign/Presentation/ApplicationLibraryModel.swift | 1346 |
| ZynSign/Application/ImportHub.swift | 1320 |

Worst function: 417 lines at ZynSign/Application/SignNestedCode.swift:53 func sign
Largest file: 1993 lines at ZynSign/Presentation/ApplicationDetailView.swift

## Dead Code

277 candidate(s) reported by the heuristic engine.
See `Reports/DeadCodeReport.md` (CI artifact) — nothing is deleted automatically.

## Dependency Health

The project declares 0 external package(s). ZynSign stays
dependency-free unless a package is deliberately allowlisted
(`Scripts/ci/dependency-allowlist.txt`).

---
_Regenerated automatically. History: `docs/internal/metrics-history.csv`._
