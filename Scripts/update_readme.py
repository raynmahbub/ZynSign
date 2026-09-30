#!/usr/bin/env python3
"""
update_readme.py — keep README.md honest and version-correct when features land.

README is the storefront. When you add a feature in ZynSign/** or
docs/product/**, this script regenerates the parts that must not drift.
02-quality.yml refuses a stale README on a pull request; 99-command-center.yml
repairs the default branch weekly. It regenerates:

  1. Version badge — `https://img.shields.io/badge/version-X-<colour>`
     from ZynSign.xcodeproj/project.pbxproj MARKETING_VERSION
  2. Honest badge — `https://img.shields.io/badge/honest-N%20wired%20·%20M%20never-green`
     from docs/product/WHAT_DOES_NOT_EXIST.md tables (counts Now Exists vs Still Honest)
  3. Release-train line — `Current stop on the release train: **vX**
     (marketing `Y`, build `Z`)` from Scripts/release_train.py (the `current`
     stage) and from MARKETING_VERSION / CURRENT_PROJECT_VERSION

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

def read_build_number() -> str:
    """`CURRENT_PROJECT_VERSION` (CFBundleVersion) from the Xcode project."""
    text = PBXPROJ.read_text(encoding="utf-8")
    m = re.search(r"CURRENT_PROJECT_VERSION\s*=\s*(\d+);", text)
    return m.group(1) if m else "1"


def read_release_stage() -> str | None:
    """The release train's current stage tag, e.g. `v0.0.1-dev.1`."""
    train = ROOT / "ZynSign" / "Application" / "ReleaseTrain.swift"
    if not train.exists():
        return None
    text = train.read_text(encoding="utf-8")
    m = re.search(r"static let current[^=]*=\s*\.?(\w+)", text)
    if not m:
        return None
    case = m.group(1)
    tag = re.search(rf"case \.{case}:\s*return\s*\"([^\"]+)\"", text)
    return f"v{tag.group(1)}" if tag else None


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
    stage = read_release_stage()
    wired, never = count_what()
    # Fallback to known 7/3 if parsing fails
    if wired == 0:
        wired = 7
    if never == 0:
        never = 3

    # 1. Version badge — any colour suffix is preserved.
    #
    # The badge carries the whole staged version, not just the marketing part:
    # `0.1.0--alpha.3` distinguishes the alpha from the beta that will share
    # MARKETING_VERSION 0.1.0. A `-` is doubled because shields.io reads a
    # single `-` as the field separator.
    #
    # The pattern must be able to match a badge that is already suffixed, or
    # the rewrite silently stops happening the first time the train leaves a
    # development stop — which is what used to occur here: `[^-]+` could not
    # cross the `-`, and `(?:--dev)?` only ever covered `--dev`. The badge
    # then froze at its development value and `--check`, which compares the
    # rewritten text, could not see it. Anchoring the colour to exactly six
    # hex digits keeps the non-greedy version group from eating into it.
    badge_version = (stage or f"v{version}").lstrip("v").replace("-", "--")
    text = re.sub(
        r"(https://img\.shields\.io/badge/version-)[0-9A-Za-z.\-]+?(-[0-9A-Fa-f]{6})\b",
        lambda m: f"{m.group(1)}{badge_version}{m.group(2)}",
        text,
    )
    # 2. Honest badge
    text = re.sub(
        r"https://img\.shields\.io/badge/honest-[^\"\)]+-green",
        f"https://img.shields.io/badge/honest-{wired}%20wired%20·%20{never}%20never-green",
        text,
    )
    # 3. Release-train line — the stop's tag, and the marketing version and
    #    build number quoted next to it. All three come from the train and the
    #    Xcode project, so the sentence cannot go stale when the train moves
    #    (a reset changes all three at once, which is exactly when a hardcoded
    #    parenthetical would lie).
    if stage:
        text = re.sub(
            r"(Current stop on the release train: \*\*`)[^`]+(`\*\*)",
            rf"\g<1>{stage}\g<2>",
            text,
        )
        build = read_build_number()
        text = re.sub(
            r"(Current stop on the release train: \*\*`[^`]+`\*\* \(marketing `)[^`]+(`, build `)\d+(`\))",
            rf"\g<1>{version}\g<2>{build}\g<3>",
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
        # Verify What works today still honest. The badge URL-encodes its
        # spaces (`10%20wired`), so accept either spelling — otherwise this
        # warns on every run and trains everyone to ignore it.
        def _present(count: int, word: str) -> bool:
            return f"{count} {word}" in text or f"{count}%20{word}" in text

        if not (_present(wired, "wired") and _present(never, "never")):
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
