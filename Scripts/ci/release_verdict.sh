#!/usr/bin/env bash
#
# ZynSign CI — release verdict: the one card at the end of 🚀 Release that
# says what happened, which job decided it, and what to do next.
#
# The verdict used to live inline in 03-release.yml and only looked at the
# last three jobs (assets, publish, sync-changelog). That left it blind to
# the way a release really stops: when GitHub cannot acquire a hosted
# runner for one of the ubuntu gates ("The job was not acquired by Runner
# of type hosted even after multiple attempts"), that gate ends `cancelled`,
# everything downstream is `skipped`, and the old card then blamed
# "Stage: assets" for a job that never ran, wrote nothing to its own log,
# and gave no hint that a re-run of the failed jobs is the whole fix. It
# also declared a dry run a "Rehearsal Complete" success regardless of
# whether any gate had failed.
#
# This script is the single place that decides the verdict:
#
#   * which job broke the run — the first job in pipeline order
#     (meta → quality-gate → secret-history → build-and-test → assets →
#     publish → sync-changelog) that did not succeed, never one that was
#     merely skipped because an earlier one stopped
#   * why — `cancelled` is GitHub's word for a runner that was never
#     acquired or a run stopped by hand, and is reported as such, with the
#     re-run command; `failure` is a real gate failure and points at that
#     job's log and artifacts
#   * the three good endings — rehearsal complete, release published,
#     release published with the changelog staged — and the one partial
#     ending, release live but changelog sync broken
#
# The card goes to the step summary; the same verdict is also written to
# the job log and, on failure, as an ::error annotation, so the reason is
# visible in the run's annotations without opening the summary.
#
# Usage:
#   Scripts/ci/release_verdict.sh
#   Scripts/ci/release_verdict.sh --self-test
#
# Inputs are environment variables set by the workflow:
#   TAG VERSION CHANNEL DRY_RUN
#   META_RESULT QUALITY_GATE_RESULT SECRET_HISTORY_RESULT
#   BUILD_AND_TEST_RESULT ASSETS_RESULT PUBLISH_RESULT CHANGELOG_RESULT
#   CHANGELOG_URL CHANGELOG_OPERATION
# Each *_RESULT is a `needs.<job>.result` value: success, failure,
# cancelled or skipped. GITHUB_RUN_ID and GITHUB_SHA, when present, feed
# the re-run hint and the commit row.
#
# Workflows call this script; CI logic lives here, never in YAML.
#
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Crystal Flow — the shared log and summary language (Scripts/ci/crystal.sh).
CRYSTAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/ci/crystal.sh
source "${CRYSTAL_DIR}/crystal.sh"

# The jobs of 03-release.yml, in pipeline order. The first one that did not
# succeed is the one that decided the run.
GATES=(meta quality-gate secret-history build-and-test assets)
JOBS=("${GATES[@]}" publish sync-changelog)

# result_of <job> — the `needs.<job>.result` value for a job id.
result_of() {
    case "$1" in
        meta)           printf '%s' "${META_RESULT:-}" ;;
        quality-gate)   printf '%s' "${QUALITY_GATE_RESULT:-}" ;;
        secret-history) printf '%s' "${SECRET_HISTORY_RESULT:-}" ;;
        build-and-test) printf '%s' "${BUILD_AND_TEST_RESULT:-}" ;;
        assets)         printf '%s' "${ASSETS_RESULT:-}" ;;
        publish)        printf '%s' "${PUBLISH_RESULT:-}" ;;
        sync-changelog) printf '%s' "${CHANGELOG_RESULT:-}" ;;
        *)              printf '' ;;
    esac
}

# first_broken <job>... — the first job in the list whose result is not
# `success`, or nothing when they all succeeded.
first_broken() {
    local job
    for job in "$@"; do
        if [[ "$(result_of "${job}")" != "success" ]]; then
            printf '%s' "${job}"
            return 0
        fi
    done
    printf ''
}

# mark <result> — a glyph for the log and the card.
mark() {
    case "$1" in
        success)   printf '✓' ;;
        failure)   printf '✗' ;;
        cancelled) printf '⊘' ;;
        skipped)   printf '–' ;;
        *)         printf '?' ;;
    esac
}

# job_summary — every job and its result on one line, for the card's
# "Jobs" row and the log, so the whole picture is visible at a glance.
job_summary() {
    local job result out="" sep=""
    for job in "${JOBS[@]}"; do
        result="$(result_of "${job}")"
        out+="${sep}\`${job}\` $(mark "${result:-?}") ${result:-unknown}"
        sep=" · "
    done
    printf '%s' "${out}"
}

