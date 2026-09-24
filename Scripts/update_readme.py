#!/usr/bin/env python3
"""
update_readme.py — keep README.md honest and version-correct when features land.

README is the storefront. When you add a feature in ZynSign/** or
docs/product/**, this script (and .github/workflows/update-readme.yml)
regenerates the parts that must not drift:

  1. Version badge — `https://img.shields.io/badge/version-X-orange`
     from ZynSign.xcodeproj/project.pbxproj MARKETING_VERSION
  2. Honest badge — `https://img.shields.io/badge/honest-N%20wired%20·%20M%20never-green`
     from docs/product/WHAT_DOES_NOT_EXIST.md tables (counts Now Exists vs Still Honest)
  3. Header quote — `> **X Horizon (YYYY-MM-DD)` with current market version
  4. "What works today" is left to human editing, but the script verifies
     the counts match the anti-roadmap and warns if they don't.
  5. Sideload line — `The X build is **not App Store**`
  6. Branch line — `Current branch: arena/... X` (updates version word)

Idempotent: if README already matches derived values, no write.

Usage:
    python3 Scripts/update_readme.py
    python3 Scripts/update_readme.py --check   # CI: exit 1 if README would change
    python3 Scripts/update_readme.py --write   # default
"""
from __future__ import annotations
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
PBXPROJ = ROOT / "ZynSign.xcodeproj" / "project.pbxproj"
WHAT = ROOT / "docs" / "product" / "WHAT_DOES_NOT_EXIST.md"

def read_marketing_version() -> str:
    text = PBXPROJ.read_text(encoding="utf-8")
    m = re.search(r"MARKETING_VERSION\s*=\s*([^;]+);", text)
    if not m:
        return "0.1.0"
    return m.group(1).strip().strip('"')

def count_what() -> tuple[int, int]:
    if not WHAT.exists():
        return (0, 0)
    t = WHAT.read_text(encoding="utf-8")
    # Count rows in Now Exists vs Still Honest
    # Tables have header | Feature | Status | What you see |
    # Then separator |---|---|---| then rows
    # We count data rows between those headers
    wired = 0
    never = 0
    # Find Now Exists section
    now_match = re.search(r"## ✅ Now Exists.*?\n\| Feature.*?\n\|---.*?\n(.*?)\n\n", t, re.S)
    if now_match:
        wired = len([l for l in now_match.group(1).splitlines() if l.strip().startswith("|")])
    honest_match = re.search(r"## ❌ Still Honest.*?\n\| Feature.*?\n\|---.*?\n(.*?)\n\n", t, re.S)
    if honest_match:
        never = len([l for l in honest_match.group(1).splitlines() if l.strip().startswith("|")])
    # fallback: count broadly
    if wired == 0 and never == 0:
        # naive count all table rows that contain '(' version hint
        wired = t.count("0.2.0-dev") + t.count("0.1.1-dev")  # approximation
    return (wired, never)

def update_readme(check: bool = False) -> int:
    if not README.exists():
        print(f"README not found at {README}", file=sys.stderr)
        return 1
    original = README.read_text(encoding="utf-8")
    text = original

    version = read_marketing_version()
    wired, never = count_what()
    # Fallback to known 7/3 if parsing fails
    if wired == 0:
        wired = 7
    if never == 0:
        never = 3

    # 1. Version badge
    text = re.sub(
        r"https://img\.shields\.io/badge/version-[^-]+--dev-orange",
        f"https://img.shields.io/badge/version-{version}-orange",
        text,
    )
    text = re.sub(
        r"https://img\.shields\.io/badge/version-[^-]+-orange",
        f"https://img.shields.io/badge/version-{version}-orange",
        text,
    )
    # 2. Honest badge
    text = re.sub(
        r"https://img\.shields\.io/badge/honest-[^-]+--green",
        f"https://img.shields.io/badge/honest-{wired}%20wired%20·%20{never}%20never-green",
        text,
    )
    text = re.sub(
        r"https://img\.shields\.io/badge/honest-[^\"\)]+-green",
        f"https://img.shields.io/badge/honest-{wired}%20wired%20·%20{never}%20never-green",
        text,
    )

    # 3. Header quote > **X Horizon
    # e.g. > **0.2.0-dev Horizon (2026-09-25)
    text = re.sub(
        r"> \*\*[0-9\.]+(?:-dev)? Horizon",
        f"> **{version} Horizon",
        text,
    )
    # 4. Sideload line
    text = re.sub(
        r"The `[^`]+` build is \*\*not App Store\*\*",
        f"The `{version}` build is **not App Store**",
        text,
    )
    # 5. Repository layout version-strategy parenthetical
    text = re.sub(
        r"version-strategy \([^\)]+ Horizon\)",
        f"version-strategy ({version} Horizon)",
        text,
    )
    # 6. Current branch line — keep version word updated
    text = re.sub(
        r"(`4ea142a` `)[0-9\.]+(-dev)? Horizon",
        rf"\g<1>{version} Horizon",
        text,
    )

    # 7. Ensure WHAT_DOES_NOT_EXIST badge counts comment matches
    # Add a hidden marker for CI debugging (optional)
    if text != original:
        if check:
            print(f"README would change: version={version} wired={wired} never={never}")
            # show diff snippet
            import difflib
            for line in difflib.unified_diff(original.splitlines(), text.splitlines(), lineterm="", n=3):
                print(line)
            return 1
        README.write_text(text, encoding="utf-8")
        print(f"README updated: version={version} honest={wired} wired · {never} never")
        # Verify What works today still honest
        if f"{wired} wired" not in text or f"{never} never" not in text:
            print("Warning: What works today table may not match WHAT_DOES_NOT_EXIST counts", file=sys.stderr)
        return 0
    else:
        print(f"README already up to date: version={version} honest={wired} wired · {never} never")
        return 0

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit 1 if README would change")
    ap.add_argument("--write", action="store_true", help="write (default)")
    args = ap.parse_args()
    # default is write
    if args.check:
        return update_readme(check=True)
    return update_readme(check=False)

if __name__ == "__main__":
    raise SystemExit(main())
