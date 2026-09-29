#!/usr/bin/env bash
#
# ZynSign CI — dependency validation.
#
# ZynSign is deliberately dependency-free: every capability is vendored.
# This check fails the moment a remote or local Swift package enters the
# project without being added to the allowlist, so adopting a dependency
# is always a visible, reviewed decision.
#
# Allowlist: Scripts/ci/dependency-allowlist.txt (one repository URL per
# line; '#' comments). Workflows call this script; CI logic lives here.
#
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Crystal Flow — the shared log and summary language (Scripts/ci/crystal.sh).
CRYSTAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/ci/crystal.sh
source "${CRYSTAL_DIR}/crystal.sh"
crystal_phase "${CRYSTAL_QUALITY}" "Quality" "Dependency allowlist"

PROJECT="ZynSign.xcodeproj/project.pbxproj"
ALLOWLIST="Scripts/ci/dependency-allowlist.txt"
METRICS_DIR="build/metrics"
mkdir -p "${METRICS_DIR}"

# Every remote package reference the project declares.
found_packages=$(grep -oE 'repositoryURL = "[^"]+"' "${PROJECT}" 2>/dev/null \
    | sed -E 's/repositoryURL = "(.*)"/\1/' | sort -u || true)

# Local package references are dependencies too.
local_packages=$(grep -c "XCLocalSwiftPackageReference" "${PROJECT}" 2>/dev/null || true)

violations=0
declare -a declared=()

if [[ -n "${found_packages}" ]]; then
    while IFS= read -r url; do
        declared+=("${url}")
        if ! grep -vE '^\s*(#|$)' "${ALLOWLIST}" 2>/dev/null | grep -qxF "${url}"; then
            echo "::error title=dependency-validation::Remote Swift package '${url}' is not on the allowlist (${ALLOWLIST})."
            violations=$((violations + 1))
        fi
    done <<<"${found_packages}"
fi

if [[ "${local_packages}" -gt 0 ]]; then
    echo "::error title=dependency-validation::${local_packages} local Swift package reference(s) found — local packages are not allowed."
    violations=$((violations + 1))
fi

# The resolved pin file, if one ever exists, must not name packages the
# project no longer declares.
if [[ -f "ZynSign.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" ]]; then
    resolved=$(grep -oE '"location" : "[^"]+"' \
        "ZynSign.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
        | sed -E 's/"location" : "(.*)"/\1/' | sort -u || true)
    while IFS= read -r url; do
        [[ -z "${url}" ]] && continue
        if ! grep -vE '^\s*(#|$)' "${ALLOWLIST}" 2>/dev/null | grep -qxF "${url}"; then
            echo "::error title=dependency-validation::Package.resolved pins '${url}' which is not on the allowlist."
            violations=$((violations + 1))
        fi
    done <<<"${resolved}"
fi

{
    echo "violations=${violations}"
    echo "dependency_count=${#declared[@]}"
    if [[ "${#declared[@]}" -gt 0 ]]; then
        printf 'dependency=%s\n' "${declared[@]}"
    fi
} > "${METRICS_DIR}/dependencies.txt"

if [[ "${violations}" -gt 0 ]]; then
    echo "Dependency validation FAILED — ${violations} violation(s)." >&2
    exit 1
fi

if [[ "${#declared[@]}" -eq 0 ]]; then
    echo "Dependency validation passed — the project remains dependency-free."
else
    echo "Dependency validation passed — ${#declared[@]} allowlisted package(s):"
    printf '  %s\n' "${declared[@]}"
fi
