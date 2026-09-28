#!/usr/bin/env bash
#
# ZynSign CI — SwiftFormat entry point.
#
# Two modes, one rule set (see .swiftformat):
#   check  — pull requests: report violations, fail if any (never edits)
#   apply  — maintenance: format in place so the diff can be reviewed
#            and committed as a single clean change
#
# Workflows call this script; CI logic lives here, never in YAML.
# On CI, failures are surfaced as GitHub annotations.
#
# Usage:
#   Scripts/ci/format.sh check
#   Scripts/ci/format.sh apply
#
set -euo pipefail

MODE="${1:-check}"

run_swiftformat() {
    if command -v swiftformat >/dev/null 2>&1; then
        swiftformat "$@"
    elif command -v docker >/dev/null 2>&1; then
        echo "swiftformat not installed — falling back to the official Docker image."
        docker run --rm --entrypoint swiftformat \
            -v "$(pwd):/work" -w /work \
            ghcr.io/nicklockwood/swiftformat:latest "$@"
    else
        cat >&2 <<'EOF'
SwiftFormat is not available.
  macOS:  brew install swiftformat
  other:  https://github.com/nicklockwood/SwiftFormat
EOF
        exit 2
    fi
}

case "${MODE}" in
    check)
        OUT="$(mktemp)"
        status=0
        if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
            run_swiftformat --lint --config .swiftformat --reporter github-actions-log . 2>&1 | tee "$OUT" || status=$?
        else
            run_swiftformat --lint --config .swiftformat . 2>&1 | tee "$OUT" || status=$?
        fi
        # Belt and braces: if the reporter produced no workflow commands
        # (older SwiftFormat), surface the findings as an annotation anyway.
        if [[ "${status}" -ne 0 && "${GITHUB_ACTIONS:-}" == "true" ]] && ! grep -q '^::' "$OUT"; then
            findings="$(grep -E 'needs formatting|warning:|error' "$OUT" | head -5 || true)"
            if [[ -z "${findings}" ]]; then
                findings="$(grep -v '^\s*$' "$OUT" | head -5 || true)"
            fi
            printf '::error title=SwiftFormat::Formatting check failed (exit %s) — run Scripts/ci/format.sh apply and review the diff. Output: %s\n' \
                "${status}" "$(printf '%s' "${findings}" | tr '\n' ';')"
        fi
        rm -f "$OUT"
        exit "${status}"
        ;;
    apply)
        run_swiftformat --config .swiftformat .
        ;;
    *)
        echo "Usage: $0 check|apply" >&2
        exit 2
        ;;
esac
