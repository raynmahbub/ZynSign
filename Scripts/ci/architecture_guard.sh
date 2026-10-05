#!/usr/bin/env bash
#
# ZynSign CI — Architecture Guard (, the most important check).
#
# ZynSign is layered: Domain must stay pure, Platform owns the OS, the
# Application layer composes, Presentation renders, App wires. Everything
# compiles into one module, so the Swift compiler cannot enforce these
# boundaries — this script does, on every run:
#
#   1. Domain imports        — allowlist: Foundation / CoreFoundation /
#                              Observation / Dispatch. SwiftUI, UIKit,
#                              Security, WebKit (and everything else) fail.
#   2. Presentation imports  — may not import Security, CryptoKit,
#                              CommonCrypto, WebKit, LocalAuthentication.
#   3. Platform imports      — may not import SwiftUI or WebKit.
#   4. Application imports   — may not import SwiftUI.
#   5. Security boundary     — Presentation may not reference the Platform's
#                              keychain / signing / certificate internals.
#   6. Service boundary      — Presentation may only touch the concrete
#                              Platform services on its allowlist; anything
#                              new must come through the Application layer.
#   7. No upward reach       — Platform may not reference Presentation
#                              types (circular dependency detection).
#   8. Domain purity ratchet — Domain may not reference upper-layer types
#                              beyond Scripts/ci/architecture-baseline.txt.
#
# Any violation fails the run immediately. Workflows call this script;
# CI logic lives here, never in YAML.
#
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Crystal Flow — the shared log and summary language (Scripts/ci/crystal.sh).
CRYSTAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/ci/crystal.sh
source "${CRYSTAL_DIR}/crystal.sh"
crystal_phase "${CRYSTAL_QUALITY}" "Quality" "Architecture guard"

SRC="ZynSign"
BASELINE_FILE="Scripts/ci/architecture-baseline.txt"
METRICS_DIR="build/metrics"
mkdir -p "${METRICS_DIR}"

VIOLATIONS=0
RULES_CHECKED=0
FINDINGS=""

violation() { # rule, location, message
    local rule="$1" location="$2" message="$3"
    echo "::error file=$(crystal_escape "${location%%:*}"),title=$(crystal_escape "architecture-guard ${rule}")::$(crystal_escape "${message}")"
    FINDINGS="${FINDINGS}  [${rule}] ${location} — ${message}"$'\n'
    VIOLATIONS=$((VIOLATIONS + 1))
}

# --- A stripped mirror of the sources --------------------------------------
# Word searches run against copies with string literals and // comments
# removed, so prose can never be mistaken for a dependency.
STRIPPED="$(mktemp -d)"
trap 'rm -rf "${STRIPPED}"' EXIT

strip_into() { # source-file, destination-file
    sed -E -e 's/"([^"\\]|\\.)*"/""/g' -e 's|//.*$||' "$1" > "$2"
}

for layer in Domain Platform Presentation Application App; do
    mkdir -p "${STRIPPED}/${layer}"
    while IFS= read -r f; do
        rel="${f#${SRC}/}"
        mkdir -p "${STRIPPED}/$(dirname "${rel}")"
        strip_into "$f" "${STRIPPED}/${rel}"
    done < <(find "${SRC}/${layer}" -name '*.swift' 2>/dev/null)
done

# Word references to a type inside a layer's stripped sources (file:line).
word_refs() { # name, layer...
    local name="$1"; shift
    grep -rnw "${name}" "$@" 2>/dev/null | cut -d: -f1,2 | sed "s|^${STRIPPED}/||" || true
}

# Top-level type names declared by a layer.
declared_types() { # layer...
    grep -rhoE "^(@[A-Za-z]+ )*(public |open |package |internal |final |indirect |nonisolated )*(struct|class|enum|actor|protocol) [A-Z][A-Za-z0-9_]+" \
        "$@" --include='*.swift' 2>/dev/null | awk '{print $NF}' | sort -u
}

DOMAIN_TYPES=$(declared_types "${SRC}/Domain")
PLATFORM_TYPES=$(declared_types "${SRC}/Platform")
PRESENTATION_TYPES=$(declared_types "${SRC}/Presentation")

