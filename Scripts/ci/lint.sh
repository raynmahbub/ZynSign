#!/usr/bin/env bash
#
# ZynSign CI — SwiftLint entry point.
#
# Lints the repository against .swiftlint.yml. Error-severity findings fail
# the run; warnings are reported but do not block (see the config's two
# tiers). Workflows call this script; CI logic lives here, never in YAML.
#
# On CI, findings and any tool errors are surfaced as GitHub annotations
# so the failure reason is visible without digging through logs.
#
# Usage:
#   Scripts/ci/lint.sh [--fix]
#
set -euo pipefail

# Crystal Flow — the shared log and summary language (Scripts/ci/crystal.sh).
CRYSTAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/ci/crystal.sh
source "${CRYSTAL_DIR}/crystal.sh"
crystal_phase "${CRYSTAL_QUALITY}" "Quality" "SwiftLint"

FIX=0
if [[ "${1:-}" == "--fix" ]]; then
    FIX=1
fi

OUT="$(mktemp)"
status=0

run_swiftlint() {
    if command -v swiftlint >/dev/null 2>&1; then
        swiftlint lint --config .swiftlint.yml "$@"
    elif command -v docker >/dev/null 2>&1; then
        echo "swiftlint not installed — falling back to the official Docker image."
        docker run --rm --entrypoint swiftlint \
            -v "$(pwd):/workspace" -w /workspace \
            ghcr.io/realm/swiftlint:latest \
            lint --config .swiftlint.yml "$@"
    else
        cat >&2 <<'EOF'
SwiftLint is not available.
  macOS:  brew install swiftlint
  other:  https://github.com/realm/SwiftLint#installation
EOF
        rm -f "$OUT"
        exit 2
    fi
}

EXTRA=()
if [[ "${FIX}" == "1" ]]; then
    EXTRA=(--fix)
fi

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    # console keeps the log readable; github-actions-logging turns every
    # finding into an annotation on the pull request.
    run_swiftlint --reporter console --reporter github-actions-logging "${EXTRA[@]+"${EXTRA[@]}"}" 2>&1 | tee "$OUT" || status=$?
else
    run_swiftlint "${EXTRA[@]+"${EXTRA[@]}"}" 2>&1 | tee "$OUT" || status=$?
fi

# If SwiftLint failed without producing workflow commands (a config or
# runtime error), surface its output so the reason is still visible.
if [[ "${status}" -ne 0 && "${GITHUB_ACTIONS:-}" == "true" ]] && ! grep -q '^::' "$OUT"; then
    grep -E 'error|Error' "$OUT" | tail -10 | while IFS= read -r line; do
        printf '::error title=SwiftLint::%s\n' "$(crystal_escape "${line}")"
    done || true
fi

rm -f "$OUT"
exit "${status}"
