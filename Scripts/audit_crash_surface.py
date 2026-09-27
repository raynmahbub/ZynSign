#!/usr/bin/env python3
"""
audit_crash_surface.py — keep ZynSign's crash surface at what it claims.

Crash hardening is not a document: it is an inventory that stays true. This
script scans the application's own sources for the constructs that turn a
recoverable condition into a crash — `try!`, `as!`, force unwraps,
`fatalError`, `preconditionFailure`, `precondition`, `assertionFailure`, and
`unowned` — and compares what it finds against
`ZynSign/Application/CompatibilityLab/CrashSurfaceBaseline.swift`.

Every construct must either be absent or be named in the baseline with a
reason. A new one fails the job, which is the point: the inventory is the
gate, and the gate is where a release decision reads it.

Usage:
    python3 Scripts/audit_crash_surface.py            # compare and report
    python3 Scripts/audit_crash_surface.py --list      # show every finding
    python3 Scripts/audit_crash_surface.py --json      # machine-readable output
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_DIR = ROOT / "ZynSign"
BASELINE = APP_DIR / "Application" / "CompatibilityLab" / "CrashSurfaceBaseline.swift"

# Boolean negation is not a force unwrap. These are the shapes a `!` may
# legitimately appear in as an operator rather than as an unwrap.
NEGATION_CONTEXT = re.compile(r"(?:^|[\s\(\[,]|&&|\|\||return|==|!=)\s*!(?=[A-Za-z0-9_\(])")

# A property declared with an implicitly unwrapped optional type. It is a
# crash surface of its own kind - a nil read traps - but it is reported
# separately because the remedy (a `let` assigned in the initializer) is
# different from the remedy for an unwrap in an expression.
IMPLICITLY_UNWRAPPED = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s*)*(?:private|fileprivate|internal|public|open|weak)?\s*"
    r"(?:var|let)\s+\w+\s*:\s*[A-Za-z_][\w\.\<\>\,\s\?\&\:\[\]]*!\s*$"
)

# The construct vocabulary. Each entry is a label and a regex over
# comment- and string-stripped source.
CONSTRUCTS: list[tuple[str, str]] = [
    ("try!", r"try\s*!(?!=)"),
    ("as!", r"\bas\s*!(?!=)"),
    ("forceUnwrap", r"[A-Za-z0-9_\)\]\]]!(?!=)"),
    ("implicitlyUnwrappedOptional", IMPLICITLY_UNWRAPPED.pattern),
    ("fatalError", r"\bfatalError\s*\("),
    ("preconditionFailure", r"\bpreconditionFailure\s*\("),
    ("precondition", r"\bprecondition\s*\("),
    ("assertionFailure", r"\bassertionFailure\s*\("),
    ("unowned", r"\bunowned\b"),
]


def is_declaration_line(line: str) -> bool:
    """Whether a `!` on this line belongs to the declaration, not an unwrap."""
    return IMPLICITLY_UNWRAPPED.match(line) is not None


def strip_comments_and_strings(source: str) -> str:
    """Blank out comments, string literals and doc-comment text.

    The scan is deliberately syntactic: a `try!` written inside a string or
    a comment is prose, not a crash.
    """
    out: list[str] = []
    i = 0
    n = len(source)
    while i < n:
        char = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if char == "/" and nxt == "/":
            while i < n and source[i] != "\n":
                i += 1
        elif char == "/" and nxt == "*":
            i += 2
            while i < n and not (source[i] == "*" and i + 1 < n and source[i + 1] == "/"):
                out.append("\n" if source[i] == "\n" else " ")
                i += 1
            i += 2
        elif char == '"':
            # A multi-line string literal (""" ... """) is skipped whole.
            triple = source.startswith('"""', i)
            closing = '"""' if triple else '"'
            i += len(closing)
            while i < n and not source.startswith(closing, i):
                if source[i] == "\\" and not triple:
                    i += 2
                    continue
                out.append("\n" if source[i] == "\n" else " ")
                i += 1
            i += len(closing)
        elif char == "#" and source.startswith("#if", i):
            # Keep preprocessor conditionals: they say which build a line
            # compiles into, and the baseline reasons about exactly that.
            out.append(char)
            i += 1
        else:
            out.append(char)
            i += 1
    return "".join(out)


