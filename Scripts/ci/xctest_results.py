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
# Leave room for the other sections written to the same GitHub step summary.
MAX_REPORT_BYTES = 128 * 1024


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

    def visit(node: object, suite: str | None = "") -> None:
        if not isinstance(node, dict):
            return
        node_type, name = node.get("nodeType"), node.get("name")
        if node_type == "Test Suite":
            # Retain even unrecognized suite names for conflict detection.
            suite = name if isinstance(name, str) and name else None
        if node_type == "Test Case":
            method = (name[:-2] if name.endswith("()") else name) if isinstance(name, str) else ""
            display_id = f"{suite}.{method}" if suite else ""
            candidates = {display_id} if IDENTIFIER.fullmatch(display_id) else set()
            raw_identifier = node.get("nodeIdentifier")
            identifier = ""
            if isinstance(raw_identifier, str):
                parts = raw_identifier.split("/")
                if len(parts) >= 2:
                    cls, method_id = parts[-2:]
                    method_id = method_id[:-2] if method_id.endswith("()") else method_id
                    identifier = f"{cls}.{method_id}"
                    if IDENTIFIER.fullmatch(identifier):
                        candidates.add(identifier)
            conflict = (
                suite is None or not method
                or ("nodeIdentifier" in node and (
                    not IDENTIFIER.fullmatch(identifier)
                    or method != identifier.split(".", 1)[1]
                    or (suite and suite != identifier.split(".", 1)[0])
                ))
            )
            raw = node.get("result")
            status = STATUSES.get(raw.lower(), "NOT VERIFIED") if isinstance(raw, str) else "NOT VERIFIED"
            children = node.get("children", [])
            if conflict or not isinstance(children, list) or any(
                isinstance(child, dict) and child.get("nodeType") == "Repetition"
                for child in children
            ):
                status = "NOT VERIFIED"
            # Keep every recognizable identity from a conflicting record so it
            # cannot disappear before duplicate/ambiguity detection.
            for candidate in candidates & allowed:
                found.setdefault(candidate, []).append(status)
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
    counts = aggregate(summary)
    limitations = "Only recognized XCTest cases with identifiers found in source are included; missing, unsupported, or repeated cases are not verified."
    if counts and any(
        list(results.values()).count(status) > counts[key]
        for status, key in (("PASS", "passedTests"), ("FAIL", "failedTests"), ("SKIPPED", "skippedTests"))
    ):
        counts = None
        limitations += " Aggregate is inconsistent with recognized per-test results and is not verified."
    return {
        "counts": counts,
        "named_tests": {name: results.get(name, "NOT VERIFIED") for name in TARGETS},
        "tests": results,
        "limitations": limitations,
    }


def markdown(report: dict, max_bytes: int = MAX_REPORT_BYTES) -> str:
    counts = report["counts"]
    counts_text = (f"{counts['passedTests']} passed, {counts['failedTests']} failed, "
                   f"{counts['skippedTests']} skipped, {counts['totalTestCount']} total") if counts else "NOT VERIFIED"
    lines = ["## Individual XCTest evidence", "", f"Aggregate: {counts_text}", "",
             "| Test | Status |", "| --- | --- |"]
    lines.extend(f"| `{name}` | {status} |" for name, status in report["named_tests"].items())
    lines.extend(["", report["limitations"], "", "### Recognized per-test results", "",
                  "| Test | Status |", "| --- | --- |"])
    prefix = "\n".join(lines) + "\n"
    # Defend the Markdown renderer as well as the parser against unsafe names
    # and unknown status values. The JSON report is generated by the parser.
    tests = [(name, status if isinstance(status, str) and status in {"PASS", "FAIL", "SKIPPED", "NOT VERIFIED"} else "NOT VERIFIED")
             for name, status in report["tests"].items()
             if isinstance(name, str) and IDENTIFIER.fullmatch(name)]
    tests.sort(key=lambda item: item[0])
    rows = [f"| `{name}` | {status} |\n" for name, status in tests]
    ending = "\n" if rows else "\nNo recognized per-test results available.\n"
    full = prefix + "".join(rows) + ending
    if len(full.encode("utf-8")) <= max_bytes:
        return full

    def truncation_notice(omitted: int) -> str:
        return (f"\nTruncated: {omitted} per-test result(s) omitted from this summary. "
                "See `xctest-results.json` in the XCTest evidence artifact for the full sanitized report.\n")

    # Include the largest fitting prefix and its exact notice; this only
    # bounds our section, not other sections in the GitHub step summary.
    used = len(prefix.encode("utf-8"))
    selected = None
    for count in range(len(rows)):
        notice = truncation_notice(len(rows) - count)
        if used + len(notice.encode("utf-8")) <= max_bytes:
            selected = count
        used += len(rows[count].encode("utf-8"))
    if selected is None:
        raise ValueError("summary byte limit is too small for the fixed report and truncation notice")
    return prefix + "".join(rows[:selected]) + truncation_notice(len(rows) - selected)


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