# --- Rule 1: Domain import allowlist ----------------------------------------
RULES_CHECKED=$((RULES_CHECKED + 1))
DOMAIN_ALLOWED="Foundation CoreFoundation Observation Dispatch"
DOMAIN_FORBIDDEN_MESSAGE="SwiftUI/UIKit/Security/WebKit are forbidden in Domain"
while IFS= read -r hit; do
    [[ -z "${hit}" ]] && continue
    file="${hit%%:*}"; line="${hit#*:}"
    module=$(sed -n "${line}p" "${file}" \
        | sed -E 's/^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+//' \
        | awk '{print $1}' | cut -d. -f1)
    allowed=0
    for ok in ${DOMAIN_ALLOWED}; do
        [[ "${module}" == "${ok}" ]] && allowed=1
    done
    if [[ "${allowed}" -eq 0 ]]; then
        message="Domain imports '${module}' (allowed: ${DOMAIN_ALLOWED// /, })"
        case "${module}" in
            SwiftUI|UIKit|Security|WebKit)
                message="Domain imports '${module}' — ${DOMAIN_FORBIDDEN_MESSAGE}" ;;
        esac
        violation "domain-import" "${file}:${line}" "${message}"
    fi
done < <(grep -rnE "^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+" \
            "${SRC}/Domain" --include='*.swift' 2>/dev/null | cut -d: -f1,2 || true)

# --- Rule 2: Presentation forbidden imports ---------------------------------
RULES_CHECKED=$((RULES_CHECKED + 1))
for forbidden in Security CryptoKit CommonCrypto WebKit LocalAuthentication; do
    while IFS= read -r hit; do
        [[ -z "${hit}" ]] && continue
        violation "presentation-import" "${hit}" \
            "Presentation imports '${forbidden}' — security and web stack belong to the Platform layer"
    done < <(grep -rnE "^[[:space:]]*import[[:space:]]+${forbidden}([[:space:]]|$)" \
                "${SRC}/Presentation" --include='*.swift' 2>/dev/null | cut -d: -f1,2 || true)
done

# --- Rule 3: Platform must not import SwiftUI / WebKit ----------------------
RULES_CHECKED=$((RULES_CHECKED + 1))
for forbidden in SwiftUI WebKit; do
    while IFS= read -r hit; do
        [[ -z "${hit}" ]] && continue
        violation "platform-import" "${hit}" \
            "Platform imports '${forbidden}' — Platform must stay UI-free"
    done < <(grep -rnE "^[[:space:]]*import[[:space:]]+${forbidden}([[:space:]]|$)" \
                "${SRC}/Platform" --include='*.swift' 2>/dev/null | cut -d: -f1,2 || true)
done

# --- Rule 4: Application must not import SwiftUI ----------------------------
RULES_CHECKED=$((RULES_CHECKED + 1))
while IFS= read -r hit; do
    [[ -z "${hit}" ]] && continue
    violation "application-import" "${hit}" \
        "Application imports SwiftUI — views live in Presentation; Application composes services"
done < <(grep -rnE "^[[:space:]]*import[[:space:]]+SwiftUI([[:space:]]|$)" \
            "${SRC}/Application" --include='*.swift' 2>/dev/null | cut -d: -f1,2 || true)

# --- Rule 5: Presentation must not touch security internals -----------------
RULES_CHECKED=$((RULES_CHECKED + 1))
SECURITY_DENYLIST="
    AppleCertificateParser AppleCMSSignatureVerifier ApplePKCS12Importer
    AppleSignatureVerifier AppleSigningKeyResolver CertificateAlgorithmIdentifiers
    CertificateDERParser CertificateDigest CMSStructureReader CryptoKitMessageDigest
    DetachedCodeSignatureCMS DetachedCodeSignatureCMSInspector KeychainIdentityRegistry
    MachOCodeSignatureInspector MachOCodeSignatureWriter ProvisioningProfileCMSVerifier
    SecureIdentityStore SecurityScopedArtifactIntake StoredSigningIdentity
"
for name in ${SECURITY_DENYLIST}; do
    while IFS= read -r ref; do
        [[ -z "${ref}" ]] && continue
        violation "security-boundary" "${ref}" \
            "Presentation references '${name}' — keychain/signing internals are reachable only through Application services"
    done < <(word_refs "${name}" "${STRIPPED}/Presentation")
