#!/usr/bin/env python3
"""
audit_accessibility.py — the half of the accessibility audit a machine can make.

ZynSign's accessibility pass is two audits: one a script can run, and one a
human has to. This script is the first. It checks the two things that are true
in the source and decide what a screen can do:

  · a colour that is not chosen from DesignTokens cannot adapt to Increase
    Contrast, to Dark Appearance, or to the platform's own contrast
    maintenance, so a hard-coded colour is a contrast defect by construction;
  · a control with a fixed frame smaller than 44x44 points is not a
    comfortable touch target, whatever it looks like.

It never claims a screen is accessible. Half of the audit — VoiceOver's
reading, the rendered contrast ratio, the focus order a reader experiences —
belongs to a person with the Accessibility Inspector, and the report this
script writes names that explicitly.

Usage:
    python3 Scripts/audit_accessibility.py                 # report
    python3 Scripts/audit_accessibility.py --json          # machine-readable
    python3 Scripts/audit_accessibility.py \
        --overlay-out build/lab-overlay.json               # for the Lab
    python3 Scripts/audit_accessibility.py --strict        # fail on findings
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_DIR = ROOT / "ZynSign"
DESIGN_SYSTEM = APP_DIR / "Presentation" / "DesignSystem"

# A colour built from numbers rather than chosen from the token system.
HARD_CODED_COLOUR = re.compile(
    r"Color\(\s*(?:red|green|blue|white|hue|red:|red\s*:|\.sRGB|displayP3|uiColor:|hex:)|"
    r"Color\(\s*CGColor|UIColor\(\s*(?:red|white|hue|displayP3)"
)

# A fixed frame with both dimensions given as literals.
FIXED_FRAME = re.compile(
    r"\.frame\(\s*width:\s*([0-9]+(?:\.[0-9]+)?)\s*,\s*height:\s*([0-9]+(?:\.[0-9]+)?)"
)

# A fixed frame with a single literal size (a square).
FIXED_SQUARE = re.compile(r"\.frame\(\s*(?:width|height):\s*([0-9]+(?:\.[0-9]+)?)")

# What makes a small frame a control rather than decoration.
INTERACTIVE = re.compile(r"Button|onTapGesture|\.buttonStyle|Toggle|Link\(|Menu\(")

# A minimum scale factor below which text is not comfortably readable at the
# sizes Dynamic Type can ask for.
MINIMUM_SCALE = re.compile(r"minimumScaleFactor\(\s*([0-9]*\.?[0-9]+)\s*\)")

MINIMUM_TOUCH_TARGET = 44.0
COMFORTABLE_SCALE_FACTOR = 0.75

# How far above a frame an interactive marker may sit and still describe it.
# A `Button { ... } label: {` opens one or two lines above its content, and a
# control's own modifiers follow on its own lines - but a decorative icon in a
# row must not be blamed for the menu four lines below it.
INTERACTIVE_WINDOW_BEFORE = 2
INTERACTIVE_WINDOW_AFTER = 1

# Findings that were looked at and accepted, each with the reason.
#
# A waiver is a decision, not a silence: it is printed whenever the audit
# runs, and it names the file, the shape, and the reasoning, so a reviewer
# can disagree with it. Line numbers are deliberately not used - they move
# when a file is edited; the shape is what is being waived.
WAIVERS: list[tuple[str, str, str, str]] = [
    (
        "ZynSign/Presentation/AppIconView.swift",
        "hardCodedColour",
        "Color(hue:",
        "A synthesised application icon, derived from the bundle identifier so the same application always shows the same mark. It is decoration standing in for an icon the package declared, not interface chrome: it carries no text, and it is marked as an image for VoiceOver. Keeping it out of the token system is what keeps it recognisable as a placeholder.",
    ),
    (
        "ZynSign/Presentation/InstallationWorkspaceComponents.swift",
        "hardCodedColour",
        "Color(hue:",
        "A synthesised application icon, derived from the bundle identifier so the same application always shows the same mark. It is decoration standing in for an icon the package declared, not interface chrome: it carries no text, and it is marked as an image for VoiceOver. Keeping it out of the token system is what keeps it recognisable as a placeholder.",
    ),
]


def swift_files() -> list[Path]:
    return sorted(APP_DIR.rglob("*.swift"))


def is_design_system(path: Path) -> bool:
    try:
        path.relative_to(DESIGN_SYSTEM)
        return True
    except ValueError:
        return False


def waiver_for(relative: str, kind: str, text: str) -> str | None:
    """The reason this finding was accepted, when it was."""
    for file_suffix, waiver_kind, shape, reason in WAIVERS:
        if relative.endswith(file_suffix) and kind == waiver_kind and shape in text:
            return reason
    return None


def scan(path: Path) -> list[dict]:
    """Every finding in one file, with the line that carries it."""
    findings: list[dict] = []
    relative = str(path.relative_to(ROOT))
    lines = path.read_text(encoding="utf-8").splitlines()
    for number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if stripped.startswith("//"):
            continue

        if not is_design_system(path) and HARD_CODED_COLOUR.search(line):
            findings.append(
                {
                    "kind": "hardCodedColour",
                    "severity": "finding",
                    "line": number,
                    "text": stripped,
                    "why": "A colour built from numbers cannot adapt to Increase Contrast or Dark Appearance; choose it from DesignTokens.",
                    "waiver": waiver_for(relative, "hardCodedColour", stripped),
                }
            )

        # A control's target size. A fixed frame is only a target when the
        # view is interactive, so decoration - an icon, a divider, a badge -
        # is not reported.
        window = "\n".join(
            lines[
                max(0, number - 1 - INTERACTIVE_WINDOW_BEFORE) : min(
                    len(lines), number + INTERACTIVE_WINDOW_AFTER
                )
            ]
        )
        if INTERACTIVE.search(window):
            match = FIXED_FRAME.search(line)
            size = None
            if match:
                size = (float(match.group(1)), float(match.group(2)))
            else:
                match = FIXED_SQUARE.search(line)
                if match:
                    value = float(match.group(1))
                    size = (value, value)
            if size and (size[0] < MINIMUM_TOUCH_TARGET or size[1] < MINIMUM_TOUCH_TARGET):
                findings.append(
                    {
                        "kind": "smallTouchTarget",
                        "severity": "finding",
                        "line": number,
                        "text": stripped,
                        "why": f"A control with a fixed frame of {size[0]:g}x{size[1]:g} is below {MINIMUM_TOUCH_TARGET:g}x{MINIMUM_TOUCH_TARGET:g} points.",
                        "waiver": waiver_for(relative, "smallTouchTarget", stripped),
                    }
                )

        match = MINIMUM_SCALE.search(line)
        if match and float(match.group(1)) < COMFORTABLE_SCALE_FACTOR:
            findings.append(
                {
                    "kind": "textScaling",
                    "severity": "review",
                    "line": number,
                    "text": stripped,
                    "why": f"Text may shrink to {float(match.group(1)):g} of its size, which is uncomfortable at the smaller Dynamic Type sizes.",
                }
            )
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument(
        "--overlay-out",
        type=Path,
        help="write a Compatibility Lab overlay with the rows this audit settles",
    )
    parser.add_argument("--strict", action="store_true", help="exit non-zero when there are findings")
    args = parser.parse_args()

    results: list[dict] = []
    for path in swift_files():
        findings = scan(path)
        if findings:
            results.append({"file": str(path.relative_to(ROOT)), "findings": findings})

    all_findings = [f for entry in results for f in entry["findings"]]
    waived = [f for f in all_findings if f.get("waiver")]
    open_findings = [f for f in all_findings if not f.get("waiver")]
    hard_coded = [f for f in open_findings if f["kind"] == "hardCodedColour"]
    touch_targets = [f for f in open_findings if f["kind"] == "smallTouchTarget"]
    reviews = [f for f in open_findings if f["kind"] == "textScaling"]

    # The rows this audit settles, for the Compatibility Lab to import. It
    # settles two of the six and says nothing about the rest.
    statuses = {
        "accessibility.contrast": "passed" if not hard_coded else "failed",
        "accessibility.touchTargets": "passed" if not touch_targets else "failed",
    }
    overlay = {
        "source": "Scripts/audit_accessibility.py on the host",
        "statuses": statuses,
    }

    if args.overlay_out:
        args.overlay_out.parent.mkdir(parents=True, exist_ok=True)
        args.overlay_out.write_text(json.dumps(overlay, indent=2) + "\n", encoding="utf-8")

    if args.json:
        print(
            json.dumps(
                {
                    "findings": open_findings,
                    "waived": waived,
                    "files": results,
                    "overlay": overlay,
                    "counts": {
                        "hardCodedColour": len(hard_coded),
                        "smallTouchTarget": len(touch_targets),
                        "textScaling": len(reviews),
                        "waived": len(waived),
                    },
                },
                indent=2,
            )
        )
        return 1 if (args.strict and (hard_coded or touch_targets)) else 0

    print("Accessibility audit — the half a machine can check")
    print()
    print(f"  Hard-coded colours outside DesignTokens: {len(hard_coded)}")
    print(f"  Controls below {MINIMUM_TOUCH_TARGET:g}x{MINIMUM_TOUCH_TARGET:g} points: {len(touch_targets)}")
    print(f"  Text that may shrink below {COMFORTABLE_SCALE_FACTOR:g} scale (review): {len(reviews)}")
    print(f"  Waived after review: {len(waived)}")
    if waived:
        for finding in waived:
            print(f"      {finding['kind']} in {finding['text'][:64]}")
    if open_findings:
        print()
        for entry in results:
            print(f"  {entry['file']}")
            for finding in entry["findings"]:
                if finding.get("waiver"):
                    continue
                print(f"      {finding['line']}: [{finding['kind']}] {finding['text'][:96]}")
                print(f"          {finding['why']}")
    print()
    print("  Rows this audit settles for the Compatibility Lab:")
    for row, status in statuses.items():
        print(f"      {row}: {status}")
    print()
    print("  Not settled here — a human pass in docs/hardening/accessibility-audit.md:")
    print("      accessibility.voiceOver · accessibility.focusOrder")
    print("      the rendered contrast ratio, at every Dynamic Type size")

    if args.strict and (hard_coded or touch_targets):
        print(
            "\n✗ Findings must be fixed or justified in docs/hardening/accessibility-audit.md",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
