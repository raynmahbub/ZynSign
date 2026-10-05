#!/usr/bin/env bash
#
# ZynSign CI — build validation entry point.
#
# Resolves packages, cleans DerivedData, builds every target, builds the
# test targets, and runs the unit tests. Every xcodebuild invocation is
# logged under build/logs/ so a failing run can upload its evidence.
#
# Workflows call this script; CI logic lives here, never in YAML.
#
# Environment overrides:
#   PROJECT         Xcode project (default: ZynSign.xcodeproj)
#   SCHEME          Scheme to build and test (default: ZynSign)
#   SIMULATOR       Test destination name (default: iPhone 16)
#   RUN_TESTS       1 = run unit tests (default), 0 = build only
#   BUILD_LOGS_DIR  Log directory (default: build/logs)
#   SKIP_CLEAN      1 = keep DerivedData (local re-runs), default cleans
#
set -euo pipefail

# Crystal Flow — the shared log and summary language (Scripts/ci/crystal.sh).
CRYSTAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/ci/crystal.sh
source "${CRYSTAL_DIR}/crystal.sh"
crystal_phase "${CRYSTAL_BUILD}" "Build" "Compile and test"

PROJECT="${PROJECT:-ZynSign.xcodeproj}"
SCHEME="${SCHEME:-ZynSign}"
# Empty = resolve the first available iPhone simulator at test time
# (see Scripts/ci/select_simulator.sh); device names drift across images.
SIMULATOR="${SIMULATOR:-}"
RUN_TESTS="${RUN_TESTS:-1}"
BUILD_LOGS_DIR="${BUILD_LOGS_DIR:-build/logs}"
SKIP_CLEAN="${SKIP_CLEAN:-0}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "build.sh requires macOS with Xcode (run inside a macOS CI job)." >&2
    exit 2
fi

mkdir -p "${BUILD_LOGS_DIR}"
DERIVED_DATA="build/DerivedData"

log() { printf '\n=== build.sh: %s ===\n' "$*"; }

run_logged() {
    # run_logged <logfile> <description> <command...>
    local logfile="$1"; shift
    local description="$1"; shift
    log "${description} (log: ${logfile})"
    local status=0
    "$@" 2>&1 | tee "${logfile}" || status="${PIPESTATUS[0]}"
    if [[ "${status}" -ne 0 ]]; then
        echo "FAILED: ${description} — see ${logfile}" >&2
        # On CI, surface the concrete errors as annotations so the
        # failure reason is readable without opening the raw log.
        if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
            local toolchain
            toolchain="$(xcodebuild -version 2>/dev/null | tr '\n' ' '); runtimes: $(xcrun simctl list runtimes 2>/dev/null | sed -n '2,5p' | sed 's/;/ /g' | tr '\n' '|')"
            printf '::notice title=Toolchain::%s\n' "$(crystal_escape "${toolchain}")"
            local bundle="${RESULT_BUNDLE:-}"
            if [[ -n "${bundle}" && -d "${bundle}" ]]; then
                # Test run: the result bundle records every failed test
                # and its failure text — the log alone rarely does.
                "$(dirname "$0")/annotate_test_failures.sh" \
                    "${bundle}" "${logfile}" || true
            else
                local errors
                errors="$(sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' "${logfile}" \
                    | grep -E '(^|: )error:' | tail -50 || true)"
                if [[ -z "${errors}" ]]; then
                    errors="$(tail -5 "${logfile}")"
                fi
                if [[ -n "${errors}" ]]; then
                    while IFS= read -r line; do
                        printf '::error title=xcodebuild::%s\n' "$(crystal_escape "${line}")"
                    done <<< "${errors}"
                fi
            fi
        fi
        exit "${status}"
    fi
}

# 1. Clean DerivedData so stale module state can never mask a breakage.
if [[ "${SKIP_CLEAN}" != "1" ]]; then
    log "Cleaning DerivedData"
    rm -rf "${DERIVED_DATA}"
    rm -rf "${HOME}/Library/Developer/Xcode/DerivedData/${SCHEME}-"* 2>/dev/null || true
fi

# 2. Resolve Swift Package dependencies. The project currently vendors no
#    external packages; the step still proves resolution works and primes
#    the cache for the day a package is adopted.
run_logged "${BUILD_LOGS_DIR}/resolve-packages.log" "Resolving Swift packages" \
    xcodebuild -resolvePackageDependencies \
        -project "${PROJECT}" \
        -scheme "${SCHEME}" \
        -derivedDataPath "${DERIVED_DATA}" \
        -quiet

# 3. Build every target for the generic iOS Simulator platform.
run_logged "${BUILD_LOGS_DIR}/build.log" "Building all targets" \
    xcodebuild build \
        -project "${PROJECT}" \
        -scheme "${SCHEME}" \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "${DERIVED_DATA}" \
        -quiet

if [[ "${RUN_TESTS}" != "1" ]]; then
    log "RUN_TESTS=0 — skipping the test run"
    exit 0
fi

# Resolve the simulator dynamically unless the caller pinned one; the
# selector installs the runtime when the runner image has none.
if [[ -z "${SIMULATOR}" ]]; then
    log "Selecting an available iPhone simulator"
    SIMULATOR="$("$(dirname "$0")/select_simulator.sh")"
fi

# 4. Build the test targets explicitly, then 5. run the unit tests.
run_logged "${BUILD_LOGS_DIR}/build-for-testing.log" "Building test targets" \
    xcodebuild build-for-testing \
        -project "${PROJECT}" \
        -scheme "${SCHEME}" \
        -destination "platform=iOS Simulator,name=${SIMULATOR},OS=latest" \
        -derivedDataPath "${DERIVED_DATA}" \
        -quiet

RESULT_BUNDLE="${BUILD_LOGS_DIR}/ZynSignTests.xcresult"
rm -rf "${RESULT_BUNDLE}"
# The test run deliberately omits -quiet: per-case failure lines are the
# human-readable backup for the annotation script (and for anyone
# reading the job log directly).
run_logged "${BUILD_LOGS_DIR}/test.log" "Running unit tests" \
    xcodebuild test \
        -project "${PROJECT}" \
        -scheme "${SCHEME}" \
        -destination "platform=iOS Simulator,name=${SIMULATOR},OS=latest" \
        -derivedDataPath "${DERIVED_DATA}" \
        -resultBundlePath "${RESULT_BUNDLE}"

log "Build validation passed"
