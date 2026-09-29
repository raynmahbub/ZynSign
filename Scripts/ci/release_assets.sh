#!/usr/bin/env bash
#
# ZynSign CI — release assets: the premium artifact set, generated from the
# tag and nothing else.
#
# One version, one naming scheme, five artifacts. Nothing here is typed by
# a human and nothing is renamed by hand afterwards:
#
#   ZynSign-v{VERSION}-unsigned.ipa    Payload/ zip of the archived .app
#   ZynSign-v{VERSION}-SHA256.txt      checksum, in `shasum` layout
#   BuildPassport-v{VERSION}.json      the build's fingerprint (internal)
#   MANIFEST.md                        what shipped, how big, how to verify
#   ReleaseNotes.md                    curated notes, else the CHANGELOG section
#
# The IPA is deliberately unsigned and says so everywhere: CI produces the
# reproducible record of what the tag built, while the privately tested
# signed IPA stays the public artifact (docs/releases/private-testing.md).
# Version-stamped names make that impossible to confuse — the two can never
# collide on a release.
#
# Usage:
#   Scripts/ci/release_assets.sh --app <ZynSign.app> --out <dir>
#   Scripts/ci/release_assets.sh --archive <ZynSign.xcarchive> --out <dir>
#
# Environment / flags:
#   VERSION, TAG, CHANNEL   release identity (default: the release train's
#                           current stop, via Scripts/release_train.py)
#   COMMIT                  commit SHA recorded in the passport
#   XCODE_VERSION, SWIFT_VERSION, BUILD_NUMBER, DEPLOYMENT_TARGET
#                           optional overrides; derived when absent
#
# Workflows call this script; CI logic lives here, never in YAML.
#
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/ci/crystal.sh
source "${HERE}/crystal.sh"

APP=""
ARCHIVE=""
OUT="build/release"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)     APP="$2"; shift 2 ;;
        --archive) ARCHIVE="$2"; shift 2 ;;
        --out)     OUT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

PBXPROJ="ZynSign.xcodeproj/project.pbxproj"

# --- identity ---------------------------------------------------------------
# The version is never invented here: it comes from the caller (the tag) or,
# failing that, from the release train — the same source release_meta.sh uses.
VERSION="${VERSION:-}"
if [[ -z "${VERSION}" ]]; then
    VERSION="$(python3 Scripts/release_train.py current)"
fi
VERSION="${VERSION#v}"
TAG="${TAG:-v${VERSION}}"
CHANNEL="${CHANNEL:-}"
if [[ -z "${CHANNEL}" ]]; then
    case "${VERSION}" in
        *-dev*)   CHANNEL="development" ;;
        *-alpha*) CHANNEL="alpha" ;;
        *-beta*)  CHANNEL="beta" ;;
        *-rc*)    CHANNEL="rc" ;;
        *)        CHANNEL="stable" ;;
    esac
fi
COMMIT="${COMMIT:-${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}}"

crystal_phase "${CRYSTAL_RELEASE}" "Release" "Assets • ${TAG}"

# --- locate the application -------------------------------------------------
if [[ -z "${APP}" && -n "${ARCHIVE}" ]]; then
    APP="${ARCHIVE}/Products/Applications/ZynSign.app"
fi
if [[ -z "${APP}" ]]; then
    crystal_fail "no --app or --archive given"
    exit 2
fi
if [[ ! -d "${APP}" ]]; then
    crystal_fail "application bundle not found at ${APP}"
    exit 2
fi
crystal_ok "Application bundle: ${APP}"

mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
IPA_NAME="ZynSign-${TAG}-unsigned.ipa"
SUM_NAME="ZynSign-${TAG}-SHA256.txt"
PASSPORT_NAME="BuildPassport-${TAG}.json"
IPA="${OUT}/${IPA_NAME}"
SUM="${OUT}/${SUM_NAME}"
PASSPORT="${OUT}/${PASSPORT_NAME}"
MANIFEST="${OUT}/MANIFEST.md"
NOTES="${OUT}/ReleaseNotes.md"

