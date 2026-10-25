#!/usr/bin/env python3
"""
audit_release_gating.py — a staged feature with nothing to switch on.

`ReleaseFeature` is a promise about a *stop*, not a promise about code. The
catalogue reads it and tells the user "Planned · v0.9.0-beta.3"; the release
train reads it and says that stop turns the feature on. Both statements are
only true if the app contains a surface the gate can actually reveal. When it
does not, the train reaches the stop, bumps the version, and nothing changes
for anyone — the release notes claim a capability that no screen can show.

Two features were in exactly that state: `BatchSigningCoordinator` is a
complete, tested actor that no screen constructs, and `SigningHealthScore` /
`SigningHealthAssessment` are complete, tested domain types that nothing reads.
Both are scheduled — beta 3 and 1.0.0 — so both stops would have shipped the
promise and none of the feature. (Signing's existing health *card* is a
different, always-on diagnostic; it is not this feature.)

The rule this script enforces:

    Every `ReleaseFeature` is either referenced by the app's own source
    (something the intermediate layer can gate) or listed in
    `Scripts/ci/release-surface-deferrals.txt` with the reason it is not.

A deferral is a decision recorded in a file a reviewer reads, not a silence:
the audit also fails when a deferral has gone *stale* — the feature now has a
surface, so the entry must be deleted — which is what stops the list from
outliving the gaps it describes. This is the same shape as the design-token
baseline: the file states the current debt, and the check refuses both hidden
debt and forgotten repayment.

What counts as a reference: the feature's own identifier anywhere under
`ZynSign/`, outside the two files that *declare* features rather than use them
(`ReleaseTrain.swift`, `FeatureCatalog.swift`). The identifier is matched with
word boundaries and case, so `.batchSigning` is not satisfied by the
`BatchSigningCoordinator` type and `.signingHealthScore` is not satisfied by
`SigningHealthScore`.

Usage:
    python3 Scripts/audit_release_gating.py            # report
    python3 Scripts/audit_release_gating.py --list     # every feature, wired or not
    python3 Scripts/audit_release_gating.py --json     # machine-readable
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_DIR = ROOT / "ZynSign"
TRAIN_FILE = APP_DIR / "Application" / "ReleaseTrain.swift"
CATALOG_FILE = APP_DIR / "Application" / "FeatureCatalog.swift"
DEFERRALS_FILE = ROOT / "Scripts" / "ci" / "release-surface-deferrals.txt"

# The files that declare the vocabulary. A feature named here is being
# scheduled, described, or catalogued — none of which is a surface.
DECLARING_FILES = {TRAIN_FILE.resolve(), CATALOG_FILE.resolve()}

DEFERRAL = re.compile(r"^\s*(?P<feature>[a-z][A-Za-z0-9]*)\s*(?:[—:-]\s*)?(?P<reason>.*)$")


def release_features() -> list[str]:
    """Every `ReleaseFeature` case, in declaration order."""
    source = TRAIN_FILE.read_text()
    start = source.find("enum ReleaseFeature")
    if start < 0:
        raise SystemExit(f"audit_release_gating: cannot find enum ReleaseFeature in {TRAIN_FILE}")
    depth = 0
    end = len(source)
    for index in range(start, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                end = index
                break
    body = source[start:end]
    # Only the bare `case name` form: the metadata switches elsewhere in the
    # file are `case .name:` and must not be mistaken for declarations.
    return re.findall(r"^\s{4}case ([a-z][A-Za-z0-9]*)\s*$", body, re.MULTILINE)


def swift_files() -> list[Path]:
    return [
        path
        for path in sorted(APP_DIR.rglob("*.swift"))
        if path.resolve() not in DECLARING_FILES
    ]


def references(features: list[str]) -> dict[str, list[str]]:
    """Where each feature is used, as `path:line` strings."""
    found: dict[str, list[str]] = {feature: [] for feature in features}
    patterns = {
        feature: re.compile(rf"(?<!\w){re.escape(feature)}\b")
        for feature in features
    }
    for path in swift_files():
        text = path.read_text()
        relative = path.relative_to(ROOT).as_posix()
        for number, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            # A comment describing a feature is not a surface.
            if stripped.startswith("//") or stripped.startswith("///"):
                continue
            for feature, pattern in patterns.items():
                if pattern.search(line):
                    found[feature].append(f"{relative}:{number}")
    return found


def deferrals() -> dict[str, str]:
    """Declared deferrals, feature → reason. Blank `#` lines are comments."""
    if not DEFERRALS_FILE.exists():
        return {}
    declared: dict[str, str] = {}
    for line in DEFERRALS_FILE.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = DEFERRAL.match(line)
        if not match:
            continue
        declared[match.group("feature")] = match.group("reason").strip()
    return declared


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="machine-readable")
    parser.add_argument("--list", action="store_true", help="every feature and its state")
    args = parser.parse_args()

    features = release_features()
    used = references(features)
    deferred = deferrals()

    unknown = sorted(set(deferred) - set(features))
    unwired = [f for f in features if not used[f] and f not in deferred]
    stale = [f for f in features if used[f] and f in deferred]
    unreasoned = sorted(f for f, reason in deferred.items() if not reason)

    if args.json:
        print(json.dumps({
            "features": {f: {"references": used[f], "deferred": deferred.get(f)} for f in features},
            "unwired": unwired,
            "stale_deferrals": stale,
            "unknown_deferrals": unknown,
            "unreasoned_deferrals": unreasoned,
        }, indent=2))
        return 1 if (unwired or stale or unknown or unreasoned) else 0

    if args.list:
        for feature in features:
            if used[feature]:
                state = f"wired — {used[feature][0]}"
            elif feature in deferred:
                state = f"deferred — {deferred[feature]}"
            else:
                state = "NOTHING TO SWITCH ON"
            print(f"{feature:28} {state}")
        return 0

    problems = 0
    print("Release gating audit — every staged feature has a surface or a recorded decision")
    print()

    if unwired:
        problems += len(unwired)
        print(f"✗ {len(unwired)} staged feature(s) the app never references, and no deferral:")
        for feature in unwired:
            print(f"  · {feature} — nothing under ZynSign/ names it, so no gate can reveal it")
        print("      Wire a surface behind `ReleaseTrain.isAvailable(.{}`,".format("…"))
        print("      or record the decision in Scripts/ci/release-surface-deferrals.txt.")
        print()

    if unreasoned:
        problems += len(unreasoned)
        print(f"✗ {len(unreasoned)} deferral(s) without a reason:")
        for feature in unreasoned:
            print(f"  · {feature}")
        print()

    if stale:
        problems += len(stale)
        print(f"✗ {len(stale)} deferral(s) that have been repaid — delete them:")
        for feature in stale:
            print(f"  · {feature} — now referenced at {', '.join(used[feature][:3])}")
        print()

    if unknown:
        problems += len(unknown)
        print(f"✗ {len(unknown)} deferral(s) for a feature that does not exist:")
        for feature in unknown:
            print(f"  · {feature}")
        print()

    if problems:
        return 1

    wired = [f for f in features if used[f]]
    print(f"✓ {len(features)} staged features: {len(wired)} wired to a surface, "
          f"{len(deferred)} deferred with a reason.")
    for feature, reason in deferred.items():
        print(f"    deferred · {feature} — {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
