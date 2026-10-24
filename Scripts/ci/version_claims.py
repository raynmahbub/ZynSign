#!/usr/bin/env python3
"""ZynSign CI — release-version claims.

`ReleaseTrain.current` is the one authority for which stop this source is cut
for. Everything that names a release — the changelog, the release notes, the
in-app version history, and the product pages that say "this build ships N of
M" — is a claim about that authority, and a claim can go stale silently. It
has before: a whole `v0.1.0-alpha.3` section, a notes page, and an in-app
version-history row survived a train rewind for weeks, describing ten features
switched on in a build that was never tagged, while the train sat at `alpha2`
and the release pages still said `alpha1`.

This check compares those claims against the source and fails when any of them
names a stop the train has not reached, states a build number the project does
not carry, or reports a feature count the gate does not produce.

It reads files only: no git, no network, no Xcode. Run from the repository root
(`python3 Scripts/ci/version_claims.py`); `Scripts/ci/docs_check.sh` calls it.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path

TRAIN_FILE = Path("ZynSign/Application/ReleaseTrain.swift")
PROJECT_FILE = Path("ZynSign.xcodeproj/project.pbxproj")
CHANGELOG_FILE = Path("CHANGELOG.md")
CATALOG_FILE = Path("ZynSign/Application/VersionHistoryCatalog.swift")
NOTES_DIR = Path("docs/releases")
WHAT_DOES_NOT_EXIST = Path("docs/product/WHAT_DOES_NOT_EXIST.md")
FEATURE_STATUS = Path("docs/product/FEATURE_STATUS.md")
DOCS_INDEX = Path("docs/README.md")

errors: list[str] = []


def fail(message: str) -> None:
    errors.append(message)


def block(text: str, opener: str) -> str | None:
    """The brace-matched body of the first declaration starting with `opener`."""
    start = text.find(opener)
    if start < 0:
        return None
    depth = 0
    for index in range(start, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    return None


@dataclass(frozen=True)
class Stage:
    name: str
    version: str
    introduced: tuple[str, ...]

    @property
    def marketing(self) -> str:
        return self.version.split("-", 1)[0]

    @property
    def tag(self) -> str:
        return f"v{self.version}"



def load_train() -> tuple[list[Stage], str, dict[str, list[str]]]:
    """Stages in shipping order, the current stop's name, and feature sets."""
    source = TRAIN_FILE.read_text()

    stage_enum = block(source, "enum ReleaseStage")
    if stage_enum is None:
        raise SystemExit(f"version_claims: cannot find enum ReleaseStage in {TRAIN_FILE}")
    order = re.findall(r"^\s{4}case ([a-z][A-Za-z0-9]*)\b", stage_enum, re.M)

    versions = dict(re.findall(r'case \.(\w+): return "([^"]+)"', stage_enum))

    features_enum = block(source, "enum ReleaseFeature")
    if features_enum is None:
        raise SystemExit(f"version_claims: cannot find enum ReleaseFeature in {TRAIN_FILE}")
    features = re.findall(r"^\s{4}case ([a-z][A-Za-z0-9]*)\s*$", features_enum, re.M)

    introduced_body = stage_enum.split("var introducedFeatures", 1)[-1].split("var features", 1)[0]
    introduced: dict[str, tuple[str, ...]] = {}
    for line in introduced_body.splitlines():
        match = re.match(r"\s*case ([^:]+): return (\[[^\]]*\])\s*$", line)
        if not match:
            continue
        names = tuple(n.strip().lstrip(".") for n in match.group(2).strip("[]").split(",") if n.strip())
        for stage_name in match.group(1).split(","):
            introduced[stage_name.strip().lstrip(".")] = names

    current_match = re.search(r"static let current: ReleaseStage = \.(\w+)", source)
    if not current_match:
        raise SystemExit(f"version_claims: cannot find ReleaseTrain.current in {TRAIN_FILE}")

    stages = [
        Stage(name=name, version=versions[name], introduced=introduced.get(name, ()))
        for name in order
        if name in versions
    ]
    return stages, current_match.group(1), {"features": features, "introduced": introduced}


def project_versions() -> tuple[set[str], set[int]]:
    text = PROJECT_FILE.read_text()
    marketing = set(re.findall(r"MARKETING_VERSION = ([0-9][^;]*);", text))
    builds = set(int(b) for b in re.findall(r"CURRENT_PROJECT_VERSION = (\d+);", text))
    return marketing, builds


