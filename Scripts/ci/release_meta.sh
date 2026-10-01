#!/usr/bin/env bash
#
# ZynSign CI — release metadata: decide which version a release run is for,
# and refuse a run that cannot ship before anything expensive happens.
#
# Both release workflows need the same four facts — version, tag, channel,
# prerelease — and both used to derive them inline in YAML from a version a
# human typed into a dispatch form. A stale or mistyped version (a retired
# that is not a stop, a past stop, a typo) then travelled all the way to the quality
# gate while macOS runners were already building, and the error it produced
# did not say what to do instead.
#
# This script is the single place that decides:
#
#   * which version the run is for — the tag ref on a tag push, the dispatch
#     input, or, when neither is given, ReleaseTrain.current read through
#     `Scripts/release_train.py current`, so no version is hardcoded in YAML
#     and a bare "Run workflow" always means "release the current stop"
#   * whether that version may be released at all — it must be the release
#     train's current stop (docs/releases/release-train.md). This fails in
#     the first job, on ubuntu, before a macOS runner is allocated
#   * the channel (development / alpha / beta / rc / stable) and whether
#     GitHub marks the release as a pre-release
#
# Usage:
#   Scripts/ci/release_meta.sh [requested-version] [git-ref-name]
#   Scripts/ci/release_meta.sh --self-test
#
# `requested-version` is the dispatch input (with or without a leading v) and
# `git-ref-name` is the ref the run was triggered on; both fall back to the
# VERSION / GITHUB_REF_NAME environment variables. Outputs are appended to
# $GITHUB_OUTPUT when it is set and recorded in build/metrics/release_meta.txt.
#
# Workflows call this script; CI logic lives here, never in YAML.
#
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Crystal Flow — the shared log and summary language (Scripts/ci/crystal.sh).
CRYSTAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/ci/crystal.sh
source "${CRYSTAL_DIR}/crystal.sh"
crystal_phase "${CRYSTAL_RELEASE}" "Release" "Metadata"

TRAIN=(python3 Scripts/release_train.py)

# Crystal Flow: ✗ in the log plus the GitHub ::error annotation.
fail() { crystal_fail "$1"; }

# --- derivation -------------------------------------------------------------

# channel_for <version> — the release channel.
#
# The train answers this, not the version suffix. The suffix rule that used to
# stand in for it could not see `0.0.1`: the development stage's last stop is
# `horizon`, and it carries no pre-release suffix at all, so the first build
# read as `stable` and would have published as a full GitHub Release, taking the
# `latest` slot from a stable line it has not reached. `release_train.py channel`
# derives the channel from the ReleaseStage instead, where the stop's identity is
# not ambiguous.
#
# The suffix rule survives only as the fallback for a version the train does not
# know — which `validate_version` refuses separately, so a real release never
# reaches it.
channel_for() {
    local from_train
    if from_train="$("${TRAIN[@]}" channel "$1" 2>/dev/null)" && [[ -n "${from_train}" ]]; then
        printf '%s\n' "${from_train}"
        return 0
    fi
    case "$1" in
        *-dev*)   printf 'development\n' ;;
        *-alpha*) printf 'alpha\n' ;;
        *-beta*)  printf 'beta\n' ;;
        *-rc*)    printf 'rc\n' ;;
        *)        printf 'stable\n' ;;
    esac
}

# prerelease_for <channel> — every channel but stable is a GitHub pre-release,
# so `latest` always points at the newest stable release.
prerelease_for() {
    if [[ "$1" == "stable" ]]; then printf 'false\n'; else printf 'true\n'; fi
}

# resolve_version <requested> <ref> — the version this run releases:
#   1. an explicit request (dispatch input), a leading `v` tolerated
#   2. otherwise the tag ref, when the run was triggered by a tag push
#      (`github.ref_name` is a bare tag name then, and a branch name
#      otherwise — branch names here never start with `v<digit>`, and the
#      SemVer + train checks below catch any misreading)
#   3. otherwise the release train's current stop
resolve_version() {
    local requested ref
    requested="$(printf '%s' "${1:-}" | tr -d '[:space:]')"
    ref="${2:-}"
    requested="${requested#v}"
    if [[ -n "${requested}" ]]; then
        printf '%s\n' "${requested}"
        return 0
    fi
    if [[ "${ref}" == v[0-9]*.[0-9]* ]]; then
        printf '%s\n' "${ref#v}"
        return 0
    fi
    "${TRAIN[@]}" current
}

# --- validation -------------------------------------------------------------

# validate_version <version> — may this version be released right now?
validate_version() {
    local version="$1" tag="v$1"
    if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
        fail "'${version}' is not a SemVer version — expected X.Y.Z or X.Y.Z-suffix, without a leading v"
        return 1
    fi
    # release_train.py check --tag is the authority: it reports whether the
    # tag is a stop on the train, whether that stop is the current one, and
    # whether MARKETING_VERSION / the build number agree with it.
    if ! "${TRAIN[@]}" check --tag "${tag}"; then
        fail "${tag} cannot be released — it is not the release train's current stop"
        {
            echo "     Release the current stop instead: $("${TRAIN[@]}" current --tag)"
            echo "     Or promote to the stop you mean, commit, then release it:"
            echo "       python3 Scripts/release_train.py promote   # see docs/releases/release-train.md"
        } >&2
        return 1
    fi
    return 0
}

# --- output -----------------------------------------------------------------

