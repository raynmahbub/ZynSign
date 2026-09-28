#!/usr/bin/env bash
#
# ZynSign CI — test-failure annotations.
#
# Usage: annotate_test_failures.sh [xcresult-path] [log-file]
#
# `xcodebuild test` runs print very little failure detail on their own,
# so a red unit-test step would otherwise surface as nothing more than
# "Process completed with exit code 65". The result bundle, however,
# records every test case and its failure text. This script reads the
# bundle with xcresulttool and emits GitHub Actions `::error`
# annotations for every failed test, so the failing suites are readable
# straight from the checks page without opening raw logs.
#
# Fallbacks, in order, when the bundle or xcresulttool is unavailable:
#   1. `Test Case ... failed` / assertion `: error:` lines from the log
#   2. the last meaningful lines of the log
#
# The script always exits 0 — callers own the real step status.
# Workflows and Scripts/ci/build.sh call it; CI logic lives here, never
# inline in YAML.
#
set -uo pipefail

RB="${1:-}"
LOG="${2:-}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
ANN_FILE="${WORKDIR}/annotations.txt"
: >"${ANN_FILE}"

# --- bundle path -----------------------------------------------------------
if [[ -n "${RB}" && -d "${RB}" ]]; then
    TESTS_JSON="${WORKDIR}/tests.json"
    SUMMARY_JSON="${WORKDIR}/summary.json"
    if xcrun xcresulttool get test-results tests \
            --path "${RB}" --format json >"${TESTS_JSON}" 2>/dev/null; then
        xcrun xcresulttool get test-results summary \
            --path "${RB}" --format json >"${SUMMARY_JSON}" 2>/dev/null \
            || : >"${SUMMARY_JSON}"
        python3 - "${SUMMARY_JSON}" "${TESTS_JSON}" \
            "${GITHUB_STEP_SUMMARY:-}" >>"${ANN_FILE}" <<'PYEOF'
import json
import sys

summary_path, tests_path, step_summary = sys.argv[1:4]


def esc(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def eprop(text: str) -> str:
    return esc(text).replace(":", "%3A").replace(",", "%2C")


failed = []
seen_names = set()


def walk(node):
    """Collect nodes whose result marks them failed (schema drift-safe)."""
    if isinstance(node, dict):
        result = node.get("result") or node.get("status") or node.get("outcome")
        name = node.get("name")
        children = node.get("children")
        if (
            name
            and isinstance(result, str)
            and result.lower() in {"failed", "failure", "errored"}
            and not (isinstance(children, list) and children)
        ):
            key = str(name)
            if key not in seen_names:
                seen_names.add(key)
                text = ""
                for field in (
                    "failureText",
                    "failure",
                    "message",
                    "issueDescription",
                ):
                    value = node.get(field)
                    if isinstance(value, str) and value.strip():
                        text = value.strip()
                        break
                failed.append((key, text))
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)


try:
    with open(tests_path) as handle:
        walk(json.load(handle))
except Exception:
    pass

# Counts for the summary annotation; key names drift across Xcode
# versions, so look for any known spelling anywhere in the summary.
counts = {}


