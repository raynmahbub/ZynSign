#!/usr/bin/env bash
#
# ZynSign CI — repository health metrics and dashboards.
#
# Aggregates everything Scripts/ci/ measures into two living dashboards:
#
#   docs/internal/RepositoryHealth.md        — the internal engineering dashboard
#   docs/internal/EngineeringCommandCenter.md — the live command center
#   docs/internal/metrics-history.csv        — the trend line both read
#
# Every check runs in report mode: a failing guard is recorded as red in
# the dashboards, it does not fail this script (the dedicated workflows
# are the gates). QUICK=1 skips the slower scans for per-PR summaries.
#
# Workflows call this script; CI logic lives here, never in YAML.
#
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Crystal Flow — the shared log and summary language (Scripts/ci/crystal.sh).
CRYSTAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/ci/crystal.sh
source "${CRYSTAL_DIR}/crystal.sh"
crystal_phase "${CRYSTAL_COMMAND}" "Command Center" "Engineering metrics"

QUICK="${QUICK:-0}"
METRICS_DIR="build/metrics"
HEALTH="docs/internal/RepositoryHealth.md"
COMMAND="docs/internal/EngineeringCommandCenter.md"
HISTORY="docs/internal/metrics-history.csv"
mkdir -p "${METRICS_DIR}" docs/internal

# --- Collect: run the guards in report mode ---------------------------------
run_guard() { # name, script...
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "pass"
    else
        echo "fail"
    fi
}

ARCH_STATUS=$(run_guard architecture Scripts/ci/architecture_guard.sh)
DEP_STATUS=$(run_guard dependencies Scripts/ci/dependency_check.sh)
DOCS_STATUS=$(run_guard documentation Scripts/ci/docs_check.sh)
SEC_STATUS=$(run_guard security Scripts/ci/security_scan.sh)
COMPLEXITY_STATUS=$(run_guard complexity Scripts/ci/complexity_check.sh)

if [[ "${QUICK}" != "1" ]]; then
    DEAD_STATUS=$(run_guard dead-code Scripts/ci/dead_code_scan.sh)
else
    DEAD_STATUS="skipped"
fi