# emit <key> <value> — publish a workflow output when running inside Actions.
emit() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"
    fi
}

# --- self-test --------------------------------------------------------------

# self_test — prove the derivation and the refusals on the real train, so
# 01-build.yml catches a broken release pipeline on an ordinary push instead of
# at the moment somebody tries to ship.
self_test() {
    local failures=0 current actual
    current="$("${TRAIN[@]}" current)"

    expect() { # expect <description> <actual> <expected>
        if [[ "$2" == "$3" ]]; then
            echo "ok: $1"
        else
            echo "FAIL: $1 — got '$2', expected '$3'" >&2
            failures=$((failures + 1))
        fi
    }
    expect_release() { # expect_release <version> <description>
        if validate_version "$1" >/dev/null 2>&1; then
            echo "ok: $2"
        else
            echo "FAIL: $2 — validate_version refused '$1'" >&2
            failures=$((failures + 1))
        fi
    }
    expect_refusal() { # expect_refusal <version> <description>
        if validate_version "$1" >/dev/null 2>&1; then
            echo "FAIL: $2 — validate_version accepted '$1'" >&2
            failures=$((failures + 1))
        else
            echo "ok: $2"
        fi
    }

    echo "=== release_meta.sh self-test (train stop: v${current}) ==="

    expect "no dispatch input on a branch releases the train's current stop" \
        "$(resolve_version "" "main")" "${current}"
    expect "a tag push releases the tag's version" \
        "$(resolve_version "" "v${current}")" "${current}"
    expect "an explicit input wins over the ref" \
        "$(resolve_version "${current}" "refs/heads/main")" "${current}"
    expect "a leading v in the input is tolerated" \
        "$(resolve_version "v${current}" "main")" "${current}"
    expect "a blank input falls back to the train" \
        "$(resolve_version "   " "main")" "${current}"
    expect "a release branch name is not read as a tag" \
        "$(resolve_version "" "release/v9.9.9-rc.9")" "${current}"
    expect "a feature branch name is not read as a tag" \
        "$(resolve_version "" "feature/engineering-excellence")" "${current}"

    expect "channel for 0.0.1-dev.1"  "$(channel_for "0.0.1-dev.1")"    "development"
    # The development stage's last stop carries no suffix, so the suffix rule
    # alone called it stable. It is a development stop and publishes as one.
    expect "channel for 0.0.1"        "$(channel_for "0.0.1")"          "development"
    expect "channel for 0.0.2-dev.1"  "$(channel_for "0.0.2-dev.1")"    "development"
    expect "channel for 0.1.0-alpha.1" "$(channel_for "0.1.0-alpha.1")"  "alpha"
    expect "channel for 0.9.0-beta.2"  "$(channel_for "0.9.0-beta.2")"   "beta"
    expect "channel for 1.0.0-rc.2"    "$(channel_for "1.0.0-rc.2")"     "rc"
    expect "channel for 1.0.0"         "$(channel_for "1.0.0")"          "stable"
    expect "the first build is a pre-release"      "$(prerelease_for "$(channel_for "0.0.1")")" "true"
    expect "stable is published as a full release"  "$(prerelease_for "stable")" "false"
    expect "every other channel is a pre-release"   "$(prerelease_for "rc")"     "true"

    expect_release "${current}" "the current stop is releasable"
    expect_refusal "9.9.9"        "a version that is not on the train is refused"
    expect_refusal "1.0.0-rc.3"   "a future stop is refused until it is promoted"
    expect_refusal "latest"       "a non-version is refused"
    expect_refusal "1.0"          "an incomplete version is refused"

    echo
    if [[ "${failures}" -gt 0 ]]; then
        echo "release_meta self-test FAILED — ${failures} failure(s)." >&2
        return 1
    fi
    echo "release_meta self-test passed."
    return 0
}

# --- main -------------------------------------------------------------------

if [[ "${1:-}" == "--self-test" ]]; then
    if self_test; then exit 0; else exit 1; fi
fi

REQUESTED="${1:-${VERSION:-}}"
REF="${2:-${GITHUB_REF_NAME:-}}"

VERSION="$(resolve_version "${REQUESTED}" "${REF}")"
TAG="v${VERSION}"

echo "=== Release metadata ==="
if [[ -n "$(printf '%s' "${REQUESTED}" | tr -d '[:space:]')" ]]; then
    echo "requested : ${REQUESTED} (explicit input)"
elif [[ "${REF}" == v[0-9]*.[0-9]* ]]; then
    echo "requested : ${REF} (tag push)"
else
    echo "requested : none — using the release train's current stop"
fi

if ! validate_version "${VERSION}"; then
    echo "Release metadata FAILED — the run stops here, before any build." >&2
    exit 1
fi

CHANNEL="$(channel_for "${VERSION}")"
PRERELEASE="$(prerelease_for "${CHANNEL}")"

emit "version" "${VERSION}"
emit "tag" "${TAG}"
emit "channel" "${CHANNEL}"
emit "prerelease" "${PRERELEASE}"

mkdir -p build/metrics
{
    echo "version=${VERSION}"
    echo "tag=${TAG}"
    echo "channel=${CHANNEL}"
    echo "prerelease=${PRERELEASE}"
} > build/metrics/release_meta.txt

echo "version   : ${VERSION}"
echo "tag       : ${TAG}"
echo "channel   : ${CHANNEL}"
echo "prerelease: ${PRERELEASE}"