def collect_counts(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if isinstance(value, int) and key in {
                "totalTestCount",
                "total",
                "passedTests",
                "failedTests",
                "skippedTests",
                "testCount",
            }:
                counts[key] = value
            collect_counts(value)
    elif isinstance(node, list):
        for value in node:
            collect_counts(value)


try:
    with open(summary_path) as handle:
        collect_counts(json.load(handle))
except Exception:
    pass

if failed:
    parts = []
    if "failedTests" in counts:
        parts.append(f"{counts['failedTests']} failed")
    if "totalTestCount" in counts:
        parts.append(f"of {counts['totalTestCount']} total")
    elif "total" in counts:
        parts.append(f"of {counts['total']} total")
    head = ", ".join(name for name, _ in failed[:60])
    detail = f" ({'; '.join(parts)})" if parts else ""
    listing = head + (" …" if len(failed) > 60 else "")
    # GitHub keeps ten error annotations per step: one summary plus the
    # first few details fit; the step summary below carries the rest.
    message = f"{len(failed)} test(s) failed{detail}: {listing}"[:3_400]
    print(f"::error title=Unit tests failed::{esc(message)}")
    for name, text in failed[:8]:
        message = name + (f" — {text[:300]}" if text else "")
        print(f"::error title=Failing test::{esc(message)}")

    if step_summary:
        try:
            with open(step_summary, "a") as handle:
                handle.write("### Failing unit tests\n\n")
                if counts:
                    handle.write(
                        "Counts: "
                        + ", ".join(f"{k}={v}" for k, v in sorted(counts.items()))
                        + "\n\n"
                    )
                handle.write("| Test | Failure |\n| --- | --- |\n")
                for name, text in failed[:80]:
                    clean = (text or "").replace("\n", " ")[:300].replace("|", "\\|")
                    handle.write(f"| `{name}` | {clean} |\n")
                handle.write("\n")
        except Exception:
            pass
PYEOF
    fi
fi

# --- log fallback ----------------------------------------------------------
# Used when the bundle is missing or the tool schema yielded nothing.
# GitHub allows ten error annotations per step, so the fallback packs
# every assertion line into chunks of at most ~3.4 KB instead of
# emitting one annotation per failure and losing the rest to the cap.
if [[ ! -s "${ANN_FILE}" && -n "${LOG}" && -f "${LOG}" ]]; then
    DIAG_DIR=""
    if [[ -n "${RB}" && -d "${RB}" ]] && command -v xcrun >/dev/null 2>&1; then
        # Xcode 16+ JSON summaries.
        SUMMARY_JSON="$RUNNER_TEMP/xc-summary.json"
        TESTS_JSON="$RUNNER_TEMP/xc-tests.json"
        xcrun xcresulttool get test-results summary --path "$RB" > "$SUMMARY_JSON" 2>/dev/null || true
        xcrun xcresulttool get test-results tests --path "$RB" > "$TESTS_JSON" 2>/dev/null || true
        # Crash reports and per-bundle stdout/stderr live ONLY here, never
        # in the job log — a bare "Test crashed with signal abrt." means
        # the answer is inside this directory.
        DIAG_DIR="$RUNNER_TEMP/xc-diag"
        rm -rf "$DIAG_DIR"
        mkdir -p "$DIAG_DIR"
        xcrun xcresulttool export diagnostics --path "$RB" --output-path "$DIAG_DIR" >/dev/null 2>&1 || true
    else
        SUMMARY_JSON=""
        TESTS_JSON=""
    fi
    python3 - "${SUMMARY_JSON}" "${TESTS_JSON}" "${DIAG_DIR}" "${LOG}" <<'PYEOF'
import json
import os
import re
import sys

summary_path, tests_path, diag_path, log_path = sys.argv[1:5]

budget = [9]  # GitHub caps error annotations per step


def esc(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def emit(title: str, text: str) -> None:
    if budget[0] <= 0:
        return
    budget[0] -= 1
    print(f"::error title={title}::{esc(text)[:4090]}")


def load(path):
    if not path:
        return None
    try:
        with open(path) as handle:
            return json.load(handle)
    except Exception:
        return None


# --- 1. exported crash diagnostics -----------------------------------------
if diag_path and os.path.isdir(diag_path):
    files = []
    for root, _dirs, names in os.walk(diag_path):
        for name in names:
            files.append(os.path.join(root, name))

    reports = [f for f in files if f.endswith((".ips", ".crash", ".panic"))]
    logs = [f for f in files if f.endswith((".log", ".txt", ".out", ".stderr", ".stdout"))
            or "stdout" in os.path.basename(f).lower()
            or "stderr" in os.path.basename(f).lower()]

    for report in reports[:2]:
        try:
            blob = open(report, errors="replace").read()
        except Exception:
            continue
        # Header line (JSON for .ips) plus the crashing thread context.
        header = blob[:1800]
        emit(f"Crash report ({os.path.basename(report)})", header)

    for log in logs[:3]:
        try:
            blob = open(log, errors="replace").read()
        except Exception:
            continue
        if not blob.strip():
            continue
        tail = blob.splitlines()[-45:]
        emit(f"Bundle output ({os.path.basename(log)})", "\n".join(tail))

    if not reports and not logs and files:
        emit("Diagnostics exported",
             "files: " + ", ".join(os.path.relpath(f, diag_path) for f in files[:20]))

# --- 2. session totals and raw failures ------------------------------------
summary = load(summary_path)
if summary:
    failures = summary.get("testFailures") or []
    keys = ("result", "status", "totalTestCount", "passedTests", "failedTests",
            "skippedTests", "expectedFailures", "totalFailures", "errorCount")
    line = "session: " + ", ".join(f"{k}={summary.get(k)}" for k in keys if k in summary)
    emit("Test session summary", line)
    for failure in failures[:2]:
        try:
            blob = json.dumps(failure, indent=1)
        except Exception:
            blob = str(failure)
        emit("XCTest failure (raw)", blob[:4080])

# --- 3. tests tree: non-passing node excerpt (schema-free) -----------------
try:
    raw_tests = open(tests_path, errors="replace").read() if tests_path else ""
except Exception:
    raw_tests = ""
if raw_tests:
    hits = []
    for m in re.finditer(r'"(?:result|status)"\s*:\s*"([^"]+)"', raw_tests):
        value = m.group(1)
        if value.lower() not in ("passed", "skipped", "success", "started"):
            excerpt = raw_tests[max(0, m.start() - 400):m.end() + 400]
            if excerpt not in hits:
                hits.append(excerpt)
        if len(hits) >= 2:
            break
    for excerpt in hits:
        emit("Tests tree (non-passing)", excerpt)

# --- 4. log stats, suite order ---------------------------------------------
try:
    lines = open(log_path, errors="replace").read().splitlines()
except Exception:
    lines = []

started = []
for line in lines:
    m = re.search(r"Test Suite '([^']+)' started", line)
    if m and m.group(1) not in started:
        started.append(m.group(1))
case_started = sum(1 for l in lines if re.match(r"\s*Test Case '.*' started", l))
case_done = sum(1 for l in lines if re.match(r"\s*Test Case '.*' (passed|failed|skipped)", l))
emit("Log stats",
     f"log_lines={len(lines)} case_started={case_started} case_finished={case_done} "
     f"suites_started={len(started)}")
if started:
    joined = " | ".join(started)
    emit("Suites started", joined[:4080])

crash_re = re.compile(r"crashed with signal|\babrt\b|fatalError|Fatal error|"
                      r"Terminating app due to uncaught exception|Assertion failure|"
                      r"execution was interrupted|lost connection|watchdog", re.I)
crash_idx = [i for i, l in enumerate(lines) if crash_re.search(l)]
if crash_idx and budget[0] > 0:
    i = crash_idx[0]
    emit("Crash context", "\n".join(lines[max(0, i - 6):i + 7])[:4080])
PYEOF
fi

cat "${ANN_FILE}"
exit 0
