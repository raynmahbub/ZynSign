#!/usr/bin/env bash
#
# ZynSign CI — complexity guard.
#
# Warns when code crosses the recommended thresholds. Warnings only —
# this check reports and annotates, it never blocks a merge:
#
#   function body   > 80 lines
#   file            > 800 lines
#   nesting depth   > 4 levels
#
# Workflows call this script; CI logic lives here, never in YAML.
# Pass --strict to make findings fail the run (reserved for the future).
#
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

METRICS_DIR="build/metrics"
mkdir -p "${METRICS_DIR}"

python3 - "${STRICT}" "${METRICS_DIR}/complexity.txt" <<'PYEOF'
import re, sys, pathlib

strict = sys.argv[1] == "1"
metrics_path = sys.argv[2]

FUNC_LIMIT, FILE_LIMIT, NEST_LIMIT = 80, 800, 4

func_start = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:public|open|package|internal|private|fileprivate|final|static|nonisolated|convenience|required|mutating)\s+)*func\s+([A-Za-z0-9_]+|[^(\s]+)")

def strip(line: str) -> str:
    line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    return re.sub(r"//.*$", "", line)

findings = []
worst = {"function": (0, ""), "file": (0, ""), "nesting": (0, "")}

for path in sorted(pathlib.Path("ZynSign").rglob("*.swift")):
    lines = path.read_text(encoding="utf-8").splitlines()
    stripped = [strip(l) for l in lines]

    if len(lines) > FILE_LIMIT:
        findings.append(("file-length", str(path), 0, f"{len(lines)} lines (limit {FILE_LIMIT})"))
        if len(lines) > worst["file"][0]:
            worst["file"] = (len(lines), str(path))

    # Function bodies: from the func line until braces balance.
    i = 0
    while i < len(stripped):
        m = func_start.match(stripped[i])
        if not m:
            i += 1
            continue
        depth = 0
        started = False
        j = i
        while j < len(stripped):
            depth += stripped[j].count("{") - stripped[j].count("}")
            if "{" in stripped[j]:
                started = True
            if started and depth <= 0:
                break
            j += 1
        body = j - i
        name = m.group(1)
        if body > FUNC_LIMIT:
            findings.append(("function-length", str(path), i + 1, f"func {name}: {body} lines (limit {FUNC_LIMIT})"))
            if body > worst["function"][0]:
                worst["function"] = (body, f"{path}:{i + 1} func {name}")
        # Nesting depth inside the body (depth 1 = function scope).
        depth = 0
        max_depth = 0
        for k in range(i, min(j + 1, len(stripped))):
            for ch in stripped[k]:
                if ch == "{":
                    depth += 1
                    max_depth = max(max_depth, depth)
                elif ch == "}":
                    depth -= 1
        if max_depth - 1 > NEST_LIMIT:  # subtract the function's own brace
            findings.append(("nesting", str(path), i + 1, f"func {name}: nesting {max_depth - 1} (limit {NEST_LIMIT})"))
            if max_depth - 1 > worst["nesting"][0]:
                worst["nesting"] = (max_depth - 1, f"{path}:{i + 1} func {name}")
        i = j + 1

for kind, file, line, msg in findings:
    loc = f"file={file}" + (f",line={line}" if line else "")
    print(f"::warning {loc},title=complexity::{msg}")

with open(metrics_path, "w") as fh:
    fh.write(f"findings={len(findings)}\n")
    fh.write(f"function_limit={FUNC_LIMIT}\n")
    fh.write(f"file_limit={FILE_LIMIT}\n")
    fh.write(f"nesting_limit={NEST_LIMIT}\n")
    fh.write(f"worst_function={worst['function'][0]} lines at {worst['function'][1]}\n")
    fh.write(f"worst_file={worst['file'][0]} lines at {worst['file'][1]}\n")
    fh.write(f"worst_nesting={worst['nesting'][0]} at {worst['nesting'][1]}\n")

print(f"Complexity guard: {len(findings)} finding(s) above thresholds — warnings only."
      if not strict else f"Complexity guard: {len(findings)} finding(s).")
sys.exit(1 if strict and findings else 0)
PYEOF
