# Repository Health

_Generated 2026-11-09 by `Scripts/ci/metrics_report.sh` at commit `b1d10f1` (`main`).
Every CI summary and the weekly `04-maintenance.yml` sweep keep this dashboard current._

## Overview

| Metric | Value |
| --- | --- |
| Swift files | 1011 |
| Swift lines of code | 258814 |
| Test files | 256 |
| Unit tests | 3341 |
| Documentation pages | 101 |
| External dependencies | 0 |
| Release readiness score | **100%** (6/6 checks) |

## Build Status

| Check | Status |
| --- | --- |
| Architecture Guard | ✅ pass (0 violations) |
| Dependency validation | ✅ pass |
| Documentation check | ✅ pass (0 broken links, 0 orphaned pages) |
| Secret policy | ✅ pass |
| Complexity guard | ✅ pass (150 findings — warnings only) |
| Dead code scan (n/a) | fail (n/a candidates) |
| Release train | ✅ pass |

Current train: Current release : v0.1.0-alpha.3  (stage .alpha3) Xcode project   : MARKETING_VERSION 0.1.0 · build 9 

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
| ZynSign/Presentation/SigningView.swift | 1809 |
| ZynSign/Application/SignApplicationPipeline.swift | 1696 |
| ZynSign/Presentation/ApplicationDetailView.swift | 1472 |
| ZynSign/Domain/NestedCodeDiscovery.swift | 1458 |
| ZynSign/Presentation/SettingsView.swift | 1437 |
| Tests/ZynSignTests/ProvisioningPolicyValidationTests.swift | 1419 |
| ZynSign/Application/ImportHub.swift | 1394 |
| ZynSign/Application/ValidateProvisioningProfile.swift | 1390 |

Worst function: 417 lines at ZynSign/Application/SignNestedCode.swift:53 func sign
Largest file: 1809 lines at ZynSign/Presentation/SigningView.swift

## Dead Code

n/a candidate(s) reported by the n/a engine.
See `Reports/DeadCodeReport.md` (CI artifact) — nothing is deleted automatically.

## Dependency Health

The project declares 0 external package(s). ZynSign stays
dependency-free unless a package is deliberately allowlisted
(`Scripts/ci/dependency-allowlist.txt`).

---
_Regenerated automatically. History: `docs/internal/metrics-history.csv`._