def scan(path: Path) -> list[tuple[str, int, str]]:
    """Return (construct, line, text) for every construct in `path`."""
    cleaned = strip_comments_and_strings(path.read_text(encoding="utf-8"))
    findings: list[tuple[str, int, str]] = []
    lines = cleaned.splitlines()
    for number, line in enumerate(lines, start=1):
        for label, pattern in CONSTRUCTS:
            if pattern is None:
                continue
            for match in re.finditer(pattern, line):
                if label == "forceUnwrap":
                    # A declaration's own `!` is reported as the declaration.
                    if is_declaration_line(line):
                        continue
                    # Boolean negation is not an unwrap.
                    start = max(0, match.start() - 12)
                    window = line[start : match.end() + 1]
                    if NEGATION_CONTEXT.search(window):
                        continue
                findings.append((label, number, line.strip()))
    return findings


def scan_tree() -> dict[str, Counter]:
    """Every construct found, per file relative to the repository root."""
    results: dict[str, Counter] = {}
    for path in sorted(APP_DIR.rglob("*.swift")):
        findings = scan(path)
        if findings:
            results[str(path.relative_to(ROOT))] = Counter(label for label, _, _ in findings)
    return results


# --------------------------------------------------------------- baseline


def load_baseline() -> list[dict]:
    """Parses the Swift baseline into the same shape the scan produces.

    The baseline is Swift rather than JSON because it lives beside the code
    it describes, is type-checked by the build, and is readable by the
    Compatibility Lab, which shows it as part of the crash-status category.
    """
    if not BASELINE.exists():
        raise SystemExit(f"Baseline not found: {BASELINE}")
    text = BASELINE.read_text(encoding="utf-8")
    entries: list[dict] = []
    pattern = re.compile(
        r"Expectation\(\s*file:\s*\"([^\"]+)\"\s*,\s*construct:\s*\"([^\"]+)\"\s*,"
        r"\s*count:\s*(\d+)\s*,\s*rationale:\s*\"(.*?)\"\s*\)",
        re.DOTALL,
    )
    for match in pattern.finditer(text):
        entries.append(
            {
                "file": match.group(1),
                "construct": match.group(2),
                "count": int(match.group(3)),
                "rationale": " ".join(match.group(4).split()),
            }
        )
    return entries


# --------------------------------------------------------------- reporting


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="show every finding")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    found = scan_tree()
    baseline = load_baseline()

    expected: dict[tuple[str, str], int] = {}
    for entry in baseline:
        key = (entry["file"], entry["construct"])
        expected[key] = expected.get(key, 0) + entry["count"]

    actual: dict[tuple[str, str], int] = {}
    for file, counts in found.items():
        for construct, count in counts.items():
            actual[(file, construct)] = count

    problems: list[str] = []
    for key in sorted(set(expected) | set(actual)):
        want = expected.get(key, 0)
        have = actual.get(key, 0)
        if want != have:
            file, construct = key
            if have == 0:
                problems.append(
                    f"{file}: baseline expects {want} × {construct} but the scan found none "
                    f"— the construct is gone, so the baseline entry should go too"
                )
            elif want == 0:
                problems.append(
                    f"{file}: {have} × {construct} is not in the baseline. Either fix it or "
                    f"add a justified Expectation to CrashSurfaceBaseline.swift"
                )
            else:
                problems.append(f"{file}: {have} × {construct}, baseline says {want}")

    # An expectation naming a file that no longer exists is drift of the same
    # kind: the inventory must describe the code that is actually there.
    for (file, construct), want in sorted(expected.items()):
        if want and not (ROOT / file).exists():
            problems.append(f"{file}: baseline names a file that does not exist")

    if args.json:
        print(
            json.dumps(
                {
                    "findings": [
                        {"file": file, "construct": construct, "count": count}
                        for (file, construct), count in sorted(actual.items())
                    ],
                    "baseline": baseline,
                    "problems": problems,
                    "ok": not problems,
                },
                indent=2,
            )
        )
        return 0 if not problems else 1

    total = sum(actual.values())
    if args.list or problems:
        for file, counts in found.items():
            detail = ", ".join(f"{construct} × {count}" for construct, count in sorted(counts.items()))
            print(f"  {file}: {detail}")
            if args.list:
                for label, number, text in scan(ROOT / file):
                    print(f"      {number}: [{label}] {text[:110]}")
        print()

    if problems:
        print(f"✗ Crash surface does not match its baseline ({total} construct(s) found):", file=sys.stderr)
        for problem in problems:
            print(f"  · {problem}", file=sys.stderr)
        return 1

    waived = sum(actual.values())
    print(f"✓ Crash surface matches its baseline: {waived} construct(s), every one justified.")
    for entry in baseline:
        print(f"  · {entry['file']}: {entry['construct']} × {entry['count']} — {entry['rationale'][:96]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
