# Repository Health

_Generated 2026-10-01 by `Scripts/ci/metrics_report.sh` at commit `02f629d` (`arena/01a0f5e6-zynsign`).
Every CI summary and the weekly `04-maintenance.yml` sweep keep this dashboard current._

## Overview

| Metric | Value |
| --- | --- |
| Swift files | 870 |
| Swift lines of code | 214452 |
| Test files | 221 |
| Unit tests | 2836 |
| Documentation pages | 77 |
| External dependencies | 0 |
| Release readiness score | **100%** (6/6 checks) |

## Build Status

| Check | Status |
| --- | --- |
| Architecture Guard | ✅ pass (0 violations) |
| Dependency validation | ✅ pass |
| Documentation check | ✅ pass (0 broken links, 0 orphaned pages) |
| Secret policy | ✅ pass |
| Complexity guard | ✅ pass (155 findings — warnings only) |
| Dead code scan (heuristic) | pass (291 candidates) |
| Release train | ✅ pass |

Current train: Current release : v0.0.1  (stage .horizon) Xcode project   : MARKETING_VERSION 0.0.1 · build 5 

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
| ZynSign/Presentation/ApplicationLibraryView.swift | 1723 |
| ZynSign/Domain/NestedCodeDiscovery.swift | 1458 |
| Tests/ZynSignTests/ProvisioningPolicyValidationTests.swift | 1419 |
| ZynSign/Application/ValidateProvisioningProfile.swift | 1390 |
| ZynSign/Application/ImportHub.swift | 1354 |
| ZynSign/Presentation/ApplicationLibraryModel.swift | 1346 |
| ZynSign/Presentation/SigningView.swift | 1283 |

Worst function: 417 lines at ZynSign/Application/SignNestedCode.swift:53 func sign
Largest file: 1993 lines at ZynSign/Presentation/ApplicationDetailView.swift

## Dead Code

291 candidate(s) reported by the heuristic engine.
See `Reports/DeadCodeReport.md` (CI artifact) — nothing is deleted automatically.

## Dependency Health

The project declares 0 external package(s). ZynSign stays
dependency-free unless a package is deliberately allowlisted
(`Scripts/ci/dependency-allowlist.txt`).

---
_Regenerated automatically. History: `docs/internal/metrics-history.csv`._
