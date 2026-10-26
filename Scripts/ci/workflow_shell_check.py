#!/usr/bin/env python3
"""ZynSign CI — the shell that the workflows actually run.

A scheduled sweep failed after it had already done its work. One step built a
pull-request body with `BODY="... ``04-maintenance.yml`` ..."` — two
backslashes before each backtick. bash reads `\\` as one literal backslash and
then starts a command substitution on the backtick that is now *unescaped*, so
the step tried to run `04-maintenance.yml`, `docs/internal/`, `.swiftformat`
and `MARKETING_VERSION` as commands and died with exit 127.

`bash -n` accepts that script: the quoting is well formed and every
substitution is closed. The mistake is semantic — an escape that escapes the
wrong character — which is why it survived review and only surfaced on a
runner, an hour into a job.

So this check reads the workflow files and asserts two things about every
`run:` block:

  1. it passes `bash -n`, so a YAML edit that breaks quoting never reaches a
     runner;
  2. it contains no backtick preceded by two or more backslashes. One
     backslash (`\\``) escapes a backtick for bash; two leave it unescaped and
     turn prose into commands.

Lines inside a block that are shell comments are exempt from rule 2 — a
comment cannot run, so it may describe the trap.

Usage:
    python3 Scripts/ci/workflow_shell_check.py
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"

# A block scalar opener: `run: |`, `run: |-`, `run: |+`, `run: >`, …
BLOCK_OPENER = re.compile(r"^(?P<indent>\s*)run:\s*[|>][+-]?\s*$")
# Two or more backslashes immediately before a backtick.
ESCAPED_PAST_A_BACKTICK = re.compile(r"\\{2,}`")

failures: list[str] = []


def blocks(text: str) -> list[tuple[int, str]]:
    """Every block-scalar `run:` script, as (starting line, dedented script)."""
    lines = text.splitlines()
    found: list[tuple[int, str]] = []
    index = 0
    while index < len(lines):
        match = BLOCK_OPENER.match(lines[index])
        if not match:
            index += 1
            continue
        base = len(match.group("indent"))
        body: list[str] = []
        cursor = index + 1
        while cursor < len(lines):
            line = lines[cursor]
            if line.strip() and (len(line) - len(line.lstrip())) <= base:
                break
            body.append(line)
            cursor += 1
        indents = [len(line) - len(line.lstrip()) for line in body if line.strip()]
        cut = min(indents) if indents else 0
        script = "\n".join(
            line[cut:] if line.strip() else "" for line in body
        )
        found.append((index + 1, script))
        index = cursor
    return found


def syntax_errors(path: Path, start: int, script: str) -> list[str]:
    """`bash -n` over one block."""
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as handle:
        handle.write(script)
        temporary = Path(handle.name)
    try:
        result = subprocess.run(
            ["bash", "-n", str(temporary)],
            capture_output=True,
            text=True,
        )
    finally:
        temporary.unlink(missing_ok=True)
    if result.returncode == 0:
        return []
    detail = " ".join(result.stderr.split()) or "bash rejected the block"
    return [f"{path}:{start}: bash -n failed — {detail}"]


def backtick_traps(path: Path, start: int, script: str) -> list[str]:
    """Two backslashes before a backtick: prose that bash will execute."""
    findings: list[str] = []
    for offset, line in enumerate(script.splitlines()):
        if line.lstrip().startswith("#"):
            continue
        if ESCAPED_PAST_A_BACKTICK.search(line):
            findings.append(
                f"{path}:{start + offset + 1}: two backslashes before a backtick — "
                f"bash starts a command substitution here.\n"
                f"    {line.strip()}\n"
                "    Use one backslash (\\`) or a single-quoted string."
            )
    return findings


def main() -> int:
    if not WORKFLOWS.is_dir():
        print(f"workflow shell check: no {WORKFLOWS.relative_to(ROOT)} directory", file=sys.stderr)
        return 1

    workflows = sorted(WORKFLOWS.glob("*.yml")) + sorted(WORKFLOWS.glob("*.yaml"))
    scripts = 0
    for workflow in workflows:
        relative = workflow.relative_to(ROOT).as_posix()
        for start, script in blocks(workflow.read_text()):
            scripts += 1
            origin = Path(relative)
            failures.extend(syntax_errors(origin, start, script))
            failures.extend(backtick_traps(origin, start, script))

    if failures:
        print("✗ Workflow shell check failed:\n")
        for failure in failures:
            print(f"  {failure}")
        print(
            f"\n{len(failures)} finding(s) across {scripts} run block(s) "
            f"in {len(workflows)} workflow file(s)."
        )
        return 1

    print(
        f"✓ Workflow shell check: {scripts} run block(s) in "
        f"{len(workflows)} workflow file(s) parse and escape cleanly."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