def unsupported_feature_count() -> int:
    """How many limits the catalogue records as never shipping."""
    source = Path("ZynSign/Application/FeatureCatalog.swift").read_text()
    body = block(source, "enum UnsupportedFeature") or ""
    return len(re.findall(r"^\s{4}case [a-z]", body, re.M))


def train_index(stages: list[Stage], version: str) -> int | None:
    for index, stage in enumerate(stages):
        if stage.version == version:
            return index
    return None


def cumulative_features(stages: list[Stage]) -> list[set[str]]:
    running: set[str] = set()
    out: list[set[str]] = []
    for stage in stages:
        running |= set(stage.introduced)
        out.append(set(running))
    return out


def check_changelog(stages: list[Stage], current: Stage) -> None:
    text = CHANGELOG_FILE.read_text()
    released = re.findall(r"^## \[([0-9][^\]]*)\] - (\d{4}-\d{2}-\d{2})", text, re.M)
    if not released:
        fail(f"{CHANGELOG_FILE}: no released section found")
        return

    previous_date: date | None = None
    for version, stamp in released:
        index = train_index(stages, version)
        if index is None:
            fail(
                f"{CHANGELOG_FILE}: `{version}` is not a stop on the release train "
                f"({current.version} is current)"
            )
            continue
        if index > train_index(stages, current.version):
            fail(
                f"{CHANGELOG_FILE}: `[{version}]` is a released section for a stop the train "
                f"has not reached (current is {current.version})"
            )
        cut = date.fromisoformat(stamp)
        if previous_date is not None and cut > previous_date:
            fail(f"{CHANGELOG_FILE}: `[{version}]` is dated {stamp}, after a newer entry above it")
        previous_date = cut

    newest = released[0][0]
    if train_index(stages, newest) is not None and train_index(stages, newest) > train_index(stages, current.version):
        fail(f"{CHANGELOG_FILE}: newest section `[{newest}]` runs ahead of the train")


def check_notes(stages: list[Stage], current: Stage) -> None:
    for page in sorted(NOTES_DIR.glob("notes-v*.md")):
        version = page.stem.removeprefix("notes-v")
        index = train_index(stages, version)
        if index is None:
            fail(f"{page}: notes for `{version}`, which is not a stop on the release train")
        elif index > train_index(stages, current.version):
            fail(
                f"{page}: notes for `{version}` ship ahead of the current stop "
                f"({current.version}); notes are written when the stop is cut"
            )


def check_catalog(stages: list[Stage], current: Stage, build: int) -> None:
    text = CATALOG_FILE.read_text()
    entries = []
    for match in re.finditer(
        r"VersionHistoryEntry\(\s*tag: \"([^\"]+)\",\s*marketingVersion: \"([^\"]+)\",\s*"
        r"buildNumber: (\d+),\s*releasedAt: DateComponents\(year: (\d+), month: (\d+), day: (\d+)\)",
        text,
    ):
        entries.append((match.group(1), int(match.group(3))))
    if not entries:
        fail(f"{CATALOG_FILE}: no version-history entries could be read")
        return

    current_index = train_index(stages, current.version)
    last_index: int | None = None
    last_build: int | None = None
    for tag, entry_build in entries:
        version = tag.removeprefix("v")
        index = train_index(stages, version)
        if index is None:
            fail(f"{CATALOG_FILE}: `{tag}` is not a stop on the release train")
            continue
        if index > current_index:
            fail(
                f"{CATALOG_FILE}: `{tag}` is listed as shipped, but the train is at "
                f"{current.version} — the in-app version history must not name a stop "
                f"that was never cut"
            )
        if last_index is not None and index >= last_index:
            fail(f"{CATALOG_FILE}: `{tag}` is out of order (entries run newest first)")
        if last_build is not None and entry_build >= last_build:
            fail(
                f"{CATALOG_FILE}: `{tag}` carries build {entry_build}, which does not "
                f"increase over the newer entry below it ({last_build})"
            )
        last_index, last_build = index, entry_build

    first_tag, first_build = entries[0]
    if first_tag != current.tag:
        fail(f"{CATALOG_FILE}: newest entry is `{first_tag}`, expected the current stop {current.tag}")
    if first_tag == current.tag and first_build != build:
        fail(
            f"{CATALOG_FILE}: the current stop is listed with build {first_build}, "
            f"but the project carries {build}"
        )


