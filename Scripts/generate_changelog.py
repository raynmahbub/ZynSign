#!/usr/bin/env python3
"""Generate a categorized Keep a Changelog entry from release history.

The release train remains the version authority. When a release tag is built,
this script promotes a non-empty `[Unreleased]` section verbatim; otherwise it
collects Conventional Commit subjects since the nearest previous release tag
on the current commit's first-parent history and groups them into user-facing
categories. Existing curated release notes are never overwritten.

Examples:
    python3 Scripts/generate_changelog.py --version 0.0.2-dev.1 --tag v0.0.2-dev.1
    python3 Scripts/generate_changelog.py --version 0.0.2-dev.1 --dry-run
"""
from __future__ import annotations

import argparse
import datetime
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHANGELOG = ROOT / "CHANGELOG.md"
RELEASES_DIR = ROOT / "docs" / "releases"

CONVENTIONAL_RE = re.compile(
    r"^(?P<type>[A-Za-z][A-Za-z0-9_-]*)"
    r"(?:\((?P<scope>[^()\r\n]+)\))?"
    r"(?P<breaking>!)?:\s*(?P<subject>.+)$"
)
BREAKING_RE = re.compile(r"(?im)^BREAKING(?: CHANGE|-CHANGE):\s*(.*)$")
PULL_REQUEST_RE = re.compile(r"\(#(?P<number>\d+)\)")

TYPE_SECTIONS = {
    "feat": "Added",
    "fix": "Fixed",
    "perf": "Performance",
    "security": "Security",
    "docs": "Documentation",
    "refactor": "Changed",
    "style": "Changed",
    "build": "Maintenance",
    "ci": "Maintenance",
    "test": "Tests",
    "chore": "Maintenance",
    "revert": "Reverted",
}
CATEGORY_ORDER = [
    "Breaking Changes",
    "Added",
    "Changed",
    "Fixed",
    "Performance",
    "Security",
    "Documentation",
    "Reverted",
    "Tests",
    "Maintenance",
]


@dataclass(frozen=True)
class Commit:
    subject: str
    body: str = ""


def run(command: list[str]) -> str:
    # Preserve git's control-character separators (`%x1e` / `%x1f`) used by
    # `collect_commits`; `str.strip()` treats those separators as whitespace.
    return subprocess.check_output(command, cwd=ROOT, text=True, stderr=subprocess.DEVNULL).rstrip("\n")


def tag_exists(tag: str) -> bool:
    try:
        run(["git", "rev-parse", "--verify", f"refs/tags/{tag}"])
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def get_previous_tag(current_tag: str, until: str = "HEAD") -> str | None:
    """Return the nearest prior release tag on first-parent history.

    Version sorting is intentionally avoided: branches can be rewound or
    release trains can be reprioritized, while ancestry gives the actual
    predecessor of the artifact being built.
    """
    target = f"{current_tag}^" if tag_exists(current_tag) else until
    try:
        return run([
            "git", "describe", "--tags", "--abbrev=0", "--first-parent",
            "--match", "v[0-9]*", target,
        ])
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def parse_git_log(output: str) -> list[Commit]:
    commits: list[Commit] = []
    for record in output.split("\x1e"):
        record = record.strip("\n")
        if not record.strip():
            continue
        fields = record.split("\x1f", 2)
        if len(fields) != 3:
            continue
        _, subject, body = fields
        subject = subject.strip()
        if subject:
            commits.append(Commit(subject=subject, body=body.strip()))
    return commits


def collect_commits(since: str | None, until: str = "HEAD") -> list[Commit]:
    revision = f"{since}..{until}" if since else until
    try:
        output = run([
            "git", "log", "--no-merges", "--no-color",
            "--format=%H%x1f%s%x1f%b%x1e", revision,
        ])
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    return [commit for commit in parse_git_log(output) if not is_automation_commit(commit.subject)]


def is_automation_commit(subject: str) -> bool:
    lowered = subject.strip().lower()
    return (
        lowered.startswith("auto: changelog")
        or lowered.startswith("docs(changelog):")
        or lowered.startswith("chore(release):")
        or lowered.startswith("release:")
    )


def _markdown_links(subject: str) -> str:
    return PULL_REQUEST_RE.sub(
        lambda match: f"([#{match.group('number')}](https://github.com/raynmahbub/ZynSign/pull/{match.group('number')}))",
        subject,
    )


def group_commits(commits: list[Commit | str]) -> dict[str, list[str]]:
    """Normalize commit titles into release-note sections and concise bullets."""
    groups: dict[str, list[str]] = {}
    seen: set[tuple[str, str]] = set()

    for raw in commits:
        commit = raw if isinstance(raw, Commit) else Commit(subject=raw)
        match = CONVENTIONAL_RE.match(commit.subject)
        if match:
            kind = match.group("type").lower()
            if kind == "release":
                continue
            scope = (match.group("scope") or "").strip()
            subject = match.group("subject").strip()
            breaking = bool(match.group("breaking")) or bool(BREAKING_RE.search(commit.body))
            breaking_detail = BREAKING_RE.search(commit.body)
            if breaking:
                category = "Breaking Changes"
                detail = breaking_detail.group(1).strip() if breaking_detail else ""
                subject = detail or subject
            else:
                category = TYPE_SECTIONS.get(kind, "Changed")
            prefix = f"**{scope}:** " if scope else ""
            entry = f"- {prefix}{_markdown_links(subject)}"
            dedupe_key = (category, entry.lower())
        else:
            category = "Changed"
            entry = f"- {_markdown_links(commit.subject.strip())}"
            dedupe_key = (category, entry.lower())

        if dedupe_key in seen:
            continue
        seen.add(dedupe_key)
        groups.setdefault(category, []).append(entry)

    return groups


