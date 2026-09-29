#!/usr/bin/env bash
#
# ZynSign CI — release quality gate, part 1: validation.
#
# Everything that can be checked without building is checked here, and
# any failure stops the release:
#
#   * the tag is the release train's current stage (release_train.py)
#   * MARKETING_VERSION in the Xcode project agrees with the tag
#   * CHANGELOG.md carries an entry for the version
#   * release notes exist (warning — the workflow can fall back to
#     auto-generated notes, but the train expects a notes file)
#   * a build number is declared
#
# Usage:
#   Scripts/ci/release_validate.sh <version-without-v>   e.g. 0.1.0-alpha.1
#
# Workflows call this script; CI logic lives here, never in YAML.
#
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Crystal Flow — the shared log and summary language (Scripts/ci/crystal.sh).
CRYSTAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/ci/crystal.sh
source "${CRYSTAL_DIR}/crystal.sh"
crystal_phase "${CRYSTAL_RELEASE}" "Release" "Validation"

VERSION="${1:-${VERSION:-}}"
if [[ -z "${VERSION}" ]]; then
    echo "Usage: $0 <version without leading v>" >&2
    exit 2
fi
TAG="v${VERSION}"
PBXPROJ="ZynSign.xcodeproj/project.pbxproj"

failures=0
warnings=0
# Crystal Flow: ✓ / ⚠ / ✗ in the log, and the matching GitHub annotation when
# running in Actions (crystal.sh emits ::warning and ::error itself).
fail()  { crystal_fail "$1";  failures=$((failures + 1)); }
warnf() { crystal_warn "$1";  warnings=$((warnings + 1)); }
ok()    { crystal_ok "$1"; }

echo "=== Release validation for ${TAG} ==="

# 1. The tag must be the release train's current stage. The train is the
#    single source of truth for which features a release switches on.
if python3 Scripts/release_train.py check --tag "${TAG}"; then
    ok "tag ${TAG} is the current release-train stage"
else
    fail "tag ${TAG} is not the current release-train stage (see docs/releases/release-train.md)"
fi

# 2. Marketing version consistency: the numeric part of the tag must equal
#    MARKETING_VERSION (pre-release suffixes live only in the tag).
marketing=$(grep -oE 'MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+' "${PBXPROJ}" | head -1 | awk '{print $3}')
tag_base="${VERSION%%-*}"
if [[ "${marketing}" == "${tag_base}" ]]; then
    ok "MARKETING_VERSION ${marketing} matches tag base ${tag_base}"
else
    fail "MARKETING_VERSION (${marketing:-missing}) does not match tag base ${tag_base}"
fi

# 3. Build number present and numeric.
build_number=$(grep -oE 'CURRENT_PROJECT_VERSION = [0-9]+' "${PBXPROJ}" | head -1 | awk '{print $3}')
if [[ -n "${build_number}" ]]; then
    ok "build number ${build_number} declared"
else
    fail "CURRENT_PROJECT_VERSION missing from ${PBXPROJ}"
fi

# 4. CHANGELOG entry for the version (generate_changelog.py inserts
#    '## [version] - date'); the release workflow regenerates a missing
#    entry, but a release that skips the changelog is a process error.
if grep -q "^## \[${VERSION}\]" CHANGELOG.md; then
    ok "CHANGELOG.md has a [${VERSION}] section"
else
    warnf "CHANGELOG.md has no [${VERSION}] section yet — the release workflow will generate one"
fi

# 5. Release notes file for the tag.
notes="docs/releases/notes-v${VERSION}.md"
if [[ -f "${notes}" ]]; then
    ok "release notes exist (${notes})"
else
    warnf "no release notes at ${notes} — the release will fall back to auto-generated notes"
fi

# 6. Deployment target sanity (the Build Passport records it).
deploy_target=$(grep -oE 'IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+' "${PBXPROJ}" | head -1 | awk '{print $3}')
if [[ -n "${deploy_target}" ]]; then
    ok "iOS deployment target ${deploy_target}"
else
    fail "IPHONEOS_DEPLOYMENT_TARGET missing from ${PBXPROJ}"
fi

mkdir -p build/metrics
{
    echo "version=${VERSION}"
    echo "tag=${TAG}"
    echo "marketing_version=${marketing}"
    echo "build_number=${build_number}"
    echo "deployment_target=${deploy_target}"
    echo "failures=${failures}"
    echo "warnings=${warnings}"
} > build/metrics/release_validate.txt

if [[ "${failures}" -gt 0 ]]; then
    echo "Release validation FAILED — ${failures} failure(s), ${warnings} warning(s). The release stops here." >&2
    exit 1
fi
echo "Release validation passed (${warnings} warning(s))."