# --- toolchain facts (derived, never hardcoded) -----------------------------
if [[ -z "${XCODE_VERSION:-}" ]]; then
    XCODE_VERSION="$(xcodebuild -version 2>/dev/null | head -1 | sed 's/Xcode //')" || XCODE_VERSION=""
fi
if [[ -z "${SWIFT_VERSION:-}" ]]; then
    SWIFT_VERSION="$(xcrun swift --version 2>/dev/null | head -1 | sed -E 's/^Apple Swift version ([0-9.]+).*/\1/')" || SWIFT_VERSION=""
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(grep -oE 'CURRENT_PROJECT_VERSION = [0-9]+' "${PBXPROJ}" | head -1 | awk '{print $3}')}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-$(grep -oE 'IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+' "${PBXPROJ}" | head -1 | awk '{print $3}')}"
MARKETING="$(grep -oE 'MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+' "${PBXPROJ}" | head -1 | awk '{print $3}')"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
XCODE_VERSION="${XCODE_VERSION:-unknown}"
SWIFT_VERSION="${SWIFT_VERSION:-unknown}"

# --- 1. the unsigned IPA ----------------------------------------------------
crystal_phase "${CRYSTAL_RELEASE}" "Release" "Package"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
mkdir -p "${STAGE}/Payload"
cp -R "${APP}" "${STAGE}/Payload/"
rm -f "${IPA}"
(cd "${STAGE}" && zip -qry "${IPA}" Payload)
crystal_ok "${IPA_NAME}"

# --- 2. the checksum --------------------------------------------------------
if command -v shasum >/dev/null 2>&1; then
    CHECKSUM="$(shasum -a 256 "${IPA}" | awk '{print $1}')"
else
    CHECKSUM="$(sha256sum "${IPA}" | awk '{print $1}')"
fi
printf '%s  %s\n' "${CHECKSUM}" "${IPA_NAME}" > "${SUM}"
crystal_ok "${SUM_NAME} — ${CHECKSUM:0:16}…"

# --- 3. the build passport --------------------------------------------------
# How many staged features this release exposes, read from the train rather
# than counted by hand: the same numbers `release_train.py status` prints.
TRAIN_STATUS="$(python3 Scripts/release_train.py status 2>/dev/null || true)"
visible="$(printf '%s' "${TRAIN_STATUS}" | sed -n 's/^Visible in this release : //p')"
hidden="$(printf '%s' "${TRAIN_STATUS}" | sed -n 's/^Hidden until later *: //p')"
count_features() {
    local line="$1"
    [[ -z "${line}" || "${line}" == "nothing — feature complete" || "${line}" == core\ only* ]] && { printf '0'; return; }
    printf '%s' "${line}" | awk -F', ' '{print NF}'
}
VISIBLE_COUNT="$(count_features "${visible}")"
HIDDEN_COUNT="$(count_features "${hidden}")"

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

{
    printf '{\n'
    printf '  "app": "ZynSign",\n'
    printf '  "version": %s,\n' "$(json_escape "${VERSION}")"
    printf '  "tag": %s,\n' "$(json_escape "${TAG}")"
    printf '  "channel": %s,\n' "$(json_escape "${CHANNEL}")"
    printf '  "artifact": %s,\n' "$(json_escape "${IPA_NAME}")"
    printf '  "marketingVersion": %s,\n' "$(json_escape "${MARKETING:-unknown}")"
    printf '  "buildNumber": %s,\n' "$(json_escape "${BUILD_NUMBER:-unknown}")"
    printf '  "commit": %s,\n' "$(json_escape "${COMMIT}")"
    printf '  "buildDate": %s,\n' "$(json_escape "${BUILD_DATE}")"
    printf '  "xcode": %s,\n' "$(json_escape "${XCODE_VERSION}")"
    printf '  "swift": %s,\n' "$(json_escape "${SWIFT_VERSION}")"
    printf '  "ios": %s,\n' "$(json_escape "${DEPLOYMENT_TARGET:-unknown}")"
    printf '  "signed": false,\n'
    printf '  "checksum": %s,\n' "$(json_escape "sha256:${CHECKSUM}")"
    printf '  "releaseTrain": %s,\n' "$(json_escape "$(python3 Scripts/release_train.py current --tag 2>/dev/null || echo "${TAG}")")"
    printf '  "featuresVisible": %s,\n' "${VISIBLE_COUNT}"
    printf '  "featuresStagedLater": %s,\n' "${HIDDEN_COUNT}"
    printf '  "note": "Unsigned archive artifact produced by CI — the reproducible record of what this tag built. The privately tested signed IPA, once attached to this release, is the public build and is never overwritten."\n'
    printf '}\n'
} > "${PASSPORT}"

