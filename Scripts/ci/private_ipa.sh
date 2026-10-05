#!/usr/bin/env bash
#
# ZynSign CI — the private test IPA (docs/releases/private-testing.md).
#
# Archives the app for a real device and *always* produces an IPA:
#
#   TEAM_ID set       signed, ad-hoc exported
#                     ZynSign-{TAG}-{CONFIG}-private.ipa
#                     (installable on devices provisioned for the team)
#   TEAM_ID missing   unsigned Payload package — the raw archived .app zipped
#                     ZynSign-{TAG}-{CONFIG}-private-unsigned.ipa
#                     (re-sign before installing; a warning says so)
#
# The job's contract is "a green run contains an IPA": the script exits
# non-zero only when no IPA could be produced at all. Every fallback is
# annotated and repeated in the summary card, so a silent export skip can
# never masquerade as a delivered artifact again.
#
# The version is never typed: it comes from the release train
# (Scripts/release_train.py current --tag), the same source the release
# workflow uses, so the private candidate carries the version of the tag
# it is testing for. Debug builds expose every feature regardless of
# ReleaseTrain.current and are labelled as such — not release evidence.
#
# Usage:
#   Scripts/ci/private_ipa.sh [--configuration Release|Debug] [--output-dir DIR]
#
# Environment:
#   TEAM_ID   optional Apple Developer team id; enables automatic signing
#   NOTE      optional free-text label; folded into the artifact name only
#             (sanitized), never into the IPA file name
#
# Outputs (appended to $GITHUB_OUTPUT when set):
#   ipa_name, ipa_path, ipa_signed (true|false), tag, version,
#   configuration, artifact_name
#
# The committed ExportOptions template is never modified: the team id is
# injected into a temporary copy at export time.
#
# Workflows call this script; CI logic lives here, never in YAML.
#
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/ci/crystal.sh
source "${HERE}/crystal.sh"

CONFIGURATION="Release"
OUT_DIR="build/private"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --output-dir)    OUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "${CONFIGURATION}" in
    Release|Debug) ;;
    *) crystal_fail "configuration must be Release or Debug, got '${CONFIGURATION}'" "Private IPA"; exit 2 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
    crystal_fail "private_ipa.sh requires macOS with Xcode (device archive)" "Private IPA"
    exit 2
fi

TEAM_ID="${TEAM_ID:-}"
NOTE="${NOTE:-}"

crystal_phase "${CRYSTAL_BUILD}" "Build" "Private IPA • ${CONFIGURATION}"

# --- candidate identity -----------------------------------------------------
TAG="$(python3 Scripts/release_train.py current --tag)"
VERSION="${TAG#v}"
SHORT_SHA="${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
SHORT_SHA="${SHORT_SHA:0:7}"
crystal_ok "Release train stop: ${TAG}"
crystal_info "Configuration: ${CONFIGURATION}"
if [[ "${CONFIGURATION}" == "Debug" ]]; then
    crystal_warn "Debug exposes EVERY feature regardless of ReleaseTrain.current — it is not release evidence." "Private IPA"
fi

# Artifact names must survive GitHub's invalid set (" : < > | * ? \r \n / \).
slugify() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
ARCHIVE="${OUT_DIR}/ZynSign-private.xcarchive"
ARCHIVE_LOG="${OUT_DIR}/archive.log"
EXPORT_LOG="${OUT_DIR}/export.log"

# --- 1. archive for a real device ------------------------------------------
crystal_phase "${CRYSTAL_BUILD}" "Build" "Archive"
if [[ -n "${TEAM_ID}" ]]; then
    crystal_info "TEAM_ID present — archiving with automatic signing"
    status=0
    xcodebuild archive \
        -project ZynSign.xcodeproj -scheme ZynSign \
        -configuration "${CONFIGURATION}" \
        -archivePath "${ARCHIVE}" \
        -destination 'generic/platform=iOS' \
        DEVELOPMENT_TEAM="${TEAM_ID}" \
        CODE_SIGN_STYLE=Automatic \
        2>&1 | tee "${ARCHIVE_LOG}" || status="${PIPESTATUS[0]}"
else
    crystal_info "No TEAM_ID secret — archiving unsigned so CI still verifies the product builds"
    status=0
    xcodebuild archive \
        -project ZynSign.xcodeproj -scheme ZynSign \
        -configuration "${CONFIGURATION}" \
        -archivePath "${ARCHIVE}" \
        -destination 'generic/platform=iOS' \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        2>&1 | tee "${ARCHIVE_LOG}" || status="${PIPESTATUS[0]}"
fi
if [[ "${status}" -ne 0 ]]; then
    crystal_fail "Archive failed (exit ${status}) — see archive.log in the artifact" "Private IPA"
    tail -n 120 "${ARCHIVE_LOG}" || true
    exit "${status}"
fi
crystal_ok "Archive complete"

APP="${ARCHIVE}/Products/Applications/ZynSign.app"
if [[ ! -d "${APP}" ]]; then
    crystal_fail "the archive contains no ZynSign.app — nothing to package" "Private IPA"
    exit 1
fi

# --- 2. the IPA -------------------------------------------------------------
# With signing material: the real deliverable, an ad-hoc export installable
# on provisioned devices. Without it (or when the export fails): an unsigned
# Payload package of the same app, honestly named, so the artifact always
# contains an IPA instead of only logs.
IPA_SIGNED="false"
EXPORT_DIR="$(mktemp -d)"
trap 'rm -rf "${EXPORT_DIR}"' EXIT