def check_what_does_not_exist(
    stages: list[Stage], current: Stage, build: int, on: int, total: int, never: int
) -> None:
    text = WHAT_DOES_NOT_EXIST.read_text()
    header = re.search(
        r"ZynSign `v([^`]+)` \(market `([^`]+)`, build `(\d+)`\) — \*\*"
        r"(\d+) staged · (\d+) on · (\d+) still ahead · (\d+) never\*\*",
        text,
    )
    if not header:
        fail(f"{WHAT_DOES_NOT_EXIST}: the version/count header could not be read")
        return
    version, market, stated_build, staged, stated_on, ahead, stated_never = header.groups()
    if version != current.version:
        fail(
            f"{WHAT_DOES_NOT_EXIST}: header names `v{version}`, but the train is at {current.tag}"
        )
    if market != current.marketing:
        fail(f"{WHAT_DOES_NOT_EXIST}: header says market `{market}`, the train says `{current.marketing}`")
    if int(stated_build) != build:
        fail(f"{WHAT_DOES_NOT_EXIST}: header says build `{stated_build}`, the project carries {build}")
    counted = (int(staged), int(stated_on), int(ahead), int(stated_never))
    expected = (total, on, total - on, never)
    if counted != expected:
        fail(
            f"{WHAT_DOES_NOT_EXIST}: header counts {counted[0]} staged · {counted[1]} on · "
            f"{counted[2]} ahead · {counted[3]} never, but the gate produces "
            f"{expected[0]} staged · {expected[1]} on · {expected[2]} ahead · {expected[3]} never"
        )


def check_feature_status(stages: list[Stage], current: Stage, build: int) -> None:
    text = FEATURE_STATUS.read_text()
    header = re.search(
        r"train at `v([^`]+)` \(`\.(\w+)`, marketing `([^`]+)`, build `(\d+)`\)", text
    )
    if not header:
        fail(f"{FEATURE_STATUS}: the train line could not be read")
    else:
        version, stage_name, market, stated_build = header.groups()
        if (version, stage_name, market, int(stated_build)) != (
            current.version,
            current.name,
            current.marketing,
            build,
        ):
            fail(
                f"{FEATURE_STATUS}: says `v{version}` (`.{stage_name}`, marketing `{market}`, "
                f"build `{stated_build}`), the train says {current.tag} (`.{current.name}`, "
                f"marketing `{current.marketing}`, build `{build}`)"
            )

    stated_current = re.search(r"`ReleaseTrain\.current` is `\.(\w+)`", text)
    if not stated_current:
        fail(f"{FEATURE_STATUS}: the `ReleaseTrain.current` line could not be read")
    elif stated_current.group(1) != current.name:
        fail(
            f"{FEATURE_STATUS}: says `ReleaseTrain.current` is `.{stated_current.group(1)}`, "
            f"the source says `.{current.name}`"
        )

    marked = re.findall(r"^\| `v([^`]+)` \(current\) \|", text, re.M)
    if marked != [current.version]:
        fail(
            f"{FEATURE_STATUS}: rows marked current are {marked or 'none'}, "
            f"expected exactly `{current.version}`"
        )


def check_docs_badge(current: Stage) -> None:
    text = DOCS_INDEX.read_text()
    badge = re.search(r"badge/version-(.+?)-orange", text)
    if not badge:
        fail(f"{DOCS_INDEX}: the version badge could not be read")
        return
    version = badge.group(1).replace("--", "-")
    if version != current.version:
        fail(f"{DOCS_INDEX}: badge says `{version}`, the train is at {current.version}")


def main() -> int:
    stages, current_name, extras = load_train()
    current = next((s for s in stages if s.name == current_name), None)
    if current is None:
        raise SystemExit(f"version_claims: `{current_name}` is not a declared stage")

    marketing, builds = project_versions()
    if len(builds) != 1:
        fail(f"{PROJECT_FILE}: CURRENT_PROJECT_VERSION is not one value ({sorted(builds)})")
        return 1
    build = builds.pop()
    if marketing != {current.marketing}:
        fail(
            f"{PROJECT_FILE}: MARKETING_VERSION {sorted(marketing)} ≠ {current.tag} "
            f"(needs {current.marketing})"
        )

    reached = cumulative_features(stages)
    index = stages.index(current)
    on = len(reached[index])
    total = len(extras["features"])
    never = unsupported_feature_count()

    check_changelog(stages, current)
    check_notes(stages, current)
    check_catalog(stages, current, build)
    check_what_does_not_exist(stages, current, build, on, total, never)
    check_feature_status(stages, current, build)
    check_docs_badge(current)

    for message in errors:
        print(f"::error title=version-claims::{message}")
    if errors:
        print(f"Version claims: {len(errors)} error(s).")
        return 1
    print(
        f"Version claims: {current.tag} · build {build} · {on} of {total} staged features · "
        f"{never} never — changelog, notes, version history and product pages agree."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