# --- Collect: repository facts -----------------------------------------------
SWIFT_FILES=$(find ZynSign Tests -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')
SWIFT_LOC=$(find ZynSign Tests -name '*.swift' -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
TEST_FILES=$(find Tests -name '*Tests.swift' 2>/dev/null | wc -l | tr -d ' ')
TEST_COUNT=$(grep -rhoE "func test[A-Za-z0-9_]+\(" Tests --include='*.swift' 2>/dev/null | wc -l | tr -d ' ')
DOC_PAGES=$(find docs -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
TODAY=$(date -u +%Y-%m-%d)

LARGEST_FILES=$(find ZynSign Tests -name '*.swift' -exec wc -l {} + 2>/dev/null \
    | grep -v total | sort -rn | head -8 \
    | awk '{printf "| %s | %d |\n", $2, $1}')

TRAIN_STATUS=$(python3 Scripts/release_train.py status 2>/dev/null | head -2 | tr '\n' ' · ' | sed 's/·  ·/·/')
TRAIN_CHECK=$(run_guard release-train python3 Scripts/release_train.py check)

CHANGELOG_STATUS="fail"
grep -q "^## \[Unreleased\]" CHANGELOG.md 2>/dev/null && CHANGELOG_STATUS="pass"

# Read back the metric files the guards wrote.
metric() { grep -E "^$2=" "${METRICS_DIR}/$1" 2>/dev/null | head -1 | cut -d= -f2- || true; }
ARCH_VIOLATIONS=$(metric architecture.txt violations); ARCH_VIOLATIONS=${ARCH_VIOLATIONS:-?}
DEP_COUNT=$(metric dependencies.txt dependency_count); DEP_COUNT=${DEP_COUNT:-0}
DOC_BROKEN=$(metric docs.txt broken_links); DOC_BROKEN=${DOC_BROKEN:-?}
DOC_ORPHANS=$(metric docs.txt orphaned_pages); DOC_ORPHANS=${DOC_ORPHANS:-?}
COMPLEXITY_FINDINGS=$(metric complexity.txt findings); COMPLEXITY_FINDINGS=${COMPLEXITY_FINDINGS:-?}
WORST_FILE=$(metric complexity.txt worst_file); WORST_FILE=${WORST_FILE:-n/a}
WORST_FUNC=$(metric complexity.txt worst_function); WORST_FUNC=${WORST_FUNC:-n/a}
DEAD_ENGINE=$(metric dead_code.txt engine); DEAD_ENGINE=${DEAD_ENGINE:-n/a}
DEAD_CANDIDATES=$(metric dead_code.txt candidates); DEAD_CANDIDATES=${DEAD_CANDIDATES:-n/a}

# --- Release readiness score --------------------------------------------------
score=0
checks=0
READINESS_ROWS=""
add_gate_row() { # status, label — accumulates in the main shell
    checks=$((checks + 1))
    if [[ "$1" == "pass" ]]; then
        score=$((score + 1))
        READINESS_ROWS="${READINESS_ROWS}| $2 | ✅ pass |"$'\n'
    else
        READINESS_ROWS="${READINESS_ROWS}| $2 | ❌ $1 |"$'\n'
    fi
}
add_gate_row "${ARCH_STATUS}" "Architecture boundaries"
add_gate_row "${DEP_STATUS}" "Dependency allowlist"
add_gate_row "${DOCS_STATUS}" "Documentation links and images"
add_gate_row "${SEC_STATUS}" "Secret policy"
add_gate_row "${TRAIN_CHECK}" "Release train consistency"
add_gate_row "${CHANGELOG_STATUS}" "CHANGELOG Unreleased section"
if [[ "${checks}" -gt 0 ]]; then
    READINESS=$((score * 100 / checks))
else
    READINESS=0
fi

status_icon() { [[ "$1" == "pass" ]] && echo "✅" || echo "❌"; }

# --- History row ---------------------------------------------------------------
if [[ ! -f "${HISTORY}" ]]; then
    echo "date,commit,swift_files,loc,test_count,arch_violations,complexity_findings,dead_code_candidates,broken_links,readiness_score" > "${HISTORY}"
fi
ROW="${TODAY},${COMMIT},${SWIFT_FILES},${SWIFT_LOC},${TEST_COUNT},${ARCH_VIOLATIONS},${COMPLEXITY_FINDINGS},${DEAD_CANDIDATES},${DOC_BROKEN},${READINESS}"
if ! tail -1 "${HISTORY}" | grep -q "${ROW}" 2>/dev/null; then
    echo "${ROW}" >> "${HISTORY}"
fi

# --- Dashboard: RepositoryHealth.md -------------------------------------------
cat > "${HEALTH}" <<EOF
# Repository Health

_Generated ${TODAY} by \`Scripts/ci/metrics_report.sh\` at commit \`${COMMIT}\` (\`${BRANCH}\`).
Every CI summary and an on-demand full run keep this dashboard current._

## Overview

| Metric | Value |
| --- | --- |
| Swift files | ${SWIFT_FILES} |
| Swift lines of code | ${SWIFT_LOC} |
| Test files | ${TEST_FILES} |
| Unit tests | ${TEST_COUNT} |
| Documentation pages | ${DOC_PAGES} |
| External dependencies | ${DEP_COUNT} |
| Release readiness score | **${READINESS}%** (${score}/${checks} checks) |

## Build Status

| Check | Status |
| --- | --- |
| Architecture Guard | $(status_icon "${ARCH_STATUS}") ${ARCH_STATUS} (${ARCH_VIOLATIONS} violations) |
| Dependency validation | $(status_icon "${DEP_STATUS}") ${DEP_STATUS} |
| Documentation check | $(status_icon "${DOCS_STATUS}") ${DOCS_STATUS} (${DOC_BROKEN} broken links, ${DOC_ORPHANS} orphaned pages) |
| Secret policy | $(status_icon "${SEC_STATUS}") ${SEC_STATUS} |
| Complexity guard | $(status_icon "${COMPLEXITY_STATUS}") ${COMPLEXITY_STATUS} (${COMPLEXITY_FINDINGS} findings — warnings only) |
| Dead code scan (${DEAD_ENGINE}) | ${DEAD_STATUS} (${DEAD_CANDIDATES} candidates) |
| Release train | $(status_icon "${TRAIN_CHECK}") ${TRAIN_CHECK} |

Current train: ${TRAIN_STATUS}

## Release Readiness

| Gate | Result |
| --- | --- |
${READINESS_ROWS}

## Largest Swift Files

| File | Lines |
| --- | --- |
${LARGEST_FILES}

Worst function: ${WORST_FUNC}
Largest file: ${WORST_FILE}

## Dead Code

${DEAD_CANDIDATES} candidate(s) reported by the ${DEAD_ENGINE} engine.
See \`Reports/DeadCodeReport.md\` (CI artifact) — nothing is deleted automatically.

## Dependency Health

The project declares ${DEP_COUNT} external package(s). ZynSign stays
dependency-free unless a package is deliberately allowlisted
(\`Scripts/ci/dependency-allowlist.txt\`).

---
_Regenerated automatically. History: \`docs/internal/metrics-history.csv\`._
EOF

# --- Dashboard: EngineeringCommandCenter.md ------------------------------------
cat > "${COMMAND}" <<EOF
# Engineering Command Center

_Live internal engineering dashboard — generated ${TODAY} at commit \`${COMMIT}\` by
\`Scripts/ci/metrics_report.sh\`; updated by every CI summary and refreshed
by an on-demand full run._

## Status Board

| Area | Status | Detail |
| --- | --- | --- |
| Build & tests | see CI checks | \`01-build.yml\` on every PR and push |
| Architecture health | $(status_icon "${ARCH_STATUS}") | ${ARCH_VIOLATIONS} violation(s) across 8 rules |
| Test coverage surface | ✅ | ${TEST_COUNT} tests in ${TEST_FILES} files |
| Largest Swift files | 📏 | ${WORST_FILE} |
| Dead code trend | 🔎 | ${DEAD_CANDIDATES} candidate(s), ${DEAD_ENGINE} engine |
| Dependency changes | ✅ | ${DEP_COUNT} package(s), allowlist enforced |
| Release readiness score | ${READINESS}% | ${score}/${checks} gates passing |
| Open regressions | tracked | \`regression\` label in the issue tracker |
| Performance baseline | device-only | Compatibility Lab runs on-device; CI records toolchain |

## Current Release Train

${TRAIN_STATUS}

## Trend

| Date | Commit | Swift files | LOC | Tests | Arch violations | Complexity findings | Dead code candidates | Broken links | Readiness |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
$(tail -n +2 "${HISTORY}" 2>/dev/null | tail -10 | awk -F, '{print "| "$1" | "$2" | "$3" | "$4" | "$5" | "$6" | "$7" | "$8" | "$9" | "$10"% |"}')

## What Feeds This Dashboard

- \`Scripts/ci/architecture_guard.sh\` → \`build/metrics/architecture.txt\`
- \`Scripts/ci/complexity_check.sh\` → \`build/metrics/complexity.txt\`
- \`Scripts/ci/dead_code_scan.sh\` → \`build/metrics/dead_code.txt\`
- \`Scripts/ci/dependency_check.sh\` → \`build/metrics/dependencies.txt\`
- \`Scripts/ci/docs_check.sh\` → \`build/metrics/docs.txt\`
- \`Scripts/ci/security_scan.sh\` → \`build/metrics/security.txt\`
- \`02-quality.yml\` posts it on every pull request; \`Scripts/ci/metrics_report.sh\` refreshes it on demand.
EOF

echo "Dashboards written: ${HEALTH}, ${COMMAND}"
echo "Readiness ${READINESS}% (${score}/${checks}) — architecture ${ARCH_STATUS}, dependencies ${DEP_STATUS}, docs ${DOCS_STATUS}, security ${SEC_STATUS}, dead code ${DEAD_STATUS}."