if [[ -n "${TEAM_ID}" ]]; then
    crystal_phase "${CRYSTAL_BUILD}" "Build" "Export"
    # Inject the team id into a temporary copy — the committed template
    # stays untouched even if this step is cancelled mid-export.
    EXPORT_OPTIONS="${EXPORT_DIR}/ExportOptions.plist"
    cp docs/releases/ExportOptions-private-adhoc.plist "${EXPORT_OPTIONS}"
    /usr/libexec/PlistBuddy -c "Set :teamID ${TEAM_ID}" "${EXPORT_OPTIONS}"
    export_status=0
    xcodebuild -exportArchive \
        -archivePath "${ARCHIVE}" \
        -exportPath "${EXPORT_DIR}/out" \
        -exportOptionsPlist "${EXPORT_OPTIONS}" \
        2>&1 | tee "${EXPORT_LOG}" || export_status="${PIPESTATUS[0]}"
    if [[ "${export_status}" -eq 0 && -f "${EXPORT_DIR}/out/ZynSign.ipa" ]]; then
        IPA_SIGNED="true"
    else
        crystal_warn "Signed export failed (exit ${export_status}) — falling back to an unsigned IPA. See export.log." "Private IPA"
        tail -n 60 "${EXPORT_LOG}" || true
    fi
else
    crystal_warn "No TEAM_ID secret — the IPA will be unsigned and must be re-signed before it can be installed." "Private IPA"
    : > "${EXPORT_LOG}"
fi

if [[ "${IPA_SIGNED}" == "true" ]]; then
    IPA_NAME="ZynSign-${TAG}-${CONFIGURATION}-private.ipa"
    mv "${EXPORT_DIR}/out/ZynSign.ipa" "${OUT_DIR}/${IPA_NAME}"
else
    IPA_NAME="ZynSign-${TAG}-${CONFIGURATION}-private-unsigned.ipa"
    STAGE="$(mktemp -d)"
    mkdir -p "${STAGE}/Payload"
    cp -R "${APP}" "${STAGE}/Payload/"
    rm -f "${OUT_DIR}/${IPA_NAME}"
    (cd "${STAGE}" && zip -qry "${OUT_DIR}/${IPA_NAME}" Payload)
    rm -rf "${STAGE}"
fi
IPA="${OUT_DIR}/${IPA_NAME}"

# --- 3. checksum ------------------------------------------------------------
if command -v shasum >/dev/null 2>&1; then
    CHECKSUM="$(shasum -a 256 "${IPA}" | awk '{print $1}')"
else
    CHECKSUM="$(sha256sum "${IPA}" | awk '{print $1}')"
fi
printf '%s  %s\n' "${CHECKSUM}" "${IPA_NAME}" > "${OUT_DIR}/${IPA_NAME}.sha256"

# --- 4. outputs -------------------------------------------------------------
ARTIFACT_NAME="ZynSign-private-${TAG}-${CONFIGURATION}-${SHORT_SHA}"
if [[ -n "${NOTE}" ]]; then
    NOTE_SLUG="$(slugify "${NOTE}")"
    [[ -n "${NOTE_SLUG}" ]] && ARTIFACT_NAME="${ARTIFACT_NAME}-${NOTE_SLUG}"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "ipa_name=${IPA_NAME}"
        echo "ipa_path=${IPA}"
        echo "ipa_signed=${IPA_SIGNED}"
        echo "tag=${TAG}"
        echo "version=${VERSION}"
        echo "configuration=${CONFIGURATION}"
        echo "artifact_name=${ARTIFACT_NAME}"
    } >> "${GITHUB_OUTPUT}"
fi

# --- 5. summary card --------------------------------------------------------
bytes() {
    local b
    b="$(stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || true)"
    printf '%s' "${b:-unknown}"
}
human() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1048576) printf "%.1f MiB", b/1048576;
        else if (b >= 1024) printf "%.0f KiB", b/1024;
        else printf "%d B", b;
    }' 2>/dev/null || printf '%s B' "$1"
}

if [[ "${IPA_SIGNED}" == "true" ]]; then
    STATUS_LINE="Signed ad-hoc — installable on provisioned devices"
    NEXT_LINE="Run the device matrix in \\`docs/releases/private-testing.md\\`, then tag \\`${TAG}\\`"
else
    STATUS_LINE="Unsigned — re-sign before installing"
    NEXT_LINE="Set the \\`TEAM_ID\\` secret for a signed export; re-sign this IPA to install it"
fi
crystal_card_begin "${CRYSTAL_BUILD}" "Private Test Build" "Never a tag, never a release" "Success"
crystal_card_row "Candidate" "\\`${TAG}\\` (${SHORT_SHA})"
crystal_card_row "Configuration" "${CONFIGURATION}"
crystal_card_row "Artifact" "\\`${IPA_NAME}\\`"
crystal_card_row "Size" "$(human "$(bytes "${IPA}")")"
crystal_card_row "SHA-256" "\\`${CHECKSUM:0:32}…\\`"
crystal_card_row "Signing" "${STATUS_LINE}"
crystal_card_row "Next" "${NEXT_LINE}"
crystal_card_end

crystal_ok "${IPA_NAME} — $(human "$(bytes "${IPA}")")"
ls -la "${OUT_DIR}"
