#!/usr/bin/env python3
"""
release_train.py — ship ZynSign one release at a time.

The whole app is built. Each release only switches on more of it. The single
source of truth is `ZynSign/Application/ReleaseTrain.swift`:

  * `ReleaseStage`        — the ordered releases (0.0.1-dev.N → 0.0.1 → alphas
                             → betas → RCs → 1.0.0 → 2.0.0 → 3.0.0)
  * `introducedFeatures`  — what each release switches on
  * `ReleaseTrain.current` — the release this build is cut for

This script reads that file (it never duplicates the table) and keeps the
Xcode project in step with it.

Usage:
    python3 Scripts/release_train.py status
        Show the current release, what it exposes, and what ships next.

    python3 Scripts/release_train.py current [--tag | --stage]
        Print the current release for machines: the version (0.0.1-dev.1),
        the tag (v0.0.1-dev.1), or the ReleaseStage case name (dev1). Scripts
        and workflows call this instead of hardcoding a version.

    python3 Scripts/release_train.py check [--tag vX.Y.Z]
        CI gate. Fails when MARKETING_VERSION disagrees with ReleaseTrain.current,
        or (with --tag) when the tag being released is not ReleaseTrain.current.

    python3 Scripts/release_train.py promote [STAGE] [--dry-run]
        Move to STAGE (default: the next stage). Edits ReleaseTrain.current,
        sets MARKETING_VERSION, and bumps CURRENT_PROJECT_VERSION by one.
        STAGE may be a name (alpha1) or a version (0.1.0-alpha.1 / v0.1.0-alpha.1).

    python3 Scripts/release_train.py rewind STAGE [--dry-run]
        Move *back* to an earlier stop. This exists for exactly one
        situation: the declared stop ran ahead of what has actually shipped,
        so no tag can be cut for the stop that is really next. `promote`
        refuses to move backwards because a released stop must never be
        re-released and no user may lose a feature — this command keeps that
        guarantee by refusing any target at or behind the highest stop that
        already carries a tag. Rewinding is therefore never destructive: it
        can only move the pointer within the range that has not shipped.
"""

from __future__ import annotations

import argparse
import re
import subprocess
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
    print("Visible in this release :", ", ".join(display.get(f, f) for f in on) or "core only — the six-tab shell (Files · Library · Home · App Store · Downloads · Settings) with every staged workflow behind it")
    print("Hidden until later      :", ", ".join(display.get(f, f) for f in off) or "nothing — feature complete")
    idx = [s.name for s in stages].index(current.name)
    if idx + 1 < len(stages):
        print(f"Next                    : {stages[idx + 1].tag}  →  python3 Scripts/release_train.py promote")
    return 0


def cmd_current(args: argparse.Namespace) -> int:
    """Print the current release in a machine-readable form (one line)."""
    stages, current_name, _ = load_train()
    current = find_stage(stages, current_name)
    if args.stage:
        print(current.name)
    elif args.tag:
        print(current.tag)
    else:
        print(current.version)
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
            names = [s.name for s in stages]
            requested = next((s for s in stages if s.tag == tag), None)
            if requested is None:
                print(
                    f"✗ {tag} is not a stop on the release train, so nothing can be released for it.\n"
                    f"  ReleaseTrain.current is {current.tag}; the train's stops are:\n"
                    f"    {', '.join(s.tag for s in stages)}\n"
                    f"  See docs/releases/release-train.md for the plan and the stop order.",
                    file=sys.stderr,
                )
            elif names.index(requested.name) < names.index(current.name):
                print(
                    f"✗ {tag} is a past stop: the train has already moved on to {current.tag}.\n"
                    f"  Past stops are never re-released — `promote` refuses to move backwards\n"
                    f"  because users would lose features. Release the current stop ({current.tag}),\n"
                    f"  or promote to a later one first.",
                    file=sys.stderr,
                )
            else:
                print(
                    f"✗ Releasing tag {tag} but ReleaseTrain.current is {current.tag}.\n"
                    f"  Promote first (python3 Scripts/release_train.py promote {requested.name}), commit, then tag.",
                    file=sys.stderr,
                )
            ok = False

    if ok:
        print(f"✓ Release train consistent: {current.tag} · MARKETING_VERSION {current.marketing} · build {next(iter(builds))}")
        return 0
    return 1


