#!/usr/bin/env python3
"""Merge a generated tag changelog entry into the current default branch.

Only the release section and a missing versioned notes file are copied from the
release artifact. The current branch's `[Unreleased]` work is preserved, and
existing curated notes are never overwritten.
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path


def release_section(text: str, version: str) -> str | None:
    header = re.search(rf"(?m)^## \[{re.escape(version)}\][^\n]*\n", text)
    if not header:
        return None
    following = re.search(r"(?m)^## \[", text[header.end():])
    end = header.end() + following.start() if following else len(text)
    return text[header.start():end].strip()


def unreleased_end(text: str) -> int | None:
    header = re.search(r"(?m)^## \[Unreleased\][^\n]*\n", text)
    if not header:
        return None
    following = re.search(r"(?m)^## \[", text[header.end():])
    return header.end() + following.start() if following else len(text)


def apply_entry(current: str, generated_entry: str, version: str) -> tuple[str, bool]:
    if release_section(current, version):
        return current, False
    generated = release_section(generated_entry, version)
    if generated is None:
        raise ValueError(f"Generated changelog has no [{version}] section")

    insertion = unreleased_end(current)
    if insertion is None:
        heading = re.search(r"(?m)^# Changelog\s*\n", current)
        if not heading:
            raise ValueError("Current CHANGELOG.md has no `# Changelog` or `[Unreleased]` section")
        insertion = heading.end()

    before = current[:insertion].rstrip("\n")
    after = current[insertion:].lstrip("\n")
    updated = f"{before}\n\n{generated}\n\n{after}".rstrip() + "\n"
    return updated, True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--generated-changelog", required=True, type=Path)
    parser.add_argument("--generated-notes", required=True, type=Path)
    parser.add_argument("--changelog", default=Path("CHANGELOG.md"), type=Path)
    parser.add_argument("--notes-directory", default=Path("docs/releases"), type=Path)
    args = parser.parse_args()
    version = args.version.removeprefix("v")

    try:
        current = args.changelog.read_text(encoding="utf-8")
        generated = args.generated_changelog.read_text(encoding="utf-8")
        updated, changed = apply_entry(current, generated, version)
    except (OSError, ValueError) as error:
        print(f"Cannot apply release changelog: {error}", file=sys.stderr)
        return 1

    if changed:
        args.changelog.write_text(updated, encoding="utf-8")
        print(f"Added [{version}] to {args.changelog}")
    else:
        print(f"[{version}] is already present in {args.changelog}")

    destination_notes = args.notes_directory / f"notes-v{version}.md"
    if destination_notes.exists():
        print(f"Preserving existing curated notes at {destination_notes}")
    else:
        try:
            destination_notes.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args.generated_notes, destination_notes)
            print(f"Copied generated notes to {destination_notes}")
        except OSError as error:
            print(f"Cannot write release notes: {error}", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
