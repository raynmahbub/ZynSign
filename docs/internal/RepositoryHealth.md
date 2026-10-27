# Repository Health

_Generated 2026-10-27 by `Scripts/ci/metrics_report.sh` at commit `591151c` (`main`).
Every CI summary and the weekly `04-maintenance.yml` sweep keep this dashboard current._

## Overview

| Metric | Value |
| --- | --- |
| Swift files | 916 |
| Swift lines of code | 225878 |
| Test files | 234 |
| Unit tests | 2962 |
| Documentation pages | 80 |
| External dependencies | 0 |
| Release readiness score | **100%** (6/6 checks) |

## Build Status

| Check | Status |
| --- | --- |
| Architecture Guard | ✅ pass (0 violations) |
| Dependency validation | ✅ pass |
| Documentation check | ✅ pass (0 broken links, 0 orphaned pages) |
| Secret policy | ✅ pass |
| Complexity guard | ✅ pass (137 findings — warnings only) |
| Dead code scan (periphery) | pass (1046 candidates) |
| Release train | ✅ pass |

Current train: Current release : v0.1.0-alpha.2  (stage .alpha2) Xcode project   : MARKETING_VERSION 0.1.0 · build 8 

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
| ZynSign/Application/SignApplicationPipeline.swift | 1554 |
| ZynSign/Presentation/ApplicationDetailView.swift | 1472 |
| ZynSign/Domain/NestedCodeDiscovery.swift | 1458 |
| Tests/ZynSignTests/ProvisioningPolicyValidationTests.swift | 1419 |
| ZynSign/Presentation/SigningView.swift | 1399 |
| ZynSign/Application/ValidateProvisioningProfile.swift | 1390 |
| ZynSign/Application/ImportHub.swift | 1386 |
| ZynSign/Presentation/ApplicationLibraryModel.swift | 1346 |

Worst function: 417 lines at ZynSign/Application/SignNestedCode.swift:53 func sign
Largest file: 1554 lines at ZynSign/Application/SignApplicationPipeline.swift

## Dead Code

1046 candidate(s) reported by the periphery engine.
See `Reports/DeadCodeReport.md` (CI artifact) — nothing is deleted automatically.

## Dependency Health

The project declares 0 external package(s). ZynSign stays
dependency-free unless a package is deliberately allowlisted
(`Scripts/ci/dependency-allowlist.txt`).

---
_Regenerated automatically. History: `docs/internal/metrics-history.csv`._