def released_stage_indices(stages: list[Stage]) -> list[int] | None:
    """Indices of the stages that already carry a tag, or None if unknown.

    Read from git rather than trusted to a human, because the whole point of
    the rewind guard is that a released stop must not become the next release
    again. Returning None (git missing, not a repository) is treated as
    "cannot prove it is safe" by the caller.
    """
    try:
        out = subprocess.run(
            ["git", "tag", "--list", "v*"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    tags = {line.strip() for line in out.splitlines() if line.strip()}
    return [i for i, s in enumerate(stages) if s.tag in tags]


def cmd_rewind(args: argparse.Namespace) -> int:
    stages, current_name, display = load_train()
    current = find_stage(stages, current_name)
    target = find_stage(stages, args.stage)
    names = [s.name for s in stages]
    current_i, target_i = names.index(current.name), names.index(target.name)

    if target_i >= current_i:
        print(
            f"\u2717 {target.tag} is not behind {current.tag}.\n"
            f"  Use `promote` to move forward; `rewind` only moves back.",
            file=sys.stderr,
        )
        return 1

    released = released_stage_indices(stages)
    if released is None and not args.allow_behind_tags:
        print(
            "\u2717 Cannot tell which stops have already been released — `git tag` did not run.\n"
            "  Rewinding without that check could aim the train at a stop that already shipped.\n"
            "  Run this inside the repository, or pass --allow-behind-tags if you are certain.",
            file=sys.stderr,
        )
        return 1
    if released:
        highest = max(released)
        if target_i <= highest and not args.allow_behind_tags:
            remaining = ", ".join(s.tag for s in stages[highest + 1 : current_i]) or "none"
            print(
                f"\u2717 {target.tag} has already been released — {stages[highest].tag} is tagged.\n"
                f"  A stop that shipped can never be the next release again; the tag exists.\n"
                f"  The train can only be rewound to a stop after {stages[highest].tag}.\n"
                f"  Still reachable by rewind: {remaining}",
                file=sys.stderr,
            )
            return 1

    _, builds = project_versions()
    new_build = max(builds) + 1
    exposed = ", ".join(display.get(f, f) for f in features_through(stages, target)) or "core only"

    print(f"Rewinding {current.tag} \u2192 {target.tag}")
    print(f"  exposes     : {exposed}")
    print(f"  version     : MARKETING_VERSION {target.marketing}, build {new_build}")
    if released:
        print(f"  safe        : nothing at or behind {stages[max(released)].tag} is touched, so no shipped release changes")
    else:
        print("  safe        : no stop has been tagged yet, so nothing shipped changes")
    if args.dry_run:
        print("  (dry run \u2014 nothing written)")
        return 0

    TRAIN.write_text(
        CURRENT_RE.sub(lambda m: m.group(1) + target.name, TRAIN.read_text(encoding="utf-8")),
        encoding="utf-8",
    )
    proj_text = PBXPROJ.read_text(encoding="utf-8")
    proj_text = re.sub(r"MARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {target.marketing};", proj_text)
    proj_text = re.sub(r"CURRENT_PROJECT_VERSION = \d+;", f"CURRENT_PROJECT_VERSION = {new_build};", proj_text)
    PBXPROJ.write_text(proj_text, encoding="utf-8")

    print()
    print("Next steps (docs/releases/release-train.md):")
    print(f"  1. git commit -am \"release: {target.tag}\" && push")
    print(f"  2. git tag -a {target.tag} -m \"ZynSign {target.version}\" && git push origin {target.tag}")
    return 0


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
    p_current = sub.add_parser("current", help="print the current release (machine-readable)")
    p_current.add_argument("--tag", action="store_true", help="print the tag form (vX.Y.Z[-suffix])")
    p_current.add_argument("--stage", action="store_true", help="print the ReleaseStage case name")
    p_current.set_defaults(func=cmd_current)
    p_check = sub.add_parser("check")
    p_check.add_argument("--tag")
    p_check.set_defaults(func=cmd_check)
    p_promote = sub.add_parser("promote")
    p_promote.add_argument("stage", nargs="?")
    p_promote.add_argument("--dry-run", action="store_true")
    p_promote.set_defaults(func=cmd_promote)
    p_rewind = sub.add_parser("rewind", help="move back to an earlier stop that has not shipped")
    p_rewind.add_argument("stage")
    p_rewind.add_argument("--dry-run", action="store_true")
    p_rewind.add_argument(
        "--allow-behind-tags",
        action="store_true",
        help="skip the already-tagged guard (only when the tags are known to be wrong)",
    )
    p_rewind.set_defaults(func=cmd_rewind)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