# rerun_hint — how to resume this run without repeating the gates that
# passed. GitHub keeps successful jobs on a "Re-run failed jobs".
rerun_hint() {
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
        printf 'Actions → this run → *Re-run failed jobs*, or `gh run rerun %s --failed`; the jobs that passed are kept' "${GITHUB_RUN_ID}"
    else
        printf 'Actions → this run → *Re-run failed jobs*; the jobs that passed are kept'
    fi
}

# log_results — the plain-text view of the run for the job log. The old
# verdict wrote only to the step summary, so its own log was empty.
log_results() {
    local job result
    crystal_phase "${CRYSTAL_RELEASE}" "Release" "Verdict • ${TAG:-unresolved}"
    for job in "${JOBS[@]}"; do
        result="$(result_of "${job}")"
        crystal_info "$(printf '%-15s %s %s' "${job}" "$(mark "${result:-?}")" "${result:-unknown}")"
    done
}

# --- the endings --------------------------------------------------------------

rehearsal_complete() {
    crystal_card_begin "${CRYSTAL_RELEASE}" "Rehearsal Complete" "Every gate ran; nothing was published" "Success"
    crystal_card_row "Candidate" "\`${TAG}\`"
    crystal_card_row "Channel" "${CHANNEL}"
    crystal_card_row "Assets" "${ASSETS_RESULT} — see the \`release-assets\` artifact"
    crystal_card_row "Published" "No — dry run"
    crystal_card_row "Next" "Tag when ready: \`git tag -a ${TAG} -m \"ZynSign ${VERSION}\" && git push origin ${TAG}\`"
    crystal_card_end
    crystal_ok "Rehearsal complete for ${TAG} — every gate passed, nothing was published."
}

published_changelog_staged() {
    crystal_card_begin "${CRYSTAL_RELEASE}" "Release Published · Changelog Staged" "Release is live; the changelog is staged but this repository does not let GitHub Actions open PRs" "Success"
    crystal_card_row "Release" "\`${TAG}\`"
    crystal_card_row "Channel" "${CHANNEL}"
    crystal_card_row "Assets" "${ASSETS_RESULT}"
    crystal_card_row "Changelog" "staged on \`automation/release-changelog-${VERSION}\`"
    crystal_card_row "Next" "Allow Actions to create pull requests (or add \`RELEASE_CHANGELOG_TOKEN\`), then re-run the sync job — or open the PR from the staged branch"
    crystal_card_end
    crystal_ok "Release ${TAG} published; changelog staged on automation/release-changelog-${VERSION}."
}

published() {
    crystal_card_begin "${CRYSTAL_RELEASE}" "Release Published" "Release assets and changelog sync completed" "Success"
    crystal_card_row "Release" "\`${TAG}\`"
    crystal_card_row "Channel" "${CHANNEL}"
    crystal_card_row "Assets" "${ASSETS_RESULT}"
    if [[ -n "${CHANGELOG_URL:-}" ]]; then
        crystal_card_row "Changelog PR" "${CHANGELOG_OPERATION} — ${CHANGELOG_URL}"
    else
        crystal_card_row "Changelog" "No documentation changes were needed"
    fi
    crystal_card_end
    crystal_ok "Release ${TAG} published."
}

published_changelog_broken() {
    crystal_card_begin "${CRYSTAL_RELEASE}" "Release Published · Changelog Sync Needs Attention" "Release is live; its changelog PR was not created successfully" "Failure"
    crystal_card_row "Release" "\`${TAG}\` — published"
    crystal_card_row "Changelog PR" "${CHANGELOG_RESULT} — inspect the sync-changelog job"
    crystal_card_row "Next" "Repair or re-run the \`sync-changelog\` job; a re-run keeps curated notes and newer \`[Unreleased]\` entries"
    crystal_card_end
    crystal_fail "Release ${TAG} is published, but the changelog sync ended '${CHANGELOG_RESULT}' — re-run or repair the sync-changelog job." "Release verdict"
}

