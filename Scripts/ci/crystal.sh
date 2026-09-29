#!/usr/bin/env bash
#
# ZynSign CI — Crystal Flow: one visual language for every log and summary.
#
# Every workflow, every script, every job speaks the same way, so a log is
# readable at a glance and a GitHub step summary reads like a product
# surface rather than a terminal dump:
#
#   ━━━━━━━━━━━━━━━━━━━━━━━━━━
#   🔨 Build • Setup
#   ━━━━━━━━━━━━━━━━━━━━━━━━━━
#   ✓ Repository checked out
#   ✓ Xcode 16.2 selected
#
# This file is *sourced* by the other Scripts/ci scripts; it is never
# executed directly. It is safe under `set -euo pipefail`, it degrades to
# plain stdout outside GitHub Actions (so local runs look the same), and it
# never writes machine-readable metrics — build/metrics/*.txt stay plain
# key=value because metrics_report.sh parses them.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/crystal.sh"
#   crystal_phase "${CRYSTAL_BUILD}" "Build" "Setup"
#   crystal_ok "Repository checked out"
#   crystal_card_begin "${CRYSTAL_BUILD}" "Build Summary" "Automatic artifact naming" "Success"
#   crystal_card_row "Version" "1.0.0-rc.2"
#   crystal_card_end
#
# CI logic lives in scripts, never in YAML — including the presentation.
#

# The four workflow identities. Numbers keep the Actions page ordered;
# these icons keep the logs and summaries recognisable.
CRYSTAL_BUILD="🔨"
CRYSTAL_QUALITY="🛡"
CRYSTAL_RELEASE="🚀"
CRYSTAL_COMMAND="⚙"

# --- log lines --------------------------------------------------------------

# crystal_phase <icon> <workflow> <phase> — open a section of the log.
crystal_phase() {
    local bar="━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf '\n%s\n%s %s • %s\n%s\n' "${bar}" "${1}" "${2}" "${3}" "${bar}"
}

# crystal_ok <message> — something succeeded.
crystal_ok() { printf '✓ %s\n' "$1"; }

# crystal_info <message> — a fact worth recording, neither pass nor fail.
crystal_info() { printf '• %s\n' "$1"; }

# crystal_warn <message> — a warning, annotated when running in Actions.
crystal_warn() {
    printf '⚠ %s\n' "$1"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf '::warning title=crystal::%s\n' "$1"
    fi
}

# crystal_fail <message> — a failure, annotated when running in Actions.
# Does not exit; the caller decides whether the run stops.
crystal_fail() {
    printf '✗ %s\n' "$1" >&2
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf '::error title=crystal::%s\n' "$1" >&2
    fi
}

# --- summary cards ----------------------------------------------------------

# _crystal_out <text> — the step summary in Actions, stdout locally.
_crystal_out() {
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf '%s\n' "$1" >> "${GITHUB_STEP_SUMMARY}"
    else
        printf '%s\n' "$1"
    fi
}

# crystal_card_begin <icon> <title> <subtitle> <status>
#   status is one of: Success · Failed · Passed · Warning · Skipped —
#   it decides the icon shown next to the verdict.
crystal_card_begin() {
    local icon="$1" title="$2" subtitle="$3" status="$4" verdict="✅"
    case "${status}" in
        Fail*|fail*|Error*|error*) verdict="❌" ;;
        Warn*|warn*)                 verdict="⚠️" ;;
        Skip*|skip*)                 verdict="⏭️" ;;
    esac
    _crystal_out "## ${icon} ${title}"
    _crystal_out "_${subtitle}_"
    _crystal_out ""
    _crystal_out "**${verdict} ${status}**"
    _crystal_out ""
    _crystal_out "| | |"
    _crystal_out "| --- | --- |"
}

# crystal_card_row <label> <value> — one line of the card's table.
crystal_card_row() {
    _crystal_out "| ${1} | ${2} |"
}

# crystal_card_end — close the card.
crystal_card_end() {
    _crystal_out ""
}

# crystal_failure_card <icon> <title> <stage> <likely-cause> <commit> <log-hint>
#   The diagnostics card: when a job fails, the summary says which stage
#   broke and where the evidence is, instead of leaving a reader to scroll
#   through a raw log.
crystal_failure_card() {
    crystal_card_begin "$1" "$2" "Automatic diagnostics" "Failed"
    crystal_card_row "Stage" "\`${3}\`"
    crystal_card_row "Likely cause" "${4}"
    crystal_card_row "Commit" "\`${5}\`"
    crystal_card_row "Evidence" "${6}"
    crystal_card_end
}