# A passport that is not valid JSON is worse than none.
if command -v jq >/dev/null 2>&1; then
    jq -e . "${PASSPORT}" >/dev/null
elif python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${PASSPORT}" 2>/dev/null; then :
else
    crystal_fail "${PASSPORT_NAME} is not valid JSON"
    exit 1
fi
crystal_ok "${PASSPORT_NAME} — ${VISIBLE_COUNT} feature(s) visible, ${HIDDEN_COUNT} staged later"

# --- 4. the release notes ---------------------------------------------------
NOTES_SOURCE="docs/releases/notes-v${VERSION}.md"
if [[ -f "${NOTES_SOURCE}" ]]; then
    cp "${NOTES_SOURCE}" "${NOTES}"
    crystal_ok "ReleaseNotes.md — curated notes (${NOTES_SOURCE})"
else
    {
        printf '# ZynSign %s\n\n' "${VERSION}"
        awk -v v="${VERSION}" '
            $0 ~ "^## \\[" v "\\]" { f = 1; print; next }
            f && /^## \[/ { exit }
            f { print }
        ' CHANGELOG.md
    } > "${NOTES}"
    if [[ "$(wc -l < "${NOTES}")" -le 2 ]]; then
        crystal_warn "no curated notes and no CHANGELOG [${VERSION}] section — ReleaseNotes.md is a stub"
    else
        crystal_ok "ReleaseNotes.md — from the CHANGELOG [${VERSION}] section"
    fi
fi

