#!/usr/bin/env python3
"""Publish a minimal, best-effort report from a native xcresult bundle.

Raw xcresulttool output stays in memory and is never included in this report.
Unknown schemas, duplicate cases and unsupported tool interfaces fail closed.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess

TARGETS = (
    "MachOCodeSignatureRegionTests.testGrowingTheReservationIsRefusedWhenAnotherSegmentIsMappedInsideIt",
    "MachOSigningIntegrationTests.testADynamicLibraryIsAdmittedAndSigned",
    "TweakStagingTests.testOptionsRefuseAnEmptyPayloadAndADuplicateName",
)
CLASS = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*Tests)\b")
METHOD = re.compile(r"\bfunc\s+(test[A-Za-z0-9_]*)\s*\(\s*\)")
IDENTIFIER = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*Tests)\.(test[A-Za-z0-9_]*)$")
STATUSES = {"passed": "PASS", "failed": "FAIL", "skipped": "SKIPPED"}
COUNT_KEYS = ("passedTests", "failedTests", "skippedTests", "totalTestCount")


def source_allowlist(root: Path) -> set[str]:
    """Only publish identifiers already present as source declarations."""
    names: set[str] = set()
    for path in root.rglob("*.swift"):
        if path.is_symlink():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            continue
        for cls in CLASS.findall(text):
            for method in METHOD.findall(text):
                names.add(f"{cls}.{method}")
    return names


def test_results(data: object, allowed: set[str]) -> dict[str, str]:
    if not isinstance(data, dict) or not isinstance(data.get("testNodes"), list):
        return {}
    found: dict[str, list[str]] = {}

    def visit(node: object, suite: str = "") -> None:
        if not isinstance(node, dict):
            return
        node_type, name = node.get("nodeType"), node.get("name")
        if node_type == "Test Suite" and isinstance(name, str):
            suite = name if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*Tests", name) else ""
        if node_type == "Test Case" and isinstance(name, str):
            method = name[:-2] if name.endswith("()") else name
            identifier = f"{suite}.{method}"
            # The modern interface identifies cases as Class/testMethod(),
            # sometimes with a bundle prefix. Prefer it when present; do not
            # fall back to a display name if the identifier is inconsistent.
            raw_identifier = node.get("nodeIdentifier")
            if raw_identifier is not None:
                if not isinstance(raw_identifier, str):
                    return
                parts = raw_identifier.split("/")
                if len(parts) < 2:
                    return
                cls, method_id = parts[-2:]
                method_id = method_id[:-2] if method_id.endswith("()") else method_id
                identifier = f"{cls}.{method_id}"
                if suite and suite != cls:
                    return
            if IDENTIFIER.fullmatch(identifier) and identifier in allowed:
                raw = node.get("result")
                status = STATUSES.get(raw.lower(), "NOT VERIFIED") if isinstance(raw, str) else "NOT VERIFIED"
                # A case with repetitions can represent a retry or multiple
                # configurations; don't silently select a single outcome.
                children = node.get("children", [])
                if isinstance(children, list) and any(
                    isinstance(child, dict) and child.get("nodeType") == "Repetition"
                    for child in children
                ):
                    status = "NOT VERIFIED"
                found.setdefault(identifier, []).append(status)
            return
        children = node.get("children", [])
        if isinstance(children, list):
            for child in children:
                visit(child, suite)

    for node in data["testNodes"]:
        visit(node)
    # Multiple occurrences may represent retries, configurations or collisions.
    return {name: statuses[0] if len(statuses) == 1 else "NOT VERIFIED"
            for name, statuses in sorted(found.items())}


def aggregate(data: object) -> dict[str, int] | None:
    if not isinstance(data, dict):
        return None
    values = [data.get(key) for key in COUNT_KEYS]
    if any(type(value) is not int or value < 0 for value in values):
        return None
    expected = data.get("expectedFailures", 0)
    if type(expected) is not int or expected != 0:
        return None
    if sum(values[:3]) != values[3]:
        return None
    return dict(zip(COUNT_KEYS, values))


def xcresult_json(bundle: str, kind: str) -> object:
    if not bundle or not Path(bundle).is_dir():
        return None
    base = ["xcrun", "xcresulttool", "get", "test-results", kind]
    try:
        help_result = subprocess.run(base + ["--help"], capture_output=True, text=True, timeout=30)
        if help_result.returncode != 0 or "--path" not in help_result.stdout or "--format" not in help_result.stdout:
            return None
        result = subprocess.run(base + ["--path", bundle, "--format", "json"],
                                capture_output=True, text=True, timeout=180)
        if result.returncode != 0:
            return None
        return json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def create_report(tests: object, summary: object, allowed: set[str]) -> dict:
    results = test_results(tests, allowed)
    return {
        "counts": aggregate(summary),
        "named_tests": {name: results.get(name, "NOT VERIFIED") for name in TARGETS},
        "tests": results,
        "limitations": "Only recognized XCTest cases with identifiers found in source are included; missing, unsupported, or repeated cases are not verified.",
    }


def markdown(report: dict) -> str:
    counts = report["counts"]
    counts_text = (f"{counts['passedTests']} passed, {counts['failedTests']} failed, "
                   f"{counts['skippedTests']} skipped, {counts['totalTestCount']} total") if counts else "NOT VERIFIED"
    lines = ["## Individual XCTest evidence", "", f"Aggregate: {counts_text}", "",
             "| Test | Status |", "| --- | --- |"]
    lines.extend(f"| `{name}` | {status} |" for name, status in report["named_tests"].items())
    lines.extend(["", report["limitations"], ""])
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", default="")
    parser.add_argument("--sources", default="Tests/ZynSignTests")
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    report = create_report(xcresult_json(args.bundle, "tests"), xcresult_json(args.bundle, "summary"),
                           source_allowlist(Path(args.sources)))
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "xctest-results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    md = markdown(report)
    (out / "xctest-results.md").write_text(md, encoding="utf-8")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(md)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        # Names and values are fixed constants or validated numbers/statuses.
        for name, status in report["named_tests"].items():
            print(f"::notice title=XCTest individual result::{name}: {status}")
        counts = report["counts"]
        text = ", ".join(f"{key}={counts[key]}" for key in COUNT_KEYS) if counts else "NOT VERIFIED"
        print(f"::notice title=XCTest verified aggregate::{text}")


if __name__ == "__main__":
    main()
