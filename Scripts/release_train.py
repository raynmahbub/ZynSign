#!/usr/bin/env python3
"""
release_train.py — ship ZynSign one release at a time.

The whole app is built. Each release only switches on more of it. The single
source of truth is `ZynSign/Application/ReleaseTrain.swift`:

  * `ReleaseStage`        — the ordered releases (0.1.0 → alphas → betas → RCs → 1.0.0)
  * `introducedFeatures`  — what each release switches on
  * `ReleaseTrain.current` — the release this build is cut for

This script reads that file (it never duplicates the table) and keeps the
Xcode project in step with it.

Usage:
    python3 Scripts/release_train.py status
        Show the current release, what it exposes, and what ships next.

    python3 Scripts/release_train.py check [--tag vX.Y.Z]
        CI gate. Fails when MARKETING_VERSION disagrees with ReleaseTrain.current,
        or (with --tag) when the tag being released is not ReleaseTrain.current.

    python3 Scripts/release_train.py promote [STAGE] [--dry-run]
        Move to STAGE (default: the next stage). Edits ReleaseTrain.current,
        sets MARKETING_VERSION, and bumps CURRENT_PROJECT_VERSION by one.
        STAGE may be a name (alpha1) or a version (0.1.0-alpha.1 / v0.1.0-alpha.1).
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRAIN = ROOT / "ZynSign" / "Application" / "ReleaseTrain.swift"
PBXPROJ = ROOT / "ZynSign.xcodeproj" / "project.pbxproj"

CURRENT_RE = re.compile(r"(static let current: ReleaseStage = \.)(\w+)")


@dataclass
class Stage:
    name: str
    version: str
    introduced: list[str] = field(default_factory=list)

    @property
    def tag(self) -> str:
        return f"v{self.version}"

    @property
    def marketing(self) -> str:
        return self.version.split("-", 1)[0]


def _block(text: str, header: str) -> str:
    """Return the body of the `{ ... }` block that follows `header`."""
    start = text.index(header)
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i + 1 : j]
    raise ValueError(f"unterminated block after {header!r}")


def load_train() -> tuple[list[Stage], str, dict[str, str]]:
    text = TRAIN.read_text(encoding="utf-8")

    stage_enum = _block(text, "enum ReleaseStage")
    names: list[str] = []
    for line in stage_enum.splitlines():
        m = re.match(r"\s*case (\w+)\s*(//.*)?$", line)
        if m:
            names.append(m.group(1))
        if "var version" in line:
            break

    versions = dict(re.findall(r"case \.(\w+): return \"([^\"]+)\"", _block(text, "var version: String")))

    introduced: dict[str, list[str]] = {n: [] for n in names}
    for cases, body in re.findall(r"case ([^:]+): return \[([^\]]*)\]", _block(text, "var introducedFeatures")):
        feats = re.findall(r"\.(\w+)", body)
        for case in re.findall(r"\.(\w+)", cases):
            introduced[case] = feats

    display = dict(re.findall(r"case \.(\w+): return \"([^\"]+)\"", _block(text, "var displayName: String")))

    stages = []
    for n in names:
        if n not in versions:
            raise SystemExit(f"ReleaseTrain.swift: stage {n!r} has no version")
        stages.append(Stage(n, versions[n], introduced.get(n, [])))

    m = CURRENT_RE.search(text)
    if not m:
        raise SystemExit("ReleaseTrain.swift: `static let current: ReleaseStage = .x` not found")
    return stages, m.group(2), display


def find_stage(stages: list[Stage], ident: str) -> Stage:
    ident = ident.strip()
    version = ident[1:] if ident.startswith("v") else ident
    for s in stages:
        if s.name == ident or s.version == version:
            return s
    raise SystemExit(f"Unknown stage {ident!r}. Known: {', '.join(s.name for s in stages)}")


def project_versions() -> tuple[set[str], set[int]]:
    text = PBXPROJ.read_text(encoding="utf-8")
    marketing = set(v.strip().strip('"') for v in re.findall(r"MARKETING_VERSION = ([^;]+);", text))
    builds = set(int(v) for v in re.findall(r"CURRENT_PROJECT_VERSION = (\d+);", text))
    return marketing, builds


def features_through(stages: list[Stage], stage: Stage) -> list[str]:
    out: list[str] = []
    for s in stages:
        out.extend(s.introduced)
        if s.name == stage.name:
            break
    return out


# ---------------------------------------------------------------- commands


def cmd_status(_: argparse.Namespace) -> int:
    stages, current_name, display = load_train()
    current = find_stage(stages, current_name)
    marketing, builds = project_versions()
    print(f"Current release : {current.tag}  (stage .{current.name})")
    print(f"Xcode project   : MARKETING_VERSION {', '.join(sorted(marketing))} · build {', '.join(map(str, sorted(builds)))}")
    print()
    print("Train:")
    for s in stages:
        marker = "▶" if s.name == current.name else " "
        added = ", ".join(display.get(f, f) for f in s.introduced) or "—"
        print(f"  {marker} {s.tag:<16} {added}")
    on = features_through(stages, current)
    off = [f for s in stages for f in s.introduced if f not in on]
    print()
    print("Visible in this release :", ", ".join(display.get(f, f) for f in on) or "core only (Files, Import, Library, Bundle Explorer, Home, Settings)")
    print("Hidden until later      :", ", ".join(display.get(f, f) for f in off) or "nothing — feature complete")
    idx = [s.name for s in stages].index(current.name)
    if idx + 1 < len(stages):
        print(f"Next                    : {stages[idx + 1].tag}  →  python3 Scripts/release_train.py promote")
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    stages, current_name, _ = load_train()
    current = find_stage(stages, current_name)
    marketing, builds = project_versions()
    ok = True

    seen: set[str] = set()
    for s in stages:
        for f in s.introduced:
            if f in seen:
                print(f"✗ feature .{f} is introduced twice", file=sys.stderr)
                ok = False
            seen.add(f)

    if marketing != {current.marketing}:
        print(
            f"✗ MARKETING_VERSION {sorted(marketing)} ≠ ReleaseTrain.current {current.tag} (needs {current.marketing}).\n"
            f"  Fix: python3 Scripts/release_train.py promote {current.name}  (or edit ReleaseTrain.current)",
            file=sys.stderr,
        )
        ok = False
    if len(builds) != 1:
        print(f"✗ CURRENT_PROJECT_VERSION differs between configurations: {sorted(builds)}", file=sys.stderr)
        ok = False

    if args.tag:
        tag = args.tag if args.tag.startswith("v") else f"v{args.tag}"
        if tag != current.tag:
            print(
                f"✗ Releasing tag {tag} but ReleaseTrain.current is {current.tag}.\n"
                f"  Promote first (python3 Scripts/release_train.py promote {tag}), commit, then tag.",
                file=sys.stderr,
            )
            ok = False

    if ok:
        print(f"✓ Release train consistent: {current.tag} · MARKETING_VERSION {current.marketing} · build {next(iter(builds))}")
        return 0
    return 1


def cmd_promote(args: argparse.Namespace) -> int:
    stages, current_name, display = load_train()
    current = find_stage(stages, current_name)
    names = [s.name for s in stages]
    if args.stage:
        target = find_stage(stages, args.stage)
    else:
        idx = names.index(current.name)
        if idx + 1 >= len(stages):
            print("Already at the final stage (1.0.0). After 1.0.0, use normal SemVer.", file=sys.stderr)
            return 1
        target = stages[idx + 1]
    if names.index(target.name) < names.index(current.name):
        print(f"Refusing to move backwards from {current.tag} to {target.tag} — users would lose features.", file=sys.stderr)
        return 1

    _, builds = project_versions()
    new_build = max(builds) + 1

    train_text = CURRENT_RE.sub(lambda m: m.group(1) + target.name, TRAIN.read_text(encoding="utf-8"))
    proj_text = PBXPROJ.read_text(encoding="utf-8")
    proj_text = re.sub(r"MARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {target.marketing};", proj_text)
    proj_text = re.sub(r"CURRENT_PROJECT_VERSION = \d+;", f"CURRENT_PROJECT_VERSION = {new_build};", proj_text)

    newly_on = [f for f in features_through(stages, target) if f not in features_through(stages, current)]
    added = ", ".join(display.get(f, f) for f in newly_on) or "no new features (fixes only)"
    print(f"{current.tag} → {target.tag}")
    print(f"  switches on : {added}")
    print(f"  version     : MARKETING_VERSION {target.marketing}, build {new_build}")
    if args.dry_run:
        print("  (dry run — nothing written)")
        return 0

    TRAIN.write_text(train_text, encoding="utf-8")
    PBXPROJ.write_text(proj_text, encoding="utf-8")
    print()
    print("Next steps (docs/releases/release-train.md):")
    print(f"  1. Add a `## [{target.version}]` section to CHANGELOG.md and docs/releases/notes-v{target.version}.md")
    print("  2. Build privately and run the private matrix for the newly visible features")
    print(f"  3. git commit -am \"release: {target.tag}\" && push, merge to main")
    print(f"  4. git tag -a {target.tag} -m \"ZynSign {target.version}\" && git push origin {target.tag}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status").set_defaults(func=cmd_status)
    p_check = sub.add_parser("check")
    p_check.add_argument("--tag")
    p_check.set_defaults(func=cmd_check)
    p_promote = sub.add_parser("promote")
    p_promote.add_argument("stage", nargs="?")
    p_promote.add_argument("--dry-run", action="store_true")
    p_promote.set_defaults(func=cmd_promote)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