# stopped <job> — the run did not reach a release; <job> is the first job in
# pipeline order that did not succeed. Its result decides the diagnosis.
stopped() {
    local job="$1" result title cause next evidence
    result="$(result_of "${job}")"
    case "${result}" in
        cancelled)
            # GitHub's wording for a job that never got a runner is
            # "The job was not acquired by Runner of type hosted even after
            # multiple attempts"; the job's conclusion is `cancelled`, exactly
            # as if someone had pressed Cancel. Either way the commit was not
            # tested and is not at fault.
            title="Release Stopped · Job Cancelled Before It Ran"
            cause="GitHub cancelled \`${job}\` — usually a hosted runner could not be acquired (\"The job was not acquired by Runner of type hosted even after multiple attempts\"), or the run was cancelled by hand. Nothing in this commit was found at fault; nothing was published"
            next="$(rerun_hint)"
            evidence="the \`${job}\` job's annotations and the GitHub Actions status page"
            ;;
        failure)
            title="Release Stopped"
            cause="the \`${job}\` gate failed — nothing was published"
            next="Fix what the \`${job}\` log reports, then tag or dispatch again"
            evidence="the \`${job}\` job's log and the \`release-assets\` / \`release-build-logs\` artifacts"
            ;;
        *)
            # A job that was skipped although everything before it succeeded:
            # an `if:` condition in the workflow, not a gate, stopped the run.
            title="Release Stopped"
            cause="\`${job}\` ended '${result:-unknown}' although every job before it succeeded — check its \`if:\` condition in 03-release.yml"
            next="Inspect the \`${job}\` job on this run"
            evidence="the run's job graph"
            ;;
    esac
    crystal_card_begin "${CRYSTAL_RELEASE}" "${title}" "Automatic diagnostics" "Failed"
    crystal_card_row "Stage" "\`${job}\` — ${result:-unknown}"
    crystal_card_row "Likely cause" "${cause}"
    crystal_card_row "Commit" "\`${GITHUB_SHA:0:7}\`"
    crystal_card_row "Candidate" "\`${TAG:-unresolved}\`"
    crystal_card_row "Jobs" "$(job_summary)"
    crystal_card_row "Evidence" "${evidence}"
    crystal_card_row "Next" "${next}"
    crystal_card_end
    crystal_fail "Release stopped at ${job} (${result:-unknown}): ${cause}." "Release verdict"
}

# --- the verdict --------------------------------------------------------------

# verdict — decide and report; the exit code is the job's.
verdict() {
    local broken
    log_results

    broken="$(first_broken "${GATES[@]}")"

    if [[ "${DRY_RUN:-}" == "true" ]]; then
        if [[ -z "${broken}" ]]; then
            rehearsal_complete
            return 0
        fi
        stopped "${broken}"
        return 1
    fi

    if [[ "${PUBLISH_RESULT:-}" == "success" && "${CHANGELOG_RESULT:-}" == "success" ]]; then
        if [[ "${CHANGELOG_OPERATION:-}" == "branch-staged" ]]; then
            published_changelog_staged
        else
            published
        fi
        return 0
    fi

    if [[ "${PUBLISH_RESULT:-}" == "success" ]]; then
        published_changelog_broken
        return 1
    fi

    # publish did not succeed: name the gate that stopped it, or publish
    # itself when every gate passed.
    stopped "${broken:-publish}"
    return 1
}

# --- self-test ----------------------------------------------------------------

