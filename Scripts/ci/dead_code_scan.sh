#!/usr/bin/env bash
#
# ZynSign CI — dead code report.
#
# Generates Reports/DeadCodeReport.md. It never deletes anything — the
# report exists for a developer to review before any removal happens.
#
# Two engines:
#   periphery   — precise, index-build based (used by the dead-code
#                 workflow on macOS, or locally when installed)
#   heuristic   — reference-counting fallback so the report exists on any
#                 platform; clearly labelled as approximate
#
# Workflows call this script; CI logic lives here, never in YAML.
#
set -Eeuo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Crystal Flow — the shared log and summary language (Scripts/ci/crystal.sh).
CRYSTAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/ci/crystal.sh
source "${CRYSTAL_DIR}/crystal.sh"
crystal_phase "${CRYSTAL_COMMAND}" "Command Center" "Dead code"

PROJECT="${PROJECT:-ZynSign.xcodeproj}"
SCHEME="${SCHEME:-ZynSign}"
REPORT="Reports/DeadCodeReport.md"
METRICS_DIR="build/metrics"
SCAN_JSON="build/periphery-scan.json"
SCAN_ERR="build/periphery-stderr.log"
mkdir -p Reports "${METRICS_DIR}"

# Any unexpected failure must still be readable from the checks page:
# job logs are not retrievable from every environment, annotations are.
ERR_ANNOTATED=0
on_error() {
    local rc=$?
    set +e
    if [[ "${ERR_ANNOTATED}" == "1" ]]; then
        return 0
    fi
    ERR_ANNOTATED=1
    if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
        return 0
    fi
    local cmd
    cmd="$(printf '%s' "${BASH_COMMAND}" | tr '\n' ' ' | cut -c1-300)"
    printf '::error title=Dead code scan failed::exit %s while running: %s\n' \
        "${rc}" "${cmd//%/%25}"
    if [[ -s "${SCAN_ERR}" ]]; then
        while IFS= read -r line; do
            printf '::error title=Periphery stderr::%s\n' "${line//%/%25}"
        done < <(tail -12 "${SCAN_ERR}")
    fi
    if [[ -s "${SCAN_JSON}" ]]; then
        printf '::error title=Periphery stdout (head)::%s\n' \
            "$(head -c 500 "${SCAN_JSON}" | tr '\n' ' ' | sed 's/%/%25/g')"
    fi
}
trap on_error ERR

ENGINE="heuristic"
if [[ "${USE_PERIPHERY:-auto}" != "0" ]] && command -v periphery >/dev/null 2>&1; then
    ENGINE="periphery"
fi

if [[ "${ENGINE}" == "periphery" ]]; then
    echo "Scanning with Periphery (index build may take a few minutes)…"
    mkdir -p build
    scan_status=0
    # Periphery 3.x selects targets via --schemes; --targets no longer
    # exists ("Unknown option '--targets'" exits EX_USAGE 64).
    periphery scan \
        --project "${PROJECT}" \
        --schemes "${SCHEME}" \
        --format json > "${SCAN_JSON}" 2> "${SCAN_ERR}" || scan_status=$?
    # Progress and diagnostics are on stderr; keep them out of the JSON.
    tail -50 "${SCAN_ERR}" >&2 || true
    if [[ "${scan_status}" -ne 0 ]]; then
        if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
            printf '::error title=Periphery scan failed::exit %s (nothing was deleted)\n' \
                "${scan_status}"
            # Prefer lines that name the problem; fall back to the raw
            # stderr tail, then to whatever reached stdout — one of the
            # three always carries the actual cause.
            hits="$(grep -Ei 'error|fatal|unknown|invalid|failed' "${SCAN_ERR}" 2>/dev/null | tail -8 || true)"
            if [[ -z "${hits}" ]]; then
                hits="$(tail -20 "${SCAN_ERR}" 2>/dev/null || true)"
            fi
            if [[ -z "${hits}" && -s "${SCAN_JSON}" ]]; then
                hits="$(head -c 500 "${SCAN_JSON}" | tr '\n' ' ')"
            fi
            while IFS= read -r line; do
                [[ -z "${line}" ]] && continue
                printf '::error title=Periphery::%s\n' "${line//%/%25}"
            done <<< "${hits}"
        fi
        echo "Periphery scan failed (exit ${scan_status}). Nothing was deleted." >&2
        exit "${scan_status}"
    fi

    python3 - "${SCAN_JSON}" "${REPORT}" <<'PYEOF'
