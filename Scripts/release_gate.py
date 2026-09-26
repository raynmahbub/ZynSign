#!/usr/bin/env python3
"""
release_gate.py — the CI release gate for ZynSign.

The release is blocked automatically when any required gate fails. There is
no bypass: the script has no "skip" flag, and both .github/workflows/ci.yml
(the `release-gate` job) and .github/workflows/release.yml (before any
publish step) run it to failure.

Required gates:

  G1  Documentation set complete
      README.md, CHANGELOG.md, LICENSE, PRIVACY.md, SECURITY.md,
      CONTRIBUTING.md at the root; Quick Start, FAQ, Troubleshooting under
      docs/user/; release-lock, metadata, notes, build-verification and
      QA sign-off files for the candidate under docs/releases/.
  G2  Version metadata consistent
      `Scripts/release_train.py check` — ReleaseTrain.current, the Xcode
      project's MARKETING_VERSION and CURRENT_PROJECT_VERSION must agree.
  G3  Static hygiene
      No private-key/certificate material outside test fixtures; no
      generated artifacts or machine state (same rules as the CI hygiene
      job, run independently here as defense in depth).
  G4  Required validations complete
      docs/testing/final-validation-rc3.md — the workflow matrix must
      report every core workflow passing (12 of 12).
  G5  Release checklist complete
      docs/releases/qa-signoff-<candidate>.md — every sign-off box checked.
  G6  Release assets (with --version X)
      CHANGELOG has a `## [X` entry and docs/releases/notes-vX.md exists;
      if a QA sign-off for X exists it must be complete; the release
      metadata file must carry its required sections.

Usage:
    python3 Scripts/release_gate.py                        # candidate gates
    python3 Scripts/release_gate.py --candidate 1.0.0-rc.1
    python3 Scripts/release_gate.py --version 1.0.0-rc.1   # + publish gates

Exit status: 0 when every gate passes, 1 otherwise.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

EXPECTED_WORKFLOWS = 12
EXPECTED_SIGNOFF_ITEMS = 11
METADATA_SECTIONS = [
    "## Version",
    "## Changelog",
    "## Known Limitations",
    "## Upgrade Notes",
    "## Compatibility Notes",
]

ROOT_DOCS = [
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    "PRIVACY.md",
    "SECURITY.md",
    "CONTRIBUTING.md",
]
USER_GUIDES = [
    "docs/user/quick-start.md",
    "docs/user/faq.md",
    "docs/user/troubleshooting.md",
]

PRIVATE_KEY_RE = re.compile(
    r"BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY", re.IGNORECASE
)
CERTIFICATE_RE = re.compile(r"BEGIN CERT[I]FICATE", re.IGNORECASE)
FORBIDDEN_NAMES = ["DerivedData", "xcuserdata", "*.xcresult", "*.xcuserstate", ".DS_Store"]

results: list[tuple[bool, str]] = []


def record(ok: bool, gate: str, detail: str) -> None:
    results.append((ok, f"{gate}: {detail}"))


def gate_documentation(candidate: str) -> None:
    missing = [p for p in ROOT_DOCS + USER_GUIDES if not (ROOT / p).exists()]
    required_release = [
        f"docs/releases/release-lock-rc3.md",
        f"docs/releases/release-metadata-{candidate}.md",
        f"docs/releases/notes-v{candidate}.md",
        f"docs/releases/build-verification-{candidate}.md",
        f"docs/releases/qa-signoff-{candidate}.md",
        f"docs/releases/stable-release-sequence.md",
    ]
    missing += [p for p in required_release if not (ROOT / p).exists()]
    record(
        not missing,
        "G1 documentation set",
        "complete" if not missing else f"missing: {', '.join(missing)}",
    )


def gate_version_metadata() -> None:
    proc = subprocess.run(
        [sys.executable, str(ROOT / "Scripts" / "release_train.py"), "check"],
        capture_output=True,
        text=True,
    )
    detail = (proc.stdout + proc.stderr).strip().splitlines()
    record(
        proc.returncode == 0,
        "G2 version metadata",
        detail[-1] if detail else f"release_train check exited {proc.returncode}",
    )


def iter_source_files():
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        parts = set(path.relative_to(ROOT).parts)
        if ".git" in parts:
            continue
        yield path


def gate_static_hygiene() -> None:
    problems: list[str] = []
    for path in iter_source_files():
        rel = path.relative_to(ROOT)
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if PRIVATE_KEY_RE.search(text):
            problems.append(f"private key material in {rel}")
        if "Tests" not in rel.parts and CERTIFICATE_RE.search(text):
            problems.append(f"certificate material outside Tests in {rel}")
    for pattern in FORBIDDEN_NAMES:
        hits = [
            h
            for h in ROOT.rglob(pattern)
            if ".git" not in h.relative_to(ROOT).parts
        ]
        if hits:
            kind = "artifact" if pattern.startswith("*") else "path"
            problems.append(f"forbidden {kind} present: {pattern}")
    record(
        not problems,
        "G3 static hygiene",
        "clean" if not problems else "; ".join(problems[:5]),
    )


def gate_validations() -> None:
    path = ROOT / "docs" / "testing" / "final-validation-rc3.md"
    if not path.exists():
        record(False, "G4 required validations", "final-validation-rc3.md missing")
        return
    text = path.read_text(encoding="utf-8")
    match = re.search(
        r"<!-- release-gate: workflows -->(.*?)<!-- /release-gate: workflows -->",
        text,
        re.S,
    )
    if not match:
        record(False, "G4 required validations", "workflow matrix markers missing")
        return
    passing = len(re.findall(r"\|\s*✅\s*\|", match.group(1)))
    record(
        passing == EXPECTED_WORKFLOWS,
        "G4 required validations",
        f"{passing} of {EXPECTED_WORKFLOWS} workflows passing",
    )


def count_checkboxes(text: str) -> tuple[int, int]:
    done = len(re.findall(r"^- \[[xX]\]", text, re.M))
    todo = len(re.findall(r"^- \[ \]", text, re.M))
    return done, todo


def gate_checklist(candidate: str) -> None:
    path = ROOT / "docs" / "releases" / f"qa-signoff-{candidate}.md"
    if not path.exists():
        record(False, "G5 release checklist", f"qa-signoff-{candidate}.md missing")
        return
    done, todo = count_checkboxes(path.read_text(encoding="utf-8"))
    record(
        todo == 0 and done >= EXPECTED_SIGNOFF_ITEMS,
        "G5 release checklist",
        f"{done} checked, {todo} outstanding (need ≥ {EXPECTED_SIGNOFF_ITEMS} checked, 0 outstanding)",
    )


def gate_release_assets(version: str, candidate: str) -> None:
    problems: list[str] = []
    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    if f"## [{version}" not in changelog:
        problems.append(f"CHANGELOG.md has no '## [{version}' entry")
    if not (ROOT / "docs" / "releases" / f"notes-v{version}.md").exists():
        problems.append(f"notes-v{version}.md missing")

    metadata = ROOT / "docs" / "releases" / f"release-metadata-{version}.md"
    if metadata.exists():
        text = metadata.read_text(encoding="utf-8")
        for section in METADATA_SECTIONS:
            if section not in text:
                problems.append(f"release-metadata-{version}.md missing '{section}'")
    elif version == candidate:
        problems.append(f"release-metadata-{version}.md missing")

    signoff = ROOT / "docs" / "releases" / f"qa-signoff-{version}.md"
    if signoff.exists():
        done, todo = count_checkboxes(signoff.read_text(encoding="utf-8"))
        if todo:
            problems.append(f"qa-signoff-{version}.md has {todo} unchecked boxes")

    record(
        not problems,
        "G6 release assets",
        f"{version} ready" if not problems else "; ".join(problems),
    )


def gate_metadata_sections(candidate: str) -> None:
    path = ROOT / "docs" / "releases" / f"release-metadata-{candidate}.md"
    if not path.exists():
        record(False, "G6 release metadata", f"release-metadata-{candidate}.md missing")
        return
    text = path.read_text(encoding="utf-8")
    missing = [s for s in METADATA_SECTIONS if s not in text]
    record(
        not missing,
        "G6 release metadata",
        "all required sections present"
        if not missing
        else f"missing sections: {', '.join(missing)}",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="ZynSign CI release gate (no bypass)")
    parser.add_argument("--candidate", default="1.0.0-rc.1")
    parser.add_argument("--version", default=None)
    args = parser.parse_args()

    gate_documentation(args.candidate)
    gate_version_metadata()
    gate_static_hygiene()
    gate_validations()
    gate_checklist(args.candidate)
    gate_metadata_sections(args.candidate)
    if args.version:
        gate_release_assets(args.version, args.candidate)

    print()
    for ok, line in results:
        print(("✓ " if ok else "✗ ") + line)
    failed = [line for ok, line in results if not ok]
    print()
    if failed:
        print(f"RELEASE GATE: FAIL ({len(failed)} gate(s) not satisfied)")
        return 1
    print("RELEASE GATE: PASS — all required gates satisfied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