def unreleased_span(text: str) -> tuple[int, int] | None:
    """Return the body span of `[Unreleased]`, or `None` if absent."""
    header = re.search(r"(?m)^## \[Unreleased\][^\n]*\n", text)
    if not header:
        return None
    following = re.search(r"(?m)^## \[", text[header.end():])
    end = header.end() + following.start() if following else len(text)
    return header.end(), end


def release_section(text: str, version: str) -> str | None:
    header = re.search(rf"(?m)^## \[{re.escape(version)}\][^\n]*\n", text)
    if not header:
        return None
    following = re.search(r"(?m)^## \[", text[header.end():])
    end = header.end() + following.start() if following else len(text)
    return text[header.start():end].strip()


def build_curated_entry(version: str, date: str, body: str) -> str:
    return f"## [{version}] - {date}\n\n{body.strip()}\n"


def build_entry(version: str, date: str, groups: dict[str, list[str]], range_label: str = "release history") -> str:
    lines = [f"## [{version}] - {date} — Auto-generated", ""]
    if not groups:
        lines.extend([
            "No user-facing Conventional Commit changes were found in this range.",
            "",
        ])
    else:
        for category in CATEGORY_ORDER:
            entries = groups.get(category)
            if not entries:
                continue
            lines.extend([f"### {category}", "", *entries, ""])
    lines.extend([
        f"<!-- Generated from {range_label} by Scripts/generate_changelog.py. This entry is not device-verification evidence. -->",
        "",
    ])
    return "\n".join(lines)


def insert_after_unreleased(text: str, entry: str) -> str:
    """Replace the Unreleased body with an empty section and insert `entry`."""
    span = unreleased_span(text)
    if span:
        header_end, body_end = span
        prefix = text[:header_end].rstrip("\n")
        suffix = text[body_end:].lstrip("\n")
        return f"{prefix}\n\n{entry.rstrip()}\n\n{suffix}".rstrip() + "\n"

    heading = re.search(r"(?m)^# Changelog\s*\n", text)
    if not heading:
        raise ValueError("CHANGELOG.md has no `# Changelog` heading or `## [Unreleased]` section")
    prefix = text[:heading.end()].rstrip("\n")
    suffix = text[heading.end():].lstrip("\n")
    return f"{prefix}\n\n{entry.rstrip()}\n\n{suffix}".rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True, help="Release-train version without a leading v")
    parser.add_argument("--date", default=datetime.date.today().isoformat())
    parser.add_argument("--tag", default=None, help="Full tag, e.g. v0.1.0-alpha.1")
    parser.add_argument("--until", default="HEAD", help="Revision to collect through when the tag does not exist")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    version = args.version.removeprefix("v")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", version):
        print(f"Invalid SemVer release version: {args.version}", file=sys.stderr)
        return 2
    tag = args.tag or f"v{version}"
    date = args.date

    if not CHANGELOG.exists():
        print(f"CHANGELOG not found at {CHANGELOG}", file=sys.stderr)
        return 1
    text = CHANGELOG.read_text(encoding="utf-8")
    notes_path = RELEASES_DIR / f"notes-v{version}.md"

    existing = release_section(text, version)
    if existing:
        print(f"CHANGELOG already has [{version}], nothing to do.")
        if not notes_path.exists() and not args.dry_run:
            RELEASES_DIR.mkdir(parents=True, exist_ok=True)
            notes_path.write_text(existing + "\n", encoding="utf-8")
            print(f"Wrote missing notes {notes_path}")
        return 0

    span = unreleased_span(text)
    curated = text[span[0]:span[1]].strip() if span else ""
    if curated:
        print(f"Promoting the curated [Unreleased] section ({len(curated.splitlines())} lines).")
        entry = build_curated_entry(version, date, curated)
    else:
        tagged = tag_exists(tag)
        until = tag if tagged else args.until
        previous = get_previous_tag(tag, until=until)
        commits = collect_commits(previous, until=until)
        range_label = f"{previous or 'repository start'}..{until}"
        groups = group_commits(commits)
        entry = build_entry(version, date, groups, range_label=range_label)
        print(f"Collected {len(commits)} non-automation commits from {range_label}.")
        for category in CATEGORY_ORDER:
            if category in groups:
                print(f"  {category}: {len(groups[category])}")

    try:
        new_text = insert_after_unreleased(text, entry)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1

    if args.dry_run:
        print("--- DRY RUN: generated release entry ---")
        print(entry)
        return 0

    CHANGELOG.write_text(new_text, encoding="utf-8")
    print(f"Inserted [{version}] into CHANGELOG.md")

    RELEASES_DIR.mkdir(parents=True, exist_ok=True)
    if notes_path.exists():
        print(f"Keeping curated release notes at {notes_path}")
    else:
        notes_path.write_text(entry, encoding="utf-8")
        print(f"Wrote {notes_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
