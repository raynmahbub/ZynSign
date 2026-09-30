#!/usr/bin/env python3
"""
generate_changelog.py — auto-create CHANGELOG.md entry on public dev release.

When you push a release tag the
.github/workflows/03-release.yml workflow calls:

    python3 Scripts/generate_changelog.py --version 0.0.1 --date 2026-09-29

If CHANGELOG.md already has that version's section the script is a no-op (idempotent).
Otherwise it inserts a new section after ## [Unreleased]. The body comes from
the curated `## [Unreleased]` section when a human wrote one — Keep a Changelog
semantics move that text into the release it describes — and only falls back to
git log since the previous tag, grouped by conventional-commit prefix, when
`[Unreleased]` is empty.

An existing `docs/releases/notes-v<version>.md` is never overwritten: the
release workflow publishes that file as the GitHub Release body, so a curated
note outranks anything this script could generate.

Grouped sections:
  feat:     → Added
  fix:      → Fixed
  docs:     → Documentation
  chore:    → Changed
  refactor: → Changed
  perf:     → Changed
  test:     → Tests
  security: → Security
  other:    → Changed

Also writes docs/releases/notes-v{version}.md for `gh release --notes-file`.

Usage locally:
    python3 Scripts/generate_changelog.py --version 0.0.1
    python3 Scripts/generate_changelog.py --version 0.0.1 --dry-run
"""
from __future__ import annotations
import argparse
import datetime
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHANGELOG = ROOT / "CHANGELOG.md"
RELEASES_DIR = ROOT / "docs" / "releases"

PREFIX_MAP = {
    "feat": "Added",
    "fix": "Fixed",
    "docs": "Documentation",
    "chore": "Changed",
    "refactor": "Changed",
    "perf": "Changed",
    "test": "Tests",
    "security": "Security",
    "build": "Changed",
    "ci": "Changed",
}

def run(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, cwd=ROOT, text=True).strip()

def get_previous_tag(current_tag: str) -> str | None:
    try:
        tags = run(["git", "tag", "--sort=-v:refname"]).splitlines()
    except Exception:
        return None
    # find tag before current_tag in sorted order (semver descending)
    # If current_tag not yet in list (dry local), just return latest
    if current_tag in tags:
        idx = tags.index(current_tag)
        if idx + 1 < len(tags):
            return tags[idx + 1]
        return None
    # Not tagged yet — previous is latest tag
    return tags[0] if tags else None

def collect_commits(since: str | None, until: str = "HEAD") -> list[str]:
    rev = f"{since}..{until}" if since else until
    try:
        log = run(["git", "log", rev, "--pretty=format:%s", "--no-merges"])
    except subprocess.CalledProcessError:
        return []
    # filter out empty and automated commits
    lines = [l.strip() for l in log.splitlines() if l.strip()]
    # ignore the generate_changelog commits themselves to avoid loop
    lines = [l for l in lines if "auto: changelog" not in l.lower()]
    return lines

def group_commits(messages: list[str]) -> dict[str, list[str]]:
    groups: dict[str, list[str]] = {}
    for msg in messages:
        m = re.match(r"^(\w+)(?:\(.+\))?:\s*(.+)", msg)
        if m:
            prefix, subject = m.groups()
            section = PREFIX_MAP.get(prefix.lower(), "Changed")
            # Keep original conventional prefix for traceability
            entry = f"- **{prefix}:** {subject} (`{msg}`)"
            # Shorten if subject already contains details
            if len(subject) < 120:
                entry = f"- {subject} (`{msg.split(':')[0].strip()}`)"
            # Use subject only for readability, keep full msg in detail
            # Prefer subject
            entry = f"- {subject}"
        else:
            section = "Changed"
            entry = f"- {msg}"
        groups.setdefault(section, []).append(entry)
    return groups

def unreleased_span(text: str) -> tuple[int, int] | None:
    """Byte span of the `## [Unreleased]` body, or None when there is no such section.

    The end of the span is the start of the next `## [` section (or EOF), so the
    body can be read and rewritten without regex-replacement surprises: release
    notes legitimately contain backslashes and `\\1`-looking text.
    """
    header = re.search(r"(?m)^## \[Unreleased\][^\n]*\n", text)
    if not header:
        return None
    following = re.search(r"(?m)^## \[", text[header.end():])
    end = header.end() + following.start() if following else len(text)
    return header.end(), end


def build_curated_entry(version: str, date: str, body: str) -> str:
    """Promote a hand-written `[Unreleased]` body into this release's section."""
    return f"## [{version}] - {date}\n\n{body.strip()}\n"