import json, sys, datetime

scan_path, report_path = sys.argv[1], sys.argv[2]
with open(scan_path) as fh:
    results = json.load(fh)

by_kind = {}
for item in results:
    by_kind.setdefault(item.get("kind", "unknown"), []).append(item)

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
lines = [
    "# Dead Code Report",
    "",
    f"_Generated {now} by Periphery — review before deleting anything._",
    "",
    f"**Total findings: {len(results)}**",
    "",
    "| Kind | Count |",
    "| --- | --- |",
]
for kind, items in sorted(by_kind.items(), key=lambda kv: -len(kv[1])):
    lines.append(f"| {kind} | {len(items)} |")
lines.append("")
for kind, items in sorted(by_kind.items(), key=lambda kv: -len(kv[1])):
    lines.append(f"## {kind} ({len(items)})")
    lines.append("")
    for item in sorted(items, key=lambda i: (i.get("location", {}).get("file", ""), i.get("location", {}).get("line", 0))):
        loc = item.get("location", {})
        name = item.get("name", "?")
        hint = item.get("hint", "")
        where = f"{loc.get('file', '?')}:{loc.get('line', '?')}"
        suffix = f" — {hint}" if hint else ""
        lines.append(f"- `{name}` ({where}){suffix}")
    lines.append("")

with open(report_path, "w") as fh:
    fh.write("\n".join(lines))
print(f"Periphery report written to {report_path}: {len(results)} finding(s).")
PYEOF
    total=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "${SCAN_JSON}")
else
    echo "Periphery not available — generating the heuristic reference report."
    python3 - "${REPORT}" <<'PYEOF'
import re, sys, pathlib, datetime

report_path = sys.argv[1]
root = pathlib.Path("ZynSign")

decl = re.compile(
    r"^(?:@\w+\s+)*(?:public |open |package |internal |final |indirect |nonisolated )*"
    r"(struct|class|enum|actor|protocol)\s+([A-Z][A-Za-z0-9_]+)"
)

sources = list(root.rglob("*.swift"))
declared = {}   # name -> file
for path in sources:
    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        m = decl.match(line)
        if m:
            declared.setdefault(m.group(2), str(path))

# Reference count: files mentioning the name as a whole word, in one
# union-pattern pass over the tree.
mentioned_in = {name: set() for name in declared}
union = re.compile(r"\b(?:" + "|".join(re.escape(n) for n in declared) + r")\b")
for path in sources:
    text = path.read_text(encoding="utf-8")
    for m in union.finditer(text):
        mentioned_in[m.group(0)].add(str(path))

unused = sorted(n for n, files in mentioned_in.items() if len(files) <= 1)
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
lines = [
    "# Dead Code Report",
    "",
    f"_Generated {now} — **heuristic fallback** (Periphery unavailable)._",
    "",
    "A candidate is a top-level type whose name appears in no other file.",
    "False positives are possible (dynamic use, strings, previews).",
    "Review before deleting anything.",
    "",
    f"**Candidates: {len(unused)}**",
    "",
]
for name in unused:
    lines.append(f"- `{name}` ({declared[name]})")
with open(report_path, "w") as fh:
    fh.write("\n".join(lines) + "\n")
print(f"Heuristic report written to {report_path}: {len(unused)} candidate(s).")
PYEOF
    total=$(grep -c '^- `' "${REPORT}" || true)
fi

{
    echo "engine=${ENGINE}"
    echo "candidates=${total}"
} > "${METRICS_DIR}/dead_code.txt"

echo "Dead code scan complete (${ENGINE}): ${total} candidate(s). Nothing was deleted."
