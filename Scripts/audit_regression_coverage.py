#!/usr/bin/env python3
"""
audit_regression_coverage.py — that the regression catalogue names real tests.

The Compatibility Lab reports one line per workflow under "Regression
Coverage". Where the behaviour is frozen by the unit-test target, the Lab
cannot run it from inside the application, so the line names the test types
that freeze it instead. A name nobody keeps is worse than no name: it reads
like coverage and is none.

This script reads `RegressionCoverageCatalog.swift`, finds every test type it
names, and checks that the type exists in the test target. It also reports
which workflows have no runtime probe, so the release decision can see how
much of the regression answer is being deferred to CI.

Usage:
    python3 Scripts/audit_regression_coverage.py            # report
    python3 Scripts/audit_regression_coverage.py --json     # machine-readable
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "ZynSign" / "Application" / "CompatibilityLab" / "RegressionCoverage.swift"
TESTS_DIR = ROOT / "Tests" / "ZynSignTests"

# One catalogue entry: its identifier, the workflow, the behaviour, the tests
# it names, and the probe the Lab runs.
ENTRY = re.compile(
    r"RegressionCoverageEntry\(\s*"
    r"id:\s*\"(?P<id>[^\"]+)\"\s*,\s*"
    r"area:\s*\"(?P<area>[^\"]+)\"\s*,\s*"
    r"behaviour:\s*\"(?P<behaviour>.*?)\"\s*,\s*"
    r"testSuites:\s*\[(?P<suites>.*?)\]\s*,\s*"
    r"probe:\s*\.(?P<probe>\w+)\s*\)",
    re.DOTALL,
)
SUITE_NAME = re.compile(r"\"(?P<name>[A-Za-z0-9_]+)\"")
# A test type in the test target, named the way Swift names it.
TEST_TYPE = re.compile(r"^\s*(?:final\s+)?(?:class|struct)\s+(?P<name>[A-Za-z0-9_]+)")


def load_catalog() -> list[dict]:
    """The catalogue as data, read from the Swift file that owns it."""
    if not CATALOG.exists():
        raise SystemExit(f"Catalogue not found: {CATALOG}")
    text = CATALOG.read_text(encoding="utf-8")
    entries: list[dict] = []
    for match in ENTRY.finditer(text):
        entries.append(
            {
                "id": match.group("id"),
                "area": match.group("area"),
                "behaviour": " ".join(match.group("behaviour").split()),
                "testSuites": SUITE_NAME.findall(match.group("suites")),
                "probe": match.group("probe"),
            }
        )
    return entries


def test_types() -> set[str]:
    """Every type declared in the unit-test target."""
    names: set[str] = set()
    for path in sorted(TESTS_DIR.rglob("*.swift")):
        for line in path.read_text(encoding="utf-8").splitlines():
            match = TEST_TYPE.match(line)
            if match:
                names.add(match.group("name"))
    return names


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    entries = load_catalog()
    available = test_types()

    problems: list[str] = []
    for entry in entries:
        for suite in entry["testSuites"]:
            if suite not in available:
                problems.append(
                    f"{entry['id']}: names test type '{suite}', which does not exist in "
                    f"Tests/ZynSignTests — rename the catalogue entry or add the test"
                )
        if not entry["testSuites"]:
            problems.append(f"{entry['id']}: names no test type, so nothing freezes it")

    deferred = [entry["id"] for entry in entries if entry["probe"] == "none"]
    executed = [entry["id"] for entry in entries if entry["probe"] != "none"]

    if args.json:
        print(
            json.dumps(
                {
                    "entries": entries,
                    "problems": problems,
                    "executedInApp": executed,
                    "deferredToTestTarget": deferred,
                    "ok": not problems,
                },
                indent=2,
            )
        )
        return 0 if not problems else 1

    print("Regression catalogue — that every frozen behaviour names a real test")
    print()
    for entry in entries:
        kind = "executed in-app" if entry["probe"] != "none" else "deferred to the test target"
        print(f"  {entry['area']} ({entry['id']}) — {kind}")
        print(f"      tests: {', '.join(entry['testSuites'])}")
    print()
    print(f"  Executed in the app: {len(executed)} · Deferred to CI: {len(deferred)}")

    if problems:
        print("\n✗ The catalogue does not match the test target:", file=sys.stderr)
        for problem in problems:
            print(f"  · {problem}", file=sys.stderr)
        return 1

    print("\n✓ Every named test type exists in Tests/ZynSignTests.")
    if deferred:
        print(
            f"  Note: {len(deferred)} workflow(s) answer through CI rather than in the app. "
            f"Run the test target before reading those rows as settled."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