def build_entry(version: str, date: str, groups: dict[str, list[str]]) -> str:
    lines = []
    lines.append(f"## [{version}] - {date} — auto-generated")
    lines.append("")
    if not groups:
        lines.append("No conventional commits since previous tag. See `git log` for details.")
        lines.append("")
        return "\n".join(lines)
    order = ["Added", "Changed", "Fixed", "Documentation", "Security", "Tests"]
    for section in order:
        if section in groups:
            lines.append(f"### {section}")
            lines.append("")
            # dedupe, keep order
            seen = set()
            for entry in groups[section]:
                if entry not in seen:
                    lines.append(entry)
                    seen.add(entry)
            lines.append("")
    # any remaining
    for sec, entries in groups.items():
        if sec not in order:
            lines.append(f"### {sec}")
            lines.append("")
            for e in entries:
                lines.append(e)
            lines.append("")
    lines.append(f"> Market `MARKETING_VERSION {version}` build from `ZynSign.xcodeproj/project.pbxproj` (`CFBundleShortVersionString {version}`), sideload/TestFlight only. Private test gate in `docs/releases/private-testing.md` preceded this tag.")
    lines.append("")
    return "\n".join(lines)

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help="e.g. 0.0.1 or 0.0.1-dev.1 (without leading v)")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--tag", default=None, help="full tag e.g. v0.1.0 (default v{version})")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    version = args.version.lstrip("v")
    tag = args.tag or f"v{version}"
    date = args.date

    if not CHANGELOG.exists():
        print(f"CHANGELOG not found at {CHANGELOG}", file=sys.stderr)
        return 1

    text = CHANGELOG.read_text(encoding="utf-8")

    # Idempotence: if entry already exists, do nothing
    if re.search(rf"^## \[{re.escape(version)}\]", text, re.M):
        print(f"CHANGELOG already has [{version}], nothing to do.")
        # still ensure notes file exists
        notes_path = RELEASES_DIR / f"notes-v{version}.md"
        if not notes_path.exists():
            # extract existing entry
            m = re.search(rf"^## \[{re.escape(version)}\].*?(?=\n## \[)", text, re.S | re.M)
            if m:
                notes_path.write_text(m.group(0).strip() + "\n", encoding="utf-8")
                print(f"Wrote missing notes {notes_path}")
        return 0

    # A hand-written [Unreleased] entry is the release's own note; the commit log
    # is only the fallback for a release that skipped the changelog.
    span = unreleased_span(text)
    curated = text[span[0]:span[1]].strip() if span else ""

    if curated:
        lines = len(curated.splitlines())
        print(f"[Unreleased] carries a curated entry ({lines} lines) — promoting it verbatim.")
        entry = build_curated_entry(version, date, curated)
        # The body now belongs to this release, so [Unreleased] starts empty again.
        new_text = text[:span[0]] + "\n" + entry + "\n" + text[span[1]:]
    else:
        prev_tag = get_previous_tag(tag)
        print(f"Previous tag: {prev_tag!r} → {tag}")
        commits = collect_commits(prev_tag)
        print(f"Collected {len(commits)} commits since {prev_tag}")
        for c in commits[:10]:
            print(f"  - {c}")
        if len(commits) > 10:
            print(f"  ... and {len(commits)-10} more")

        groups = group_commits(commits)
        entry = build_entry(version, date, groups)

        if span:
            # Insert after the [Unreleased] section, leaving any preamble intact.
            new_text = text[:span[1]] + entry + "\n" + text[span[1]:]
        else:
            # fallback: after first # Changelog header
            new_text = text.replace("# Changelog", f"# Changelog\n\n{entry}", 1)

    if args.dry_run:
        print("--- DRY RUN: would insert ---")
        print(entry[:2000])
        return 0

    CHANGELOG.write_text(new_text, encoding="utf-8")
    print(f"Inserted [{version}] into CHANGELOG.md")

    # Notes for `gh release --notes-file`. An existing file was written by a
    # human for this stop and outranks anything generated here — the release
    # publishes the file by path, so overwriting it would ship over the notes.
    RELEASES_DIR.mkdir(parents=True, exist_ok=True)
    notes_path = RELEASES_DIR / f"notes-v{version}.md"
    if notes_path.exists():
        print(f"Keeping the existing notes at {notes_path}")
    else:
        notes_path.write_text(entry, encoding="utf-8")
        print(f"Wrote {notes_path}")

    # Also ensure README version badge will be fixed by update_readme.py, but we do minimal here
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
