#!/usr/bin/env python3
"""
audit_design_tokens.py — where Presentation still spells a design value by hand.

The design system (`Presentation/DesignSystem`) owns spacing, radius, shadow,
colour, typography, motion and haptics. This script lists every place in
`Presentation/` that writes one of those as a literal instead — the raw
material for a consolidation pass, and afterwards the guard that keeps the
count from growing.

It reports, per category:
  colour     Color(red:green:blue:), Color(hex…), UIColor(red:…)
  radius     cornerRadius: <n> / .cornerRadius(<n>) with a numeric literal
  spacing    .padding(<n>) / spacing: <n> off the 4-pt grid or above 48
  font       .font(.system(size: <n>…)) fixed sizes (Dynamic Type breaks)
  shadow     .shadow(color:radius:…) written inline
  motion     .easeInOut(duration:) / .spring(response:) / .linear(duration:) written inline
  haptics    UIImpactFeedbackGenerator / UINotificationFeedbackGenerator / UISelectionFeedbackGenerator
             outside ZHaptics

Usage:
    python3 Scripts/audit_design_tokens.py                # report
    python3 Scripts/audit_design_tokens.py --markdown     # for docs/internal
    python3 Scripts/audit_design_tokens.py --baseline Scripts/design_tokens_baseline.json --check
                                                          # fail if any category grew
    python3 Scripts/audit_design_tokens.py --write-baseline Scripts/design_tokens_baseline.json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PRESENTATION = ROOT / "ZynSign" / "Presentation"
DESIGN_SYSTEM = PRESENTATION / "DesignSystem"

GRID = {0, 1, 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 44, 48}

PATTERNS = {
    "colour": re.compile(r"\b(?:UI)?Color\(\s*(?:red|hex|\.sRGB|white:)\s*"),
    "radius": re.compile(r"cornerRadius:\s*(\d+(?:\.\d+)?)|\.cornerRadius\(\s*(\d+(?:\.\d+)?)"),
    "spacing": re.compile(r"\.padding\((?:\.\w+,\s*)?(\d+(?:\.\d+)?)\)|spacing:\s*(\d+(?:\.\d+)?)\b"),
    "font": re.compile(r"\.font\(\s*\.system\(\s*size:\s*(\d+(?:\.\d+)?)"),
    "shadow": re.compile(r"\.shadow\(\s*color:"),
    "motion": re.compile(r"\.(?:easeInOut|easeOut|easeIn|linear)\(\s*duration:\s*(\d*\.?\d+)|\.spring\(\s*response:\s*(\d*\.?\d+)"),
    "haptics": re.compile(r"UI(?:Impact|Notification|Selection)FeedbackGenerator"),
}


def scan() -> dict[str, list[dict]]:
    findings: dict[str, list[dict]] = defaultdict(list)
    for path in sorted(PRESENTATION.rglob("*.swift")):
        in_design_system = DESIGN_SYSTEM in path.parents
        rel = str(path.relative_to(ROOT))
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("///"):
                continue
            for category, rx in PATTERNS.items():
                if in_design_system and category in {"colour", "shadow", "motion", "haptics", "radius", "spacing", "font"}:
                    # The design system is allowed to define values; only call sites are audited.
                    continue
                for m in rx.finditer(line):
                    value = next((g for g in m.groups() if g), None) if m.groups() else None
                    if category == "spacing" and value is not None:
                        try:
                            v = float(value)
                        except ValueError:
                            continue
                        if v in GRID:
                            continue
                    findings[category].append({"file": rel, "line": lineno, "value": value, "text": stripped[:140]})
    return findings


def summary(findings: dict[str, list[dict]]) -> dict[str, int]:
    return {k: len(findings.get(k, [])) for k in PATTERNS}


def render_text(findings: dict[str, list[dict]]) -> str:
    out = []
    for category in PATTERNS:
        items = findings.get(category, [])
        out.append(f"{category:8} {len(items):4}")
    return "\n".join(out)


def render_markdown(findings: dict[str, list[dict]]) -> str:
    counts = summary(findings)
    lines = ["| Category | Call sites | Distinct values | Files |", "|---|---|---|---|"]
    for category in PATTERNS:
        items = findings.get(category, [])
        values = sorted({i["value"] for i in items if i["value"] is not None}, key=lambda s: float(s))
        files = len({i["file"] for i in items})
        shown = ", ".join(values[:14]) + (" …" if len(values) > 14 else "")
        lines.append(f"| {category} | {counts[category]} | {shown or '—'} | {files} |")
    lines.append("")
    for category in PATTERNS:
        items = findings.get(category, [])
        if not items:
            continue
        lines.append(f"### {category} ({len(items)})")
        lines.append("")
        by_file: dict[str, list[dict]] = defaultdict(list)
        for i in items:
            by_file[i["file"]].append(i)
        for file, hits in sorted(by_file.items(), key=lambda kv: -len(kv[1]))[:25]:
            lines.append(f"- `{file}` — {len(hits)}: " + ", ".join(f"L{h['line']}" + (f" ({h['value']})" if h["value"] else "") for h in hits[:8]) + (" …" if len(hits) > 8 else ""))
        if len(by_file) > 25:
            lines.append(f"- … and {len(by_file) - 25} more files")
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--baseline", type=Path)
    ap.add_argument("--write-baseline", type=Path)
    ap.add_argument("--check", action="store_true", help="exit 1 if any category exceeds the baseline")
    args = ap.parse_args()

    findings = scan()
    counts = summary(findings)

    if args.write_baseline:
        args.write_baseline.write_text(json.dumps(counts, indent=2) + "\n")
        print(f"baseline written: {args.write_baseline} {counts}")
        return 0
    if args.json:
        print(json.dumps({"counts": counts, "findings": findings}, indent=2))
        return 0
    if args.markdown:
        print(render_markdown(findings))
        return 0

    print(render_text(findings))
    if args.baseline and args.check:
        base = json.loads(args.baseline.read_text())
        grew = {k: (base.get(k, 0), v) for k, v in counts.items() if v > base.get(k, 0)}
        if grew:
            print("✗ Hand-written design values grew past the baseline:")
            for k, (b, v) in grew.items():
                print(f"    {k}: {b} → {v}")
            return 1
        print("✓ No category exceeds the design-token baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