# self_test — replay the endings against recorded job results, including the
# run that motivated this script (two ubuntu gates cancelled for want of a
# runner), so 01-build.yml catches a verdict that lies on an ordinary push.
self_test() {
    local failures=0

    # case <description> <expected-exit> <expected-text-in-summary> <VAR=value>...
    # Runs the verdict in a subshell with the given environment, the summary
    # redirected to a scratch file and annotations switched off, so a
    # self-test never leaves ::error marks on the build.
    case_() {
        local description="$1" expected_exit="$2" expected_text="$3"
        shift 3
        local summary rc=0
        summary="$(mktemp)"
        (
            unset GITHUB_ACTIONS GITHUB_RUN_ID
            export GITHUB_STEP_SUMMARY="${summary}" GITHUB_SHA="0123456789abcdef"
            export TAG="" VERSION="" CHANNEL="" DRY_RUN=""
            export META_RESULT="" QUALITY_GATE_RESULT="" SECRET_HISTORY_RESULT=""
            export BUILD_AND_TEST_RESULT="" ASSETS_RESULT="" PUBLISH_RESULT=""
            export CHANGELOG_RESULT="" CHANGELOG_URL="" CHANGELOG_OPERATION=""
            local assignment
            for assignment in "$@"; do export "${assignment?}"; done
            verdict >/dev/null 2>&1
        ) || rc=$?
        if [[ "${rc}" -ne "${expected_exit}" ]]; then
            echo "FAIL: ${description} — exit ${rc}, expected ${expected_exit}" >&2
            failures=$((failures + 1))
        elif ! grep -qF -- "${expected_text}" "${summary}"; then
            echo "FAIL: ${description} — summary lacks '${expected_text}':" >&2
            sed 's/^/     /' "${summary}" >&2
            failures=$((failures + 1))
        else
            echo "ok: ${description}"
        fi
        rm -f "${summary}"
    }

    local all_gates=(META_RESULT=success QUALITY_GATE_RESULT=success SECRET_HISTORY_RESULT=success BUILD_AND_TEST_RESULT=success ASSETS_RESULT=success)
    local ids=(TAG=v0.1.0-alpha.2 VERSION=0.1.0-alpha.2 CHANNEL=alpha)

    echo "=== release_verdict.sh self-test ==="

    case_ "a clean dry run is a complete rehearsal" 0 "Rehearsal Complete" \
        "${ids[@]}" DRY_RUN=true "${all_gates[@]}" PUBLISH_RESULT=skipped CHANGELOG_RESULT=skipped
    case_ "a dry run with a failed build is not a rehearsal" 1 '| Stage | `build-and-test` — failure |' \
        "${ids[@]}" DRY_RUN=true META_RESULT=success QUALITY_GATE_RESULT=success SECRET_HISTORY_RESULT=success \
        BUILD_AND_TEST_RESULT=failure ASSETS_RESULT=skipped PUBLISH_RESULT=skipped CHANGELOG_RESULT=skipped

    case_ "published with a changelog PR" 0 "created — https://example.invalid/pull/1" \
        "${ids[@]}" DRY_RUN=false "${all_gates[@]}" PUBLISH_RESULT=success CHANGELOG_RESULT=success \
        CHANGELOG_OPERATION=created CHANGELOG_URL=https://example.invalid/pull/1
    case_ "published with nothing to sync" 0 "No documentation changes were needed" \
        "${ids[@]}" DRY_RUN=false "${all_gates[@]}" PUBLISH_RESULT=success CHANGELOG_RESULT=success CHANGELOG_OPERATION=none
    case_ "published with the changelog staged on a branch" 0 "Release Published · Changelog Staged" \
        "${ids[@]}" DRY_RUN=false "${all_gates[@]}" PUBLISH_RESULT=success CHANGELOG_RESULT=success CHANGELOG_OPERATION=branch-staged
    case_ "published but the changelog sync failed" 1 "Changelog Sync Needs Attention" \
        "${ids[@]}" DRY_RUN=false "${all_gates[@]}" PUBLISH_RESULT=success CHANGELOG_RESULT=failure

    # Run 37373668043: both ubuntu gates were never acquired by a runner.
    case_ "a gate cancelled for want of a runner is named, not blamed on assets" 1 '| Stage | `quality-gate` — cancelled |' \
        "${ids[@]}" DRY_RUN=false META_RESULT=success QUALITY_GATE_RESULT=cancelled SECRET_HISTORY_RESULT=cancelled \
        BUILD_AND_TEST_RESULT=success ASSETS_RESULT=skipped PUBLISH_RESULT=skipped CHANGELOG_RESULT=skipped
    case_ "a cancelled gate points at a re-run, not at the commit" 1 "Re-run failed jobs" \
        "${ids[@]}" DRY_RUN=false META_RESULT=success QUALITY_GATE_RESULT=cancelled SECRET_HISTORY_RESULT=cancelled \
        BUILD_AND_TEST_RESULT=success ASSETS_RESULT=skipped PUBLISH_RESULT=skipped CHANGELOG_RESULT=skipped

    case_ "a failed gate is a real stop" 1 '| Stage | `secret-history` — failure |' \
        "${ids[@]}" DRY_RUN=false META_RESULT=success QUALITY_GATE_RESULT=success SECRET_HISTORY_RESULT=failure \
        BUILD_AND_TEST_RESULT=success ASSETS_RESULT=skipped PUBLISH_RESULT=skipped CHANGELOG_RESULT=skipped
    case_ "a refused version stops at meta with no tag" 1 '| Stage | `meta` — failure |' \
        DRY_RUN=false META_RESULT=failure QUALITY_GATE_RESULT=skipped SECRET_HISTORY_RESULT=skipped \
        BUILD_AND_TEST_RESULT=skipped ASSETS_RESULT=skipped PUBLISH_RESULT=skipped CHANGELOG_RESULT=skipped
    case_ "a failed publish after green gates is the publish stage" 1 '| Stage | `publish` — failure |' \
        "${ids[@]}" DRY_RUN=false "${all_gates[@]}" PUBLISH_RESULT=failure CHANGELOG_RESULT=skipped
    case_ "a failed assets job is the assets stage" 1 '| Stage | `assets` — failure |' \
        "${ids[@]}" DRY_RUN=false META_RESULT=success QUALITY_GATE_RESULT=success SECRET_HISTORY_RESULT=success \
        BUILD_AND_TEST_RESULT=success ASSETS_RESULT=failure PUBLISH_RESULT=skipped CHANGELOG_RESULT=skipped

    echo
    if [[ "${failures}" -gt 0 ]]; then
        echo "release_verdict self-test FAILED — ${failures} failure(s)." >&2
        return 1
    fi
    echo "release_verdict self-test passed."
    return 0
}

# --- main ---------------------------------------------------------------------

if [[ "${1:-}" == "--self-test" ]]; then
    if self_test; then exit 0; else exit 1; fi
fi

if verdict; then exit 0; else exit 1; fi
