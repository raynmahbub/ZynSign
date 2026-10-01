#!/usr/bin/env python3
"""
audit_identity_stability.py — presentation identities that are minted per read.

SwiftUI reads an item's `Identifiable.id` on every body evaluation. An identity
*computed* from a fresh value — `var id: String { UUID().uuidString }` — names a
different item every time the view re-renders, so `.sheet(item:)`,
`.fullScreenCover(item:)`, and `ForEach` see a new item and rebuild, or
re-present, the view the user is looking at whenever the model publishes. On a
screen that publishes during work — an import, a delivery, a signing run — that
is a sheet that flickers, resets, or dismisses itself.

The rule is one line long: an identity is *stored*, minted once when the value
that carries it is created. Every identifier in the app followed that rule
except one hand-off sheet, which this script keeps fixed.

Usage:
    python3 Scripts/audit_identity_stability.py            # report
    python3 Scripts/audit_identity_stability.py --json     # machine-readable
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_DIR = ROOT / "ZynSign"

# A computed `id`: the declaration, whose body is read for a per-read value.
COMPUTED_ID = re.compile(
    r"^\s*(?:@\w+\s+)?(?:public\s+|internal\s+|fileprivate\s+|private\s+)?"
    r"var\s+id\s*:\s*[^=]+?(?P<brace>\{)"
)

# A value that is different on every read: minting an identifier, reading the
# clock, or taking a heap identity.
PER_READ_VALUE = re.compile(
    r"UUID\(\)\.uuidString|UUID\(\)|Date\(\)|CACurrentMediaTime\(\)|"
    r"DispatchTime\.now\(\)|ObjectIdentifier\(self\)|\.now\b"
)


def swift_files() -> list[Path]:
    return sorted(APP_DIR.rglob("*.swift"))


def body_of(lines: list[str], start: int, brace_column: int) -> str:
    """The text of the declaration's body, from `{` to its matching `}`."""
    depth = 0
    collected: list[str] = []
    for number in range(start, min(start + 12, len(lines))):
        line = lines[number]
        collected.append(line[brace_column:] if number == start else line)
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            break
    return "\n".join(collected)


def scan(path: Path) -> list[dict]:
    """Every computed identity that is minted per read, in one file."""
    findings: list[dict] = []
    lines = path.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        match = COMPUTED_ID.match(line)
        if not match:
            continue
        body = body_of(lines, index, match.start("brace"))
        per_read = PER_READ_VALUE.search(body)
        if per_read:
            findings.append(
                {
                    "file": str(path.relative_to(ROOT)),
                    "line": index + 1,
                    "text": stripped,
                    "value": per_read.group(0),
                    "why": "An identity computed from a fresh value changes on every read; "
                           "store it when the value is created instead.",
                }
            )
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="machine-readable")
    args = parser.parse_args()

    findings: list[dict] = []
    for path in swift_files():
        findings.extend(scan(path))

    if args.json:
        print(json.dumps({"findings": findings, "count": len(findings)}, indent=2))
        return 1 if findings else 0

    print("Identity stability audit — presentation identities that stay put")
    print()
    if not findings:
        print("✓ Every `Identifiable.id` in the app is stored, not minted per read.")
        return 0
    print(f"✗ {len(findings)} computed identity(ies) mint a fresh value per read:")
    for finding in findings:
        print(f"  · {finding['file']}:{finding['line']} — {finding['text']}")
        print(f"      {finding['why']} (found `{finding['value']}`)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
