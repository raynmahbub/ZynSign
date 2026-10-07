# Engineering Command Center

_Live internal engineering dashboard — generated 2026-10-01 at commit `02f629d` by
`Scripts/ci/metrics_report.sh`; updated by every CI summary and the weekly
`04-maintenance.yml` sweep._

## Status Board

| Area | Status | Detail |
| --- | --- | --- |
| Build & tests | see CI checks | pull requests and manual dispatches; no branch-push Xcode build |
| Architecture health | ✅ | 0 violation(s) across 8 rules |
| Test coverage surface | ✅ | 2836 tests in 221 files |
| Largest Swift files | 📏 | 1993 lines at ZynSign/Presentation/ApplicationDetailView.swift |
| Dead code trend | 🔎 | 291 candidate(s), heuristic engine |
| Dependency changes | ✅ | 0 package(s), allowlist enforced |
| Release readiness score | 100% | 6/6 gates passing |
| Open regressions | tracked | `regression` label in the issue tracker |
| Performance baseline | device-only | Compatibility Lab runs on-device; CI records toolchain |

## Current Release Train

Current release : v0.0.1  (stage .horizon) Xcode project   : MARKETING_VERSION 0.0.1 · build 5 

## Trend

| Date | Commit | Swift files | LOC | Tests | Arch violations | Complexity findings | Dead code candidates | Broken links | Readiness |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-27 | 8119672 | 818 | 206504 | 2709 | 0 | 152 | 277 | 0 | 100% |
| 2026-09-27 | a6ddcbd | 818 | 206504 | 2709 | 0 | 152 | 277 | 0 | 100% |
| 2026-10-01 | 02f629d | 870 | 214452 | 2836 | 0 | 155 | 291 | 0 | 100% |

## What Feeds This Dashboard

- `Scripts/ci/architecture_guard.sh` → `build/metrics/architecture.txt`
- `Scripts/ci/complexity_check.sh` → `build/metrics/complexity.txt`
- `Scripts/ci/dead_code_scan.sh` → `build/metrics/dead_code.txt`
- `Scripts/ci/dependency_check.sh` → `build/metrics/dependencies.txt`
- `Scripts/ci/docs_check.sh` → `build/metrics/docs.txt`
- `Scripts/ci/security_scan.sh` → `build/metrics/security.txt`
- The PR summary aggregates the Quality gates and their metrics; `04-maintenance.yml` refreshes it weekly.
