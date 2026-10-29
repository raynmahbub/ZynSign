#!/usr/bin/env bash
#
# ZynSign CI — build validation entry point.
#
# Resolves packages, cleans DerivedData, builds every target, builds the
# test targets, and runs the unit tests. Every xcodebuild invocation is
# logged under build/logs/ so the workflow can upload the result bundle
# and the logs after a pass and after a failure.
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

# Record the toolchain and the destination the test invocation will use.
# The workflow uploads this file; it is not a second test run.
write_xctest_context() {
    local destination="$1"
    local xcode_version="unavailable"
    if command -v xcodebuild >/dev/null 2>&1; then
        xcode_version="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
        if [[ -z "${xcode_version}" ]]; then
            xcode_version="unavailable"
        fi
    fi
    {
        printf 'xcode_version=%s\n' "${xcode_version}"
        printf 'simulator_destination=%s\n' "${destination}"
        printf 'scheme=%s\n' "${SCHEME}"
        printf 'project=%s\n' "${PROJECT}"
        printf 'run_tests=%s\n' "${RUN_TESTS}"
        printf 'result_bundle=%s\n' "${BUILD_LOGS_DIR}/ZynSignTests.xcresult"
    } > "${BUILD_LOGS_DIR}/xctest-context.txt"
    crystal_info "Xcode: ${xcode_version}"
    crystal_info "Simulator destination: ${destination}"
}

# Concise counts for the job log and the step summary. Must not change the
# script's exit status — finish() saves that before calling this.
publish_xctest_summary() {
    local bundle="${1:-}"
    local summary_json="${BUILD_LOGS_DIR}/xctest-summary.json"
    local summary_txt="${BUILD_LOGS_DIR}/xctest-summary.txt"
    local summary_md="${BUILD_LOGS_DIR}/xctest-summary.md"
    local artifact_name="xctest-results-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}"
    local run_url=""

    if [[ ! -d "${BUILD_LOGS_DIR}" ]]; then
        return 0
    fi
    if [[ -n "${bundle}" && -d "${bundle}" ]] && command -v xcrun >/dev/null 2>&1; then
        if ! xcrun xcresulttool get test-results summary \
                --path "${bundle}" --format json >"${summary_json}" 2>/dev/null; then
            rm -f "${summary_json}"
        fi
    fi
    if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
        run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    fi
    python3 "${CRYSTAL_DIR}/xctest_evidence.py" summarize \
        --json "${summary_json}" \
        --log "${BUILD_LOGS_DIR}/test.log" \
        --context "${BUILD_LOGS_DIR}/xctest-context.txt" \
        --bundle "${bundle}" \
        --artifact "${artifact_name}" \
        --retention-days 14 \
        --run-url "${run_url}" \
        --output "${summary_txt}" \
        --markdown "${summary_md}" || true
    if [[ -s "${summary_txt}" ]]; then
        printf '\n=== XCTest summary ===\n'
        cat "${summary_txt}"
        if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
            local one_line
            one_line="$(head -n 1 "${summary_txt}" | cut -c 1-500 || true)"
            printf '::notice title=XCTest summary::%s\n' "$(crystal_escape "${one_line}")"
        fi
    fi
    if [[ -s "${summary_md}" && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        cat "${summary_md}" >> "${GITHUB_STEP_SUMMARY}"
    fi
}

# Runs on every exit, including a failing xcodebuild, so a red run still
# leaves the summary next to the logs the workflow uploads.
finish() {
    status=$?
    trap - EXIT
    publish_xctest_summary "${RESULT_BUNDLE:-}" || true
    # Only sanitized, source-allowlisted identifiers and validated counts are
    # published; raw xcresulttool data remains in the helper's memory.
    python3 "${CRYSTAL_DIR}/xctest_results.py" \
        --bundle "${RESULT_BUNDLE:-}" --output-dir "${BUILD_LOGS_DIR}" || true
    exit "${status}"
}
trap finish EXIT
write_xctest_context "not selected"

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
    write_xctest_context "skipped (RUN_TESTS=0)"
    log "RUN_TESTS=0 — skipping the test run"
    exit 0
fi

# Resolve the simulator dynamically unless the caller pinned one; the
# selector installs the runtime when the runner image has none.
if [[ -z "${SIMULATOR}" ]]; then
    log "Selecting an available iPhone simulator"
    SIMULATOR="$("$(dirname "$0")/select_simulator.sh")"
fi
write_xctest_context "platform=iOS Simulator,name=${SIMULATOR},OS=latest"

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