done

# --- Rule 6: Presentation's concrete Platform surface is an allowlist --------
RULES_CHECKED=$((RULES_CHECKED + 1))
# RecoveryCenterView speaks to the Recovery feature's Platform types
# directly; the rest of Presentation must still route new Platform
# services through the Application layer.
PRESENTATION_PLATFORM_ALLOWLIST="
    AudioPlaybackService BackupCategory BackupHistoryItem BackupManifest
    DeliveryQRCodeRenderer FilePreferencesStore LiveActivityService
    LocalAuthenticationBiometricAuthenticator LocalDownloadNotifier
    LocalSigningQueueNotifier RecoveryStore StoreImageCache
"
for name in ${PLATFORM_TYPES}; do
    skip=0
    for ok in ${PRESENTATION_PLATFORM_ALLOWLIST}; do
        [[ "${name}" == "${ok}" ]] && skip=1
    done
    [[ "${skip}" -eq 1 ]] && continue
    # A name Presentation declares itself is not a Platform dependency.
    if grep -qx "${name}" <<<"${PRESENTATION_TYPES}"; then continue; fi
    while IFS= read -r ref; do
        [[ -z "${ref}" ]] && continue
        violation "service-boundary" "${ref}" \
            "Presentation references concrete Platform type '${name}' — route it through the Application layer or extend PRESENTATION_PLATFORM_ALLOWLIST with review"
    done < <(word_refs "${name}" "${STRIPPED}/Presentation")
done

# --- Rule 7: Platform must not reach up into Presentation --------------------
RULES_CHECKED=$((RULES_CHECKED + 1))
for name in ${PRESENTATION_TYPES}; do
    # Short or ambiguous names and names Platform declares itself are noise.
    [[ "${#name}" -lt 7 ]] && continue
    if grep -qx "${name}" <<<"${PLATFORM_TYPES}"; then continue; fi
    while IFS= read -r ref; do
        [[ -z "${ref}" ]] && continue
        violation "circular-dependency" "${ref}" \
            "Platform references Presentation type '${name}' — dependencies flow downward only"
    done < <(word_refs "${name}" "${STRIPPED}/Platform")
done

# --- Rule 8: Domain purity ratchet -------------------------------------------
RULES_CHECKED=$((RULES_CHECKED + 1))
BASELINE_NAMES=$(grep -E '^Domain ' "${BASELINE_FILE}" 2>/dev/null | awk '{print $2}' || true)
UPPER_TYPES=$(printf '%s\n%s\n%s\n' \
    "$(declared_types "${SRC}/Platform")" \
    "$(declared_types "${SRC}/Presentation")" \
    "$(declared_types "${SRC}/Application")" | sort -u)
for name in ${UPPER_TYPES}; do
    [[ "${#name}" -lt 7 ]] && continue
    if grep -qx "${name}" <<<"${DOMAIN_TYPES}"; then continue; fi
    if grep -qx "${name}" <<<"${BASELINE_NAMES}"; then continue; fi
    while IFS= read -r ref; do
        [[ -z "${ref}" ]] && continue
        violation "domain-purity" "${ref}" \
            "Domain references upper-layer type '${name}' — Domain depends on nothing above itself (baseline: ${BASELINE_FILE})"
    done < <(word_refs "${name}" "${STRIPPED}/Domain")
done

# --- Report -------------------------------------------------------------------
{
    echo "violations=${VIOLATIONS}"
    echo "rules_checked=${RULES_CHECKED}"
    echo "domain_import_allowlist=${DOMAIN_ALLOWED// /,}"
    echo "presentation_platform_allowlist=$(printf '%s' "${PRESENTATION_PLATFORM_ALLOWLIST}" | tr -s ' \n' ',' | sed -e 's/^,//' -e 's/,$//')"
} > "${METRICS_DIR}/architecture.txt"

echo "Architecture Guard: ${RULES_CHECKED} rules checked."
if [[ "${VIOLATIONS}" -gt 0 ]]; then
    echo "Architecture Guard FAILED — ${VIOLATIONS} violation(s):" >&2
    printf '%s' "${FINDINGS}" >&2
    exit 1
fi
echo "Architecture Guard passed — no boundary violations."
