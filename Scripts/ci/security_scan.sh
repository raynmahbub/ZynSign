#!/usr/bin/env bash
#
# ZynSign CI — secret scanning.
#
# Fails immediately when committed material looks like a secret:
#
#   * private-key PEM blocks anywhere except the Compatibility Lab's
#     fixed detection markers
#   * certificate PEM text outside Tests/ (synthetic fixtures only)
#   * well-known token shapes (AWS keys, GitHub tokens, Slack tokens,
#     Stripe live keys) anywhere in sources and scripts
#
# The same policy runs in 02-quality.yml's secret-policy job; this script makes
# it reproducible locally and pairs with Gitleaks (used on the full history
# by 02-quality.yml's gitleaks job). If `gitleaks` is installed it runs too.
#
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Crystal Flow — the shared log and summary language (Scripts/ci/crystal.sh).
CRYSTAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/ci/crystal.sh
source "${CRYSTAL_DIR}/crystal.sh"
crystal_phase "${CRYSTAL_QUALITY}" "Quality" "Secret policy"

METRICS_DIR="build/metrics"
mkdir -p "${METRICS_DIR}"
findings=0

fail() {
    echo "::error title=security-scan::$1" >&2
    echo "FINDING: $1" >&2
    findings=$((findings + 1))
}

echo "Scanning for private-key material…"
if grep -rniE "BEGIN (RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY" \
        --exclude-dir=.git --exclude-dir=node_modules \
        --exclude=CompatibilityLabSecurity.swift . ; then
    fail "Private key material found (CompatibilityLabSecurity.swift carries the only allowed detection markers)."
fi

echo "Scanning for certificate material outside test fixtures…"
if grep -rniE "BEGIN CERT[I]FICATE" \
        --exclude-dir=.git --exclude-dir=node_modules \
        --exclude-dir=Tests . ; then
    fail "Certificate material found outside Tests/ (synthetic fixtures are the only allowed source)."
fi

echo "Scanning for well-known token shapes…"
token_hits=$(grep -rnE \
    "AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|ghs_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk_live_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{35}" \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=build \
    ZynSign Scripts docs .github 2>/dev/null || true)
if [[ -n "${token_hits}" ]]; then
    echo "${token_hits}" >&2
    fail "Possible API key or token committed in the repository."
fi

# Gitleaks covers the full history with the default rule set when present.
if command -v gitleaks >/dev/null 2>&1; then
    echo "Running Gitleaks over the full history…"
    if ! gitleaks detect --config .gitleaks.toml --no-banner --redact; then
        fail "Gitleaks found secret material in the history."
    fi
else
    echo "gitleaks not installed — the history scan runs in 02-quality.yml's gitleaks job."
fi

echo "findings=${findings}" > "${METRICS_DIR}/security.txt"

if [[ "${findings}" -gt 0 ]]; then
    echo "Security scan FAILED — ${findings} finding(s). Rotate anything that may have leaked." >&2
    exit 1
fi
echo "Security scan passed — no secret material detected."