# --- 5. the manifest --------------------------------------------------------
bytes() {
    # GNU stat, then BSD/macOS stat, then a plain byte count.
    local b
    b="$(stat -c%s "$1" 2>/dev/null || true)"
    if [[ -n "${b}" ]]; then printf '%s' "${b}"; return 0; fi
    b="$(stat -f%z "$1" 2>/dev/null || true)"
    if [[ -n "${b}" ]]; then printf '%s' "${b}"; return 0; fi
    wc -c < "$1" | tr -d '[:space:]'
}
human() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1073741824) printf "%.2f GiB", b/1073741824;
        else if (b >= 1048576) printf "%.1f MiB", b/1048576;
        else if (b >= 1024) printf "%.0f KiB", b/1024;
        else printf "%d B", b;
    }'
}
{
    printf '# ZynSign %s — release manifest\n\n' "${TAG}"
    printf '_Generated by `Scripts/ci/release_assets.sh` on %s. Nothing in this file is written by hand._\n\n' "${BUILD_DATE}"
    printf '## Identity\n\n'
    printf '| | |\n| --- | --- |\n'
    printf '| Version | `%s` |\n' "${VERSION}"
    printf '| Tag | `%s` |\n' "${TAG}"
    printf '| Channel | %s |\n' "${CHANNEL}"
    printf '| Marketing version | `%s` |\n' "${MARKETING:-unknown}"
    printf '| Build number | `%s` |\n' "${BUILD_NUMBER:-unknown}"
    printf '| Minimum iOS | %s |\n' "${DEPLOYMENT_TARGET:-unknown}"
    printf '| Release train stop | `%s` |\n' "$(python3 Scripts/release_train.py current --tag 2>/dev/null || echo "${TAG}")"
    printf '| Features visible | %s (%s more staged for later stops) |\n\n' "${VISIBLE_COUNT}" "${HIDDEN_COUNT}"
    printf '## Provenance\n\n'
    printf '| | |\n| --- | --- |\n'
    printf '| Commit | `%s` |\n' "${COMMIT}"
    printf '| Built | %s |\n' "${BUILD_DATE}"
    printf '| Xcode | %s |\n' "${XCODE_VERSION}"
    printf '| Swift | %s |\n' "${SWIFT_VERSION}"
    printf '| Signed | **No** — CI never signs |\n\n'
    printf '## Assets\n\n'
    printf '| File | Size | SHA-256 |\n| --- | --- | --- |\n'
    for f in "${IPA_NAME}" "${SUM_NAME}" "${PASSPORT_NAME}" "MANIFEST.md" "ReleaseNotes.md"; do
        path="${OUT}/${f}"
        if [[ "${f}" == "MANIFEST.md" ]]; then
            printf '| `%s` | _this file_ | — |\n' "${f}"
        elif [[ -f "${path}" ]]; then
            size="$(human "$(bytes "${path}")")"
            if command -v shasum >/dev/null 2>&1; then
                hash="$(shasum -a 256 "${path}" | awk '{print $1}')"
            else
                hash="$(sha256sum "${path}" | awk '{print $1}')"
            fi
            printf '| `%s` | %s | `%s…` |\n' "${f}" "${size}" "${hash:0:16}"
        else
            printf '| `%s` | — | _written after this manifest_ |\n' "${f}"
        fi
    done
    printf '\n## Verify\n\n'
    printf '```sh\n'
    printf 'shasum -a 256 -c %s\n' "${SUM_NAME}"
    printf '```\n\n'
    printf '## Honesty\n\n'
    printf 'The IPA in this set is an **unsigned archive artifact**: it is the\n'
    printf 'reproducible record of what `%s` built, not a distributable build. The\n' "${TAG}"
    printf 'privately tested signed IPA — produced off CI per\n'
    printf '`docs/releases/private-testing.md` — is the public artifact, and the\n'
    printf 'publish step never overwrites it. In-app installation remains unavailable;\n'
    printf 'see `docs/product/WHAT_DOES_NOT_EXIST.md`.\n'
} > "${MANIFEST}"
crystal_ok "MANIFEST.md — 5 asset(s) listed"

# --- metrics + summary ------------------------------------------------------
mkdir -p build/metrics
{
    echo "version=${VERSION}"
    echo "tag=${TAG}"
    echo "channel=${CHANNEL}"
    echo "ipa=${IPA_NAME}"
    echo "checksum=${CHECKSUM}"
    echo "features_visible=${VISIBLE_COUNT}"
    echo "features_staged_later=${HIDDEN_COUNT}"
} > build/metrics/release_assets.txt

crystal_card_begin "${CRYSTAL_RELEASE}" "Release Assets" "Everything below is generated from the tag — no manual renaming" "Success"
crystal_card_row "Version" "\`${VERSION}\`"
crystal_card_row "Channel" "${CHANNEL}"
crystal_card_row "Artifact" "\`${IPA_NAME}\`"
crystal_card_row "Size" "$(human "$(bytes "${IPA}")")"
crystal_card_row "SHA-256" "\`${CHECKSUM:0:32}…\`"
crystal_card_row "Build" "\`${MARKETING:-unknown}\` (\`${BUILD_NUMBER:-unknown}\`) · iOS ${DEPLOYMENT_TARGET:-unknown}+"
crystal_card_row "Toolchain" "Xcode ${XCODE_VERSION} · Swift ${SWIFT_VERSION}"
crystal_card_row "Signed" "No — CI never signs"
crystal_card_row "Features" "${VISIBLE_COUNT} visible · ${HIDDEN_COUNT} staged later"
crystal_card_end

printf '\n'
ls -la "${OUT}"
