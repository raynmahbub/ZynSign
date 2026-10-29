#!/usr/bin/env python3
"""Native XCTest evidence for CI — summary text, and a safe upload set.

Two commands, neither of which invokes xcodebuild or xcresulttool:

    python3 Scripts/ci/xctest_evidence.py summarize \\
        --json build/logs/xctest-summary.json \\
        --log build/logs/test.log \\
        --context build/logs/xctest-context.txt \\
        --output build/logs/xctest-summary.txt \\
        --markdown build/logs/xctest-summary.md

    python3 Scripts/ci/xctest_evidence.py prepare [build/logs]

`summarize` turns xcresulttool JSON (or, if that JSON is missing, the
xcodebuild log) into a concise count plus the Xcode version and simulator
destination recorded by build.sh. `prepare` runs before the artifact upload.
A missing log directory is not an error — compile-only runs and jobs that
die before xcodebuild have nothing to preserve, and the upload step warns
instead of failing. Signing-material filenames that land beside the logs are
moved out of the upload directory. The result bundle is not opened or rewritten.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Kept in lockstep with the workflow upload allowlist by
# Tests/Host/test_xctest_evidence.py. Adding a suffix here without the
# matching `!build/logs/**/*` exclusion fails that check.
FORBIDDEN_SUFFIXES = (
    ".p12",
    ".pfx",
    ".pem",
    ".key",
    ".p8",
    ".cer",
    ".crt",
    ".certsigningrequest",
    ".mobileprovision",
    ".provisionprofile",
    ".xcuserstate",
)
FORBIDDEN_NAMES = {
    ".netrc",
    "credentials",
    "id_rsa",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
}
EVIDENCE_NAMES = (
    "xctest-context.txt",
    "xctest-summary.txt",
    "xctest-summary.json",
    "xctest-summary.md",
    "ZynSignTests.xcresult",
)
COUNT_KEYS = (
    "totalTestCount",
    "passedTests",
    "failedTests",
    "skippedTests",
    "expectedFailures",
)
ALL_TESTS_END = re.compile(r"^\s*Test Suite 'All tests' (?:passed|failed)\b", re.MULTILINE)
ALL_TESTS_RESULT = re.compile(
    r"^\s*Test Suite 'All tests' (?:passed|failed)\b[^\n]*\n"
    r"\s*Executed (\d+) tests?, with (\d+) failures?\b",
    re.MULTILINE,
)
LOG_FAILURE = re.compile(r"Test Case '([^']+)' failed")
LOG_SKIPPED = re.compile(r"^\s*Test Case '.*' skipped", re.MULTILINE)
NAME_KEYS = ("testIdentifierString", "testName", "name")


def is_forbidden(name: str) -> bool:
    """True for a signing certificate, key, profile, or credential filename."""
    lowered = name.lower()
    if lowered in FORBIDDEN_NAMES or lowered.startswith("credentials."):
        return True
    return any(lowered.endswith(suffix) for suffix in FORBIDDEN_SUFFIXES)


def prepare(logs_dir: Path) -> int:
    """Quarantine forbidden top-level files. Missing evidence exits 0."""
    if not logs_dir.is_dir():
        print(f"No {logs_dir} directory; XCTest evidence was not produced.")
        return 0

    quarantine = logs_dir.parent / "xctest-evidence-quarantine"
    moved = 0
    for path in sorted(logs_dir.iterdir()):
        # Do not descend into the result bundle. Rewriting it would make the
        # downloaded .xcresult unreadable, which defeats the upload. A symlink
        # with a forbidden name is moved as a link; its target is left alone.
        if path.is_dir() and not path.is_symlink():
            continue
        if not is_forbidden(path.name):
            continue
        quarantine.mkdir(parents=True, exist_ok=True)
        destination = quarantine / path.name
        if destination.exists():
            destination.unlink()
        path.replace(destination)
        print(
            f"Excluding signing material from XCTest evidence: {path.name}",
            file=sys.stderr,
        )
        moved += 1
    if moved:
        print(
            f"Moved {moved} signing-material file(s) to {quarantine}; "
            "they will not be uploaded.",
            file=sys.stderr,
        )

    present = [path.name for path in sorted(logs_dir.glob("*.log"))]
    for name in EVIDENCE_NAMES:
        if (logs_dir / name).exists():
            present.append(name)
    if present:
        print("XCTest evidence present: " + ", ".join(present))
    else:
        print(
            f"No XCTest evidence files in {logs_dir}. "
            "The upload step will warn and continue."
        )
    return 0


def load_json(path: Path) -> dict:
    if not path.is_file() or path.stat().st_size == 0:
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def load_text(path: Path) -> str:
    if not path.is_file():
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def load_context(path: Path) -> dict[str, str]:
    context: dict[str, str] = {}
    for line in load_text(path).splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        context[key.strip()] = value.strip()
    return context


def first_int(node: object, key: str, depth: int = 0) -> int | None:
    """First integer stored under `key`, preferring the current object."""
    if depth > 6:
        return None
    if isinstance(node, dict):
        value = node.get(key)
        if isinstance(value, int) and not isinstance(value, bool):
            return value
        for child in node.values():
            found = first_int(child, key, depth + 1)
            if found is not None:
                return found
    elif isinstance(node, list):
        for child in node:
            found = first_int(child, key, depth + 1)
            if found is not None:
                return found
    return None


def counts_from_log(text: str) -> dict[str, int]:
    # A nested suite's execution line is not a run total. Multiple All tests
    # summaries can represent separate test processes, not a single aggregate.
    matches = list(ALL_TESTS_RESULT.finditer(text))
    if len(matches) != 1 or len(ALL_TESTS_END.findall(text)) != 1:
        return {}
    total, failures = map(int, matches[0].groups())
    counts: dict[str, int] = {}
    # The log does not reliably establish whether skipped cases are included
    # in the executed total, or whether their case lines are complete.
    if not LOG_SKIPPED.search(text):
        counts["totalTestCount"] = total
    # XCTest counts failure events, which need not equal failed test cases.
    if failures == 0:
        counts["failedTests"] = 0
    # Never infer passed or skipped counts from an incomplete log.
    return counts


def merge_counts(summary: dict, log_text: str) -> dict[str, int | None]:
    counts: dict[str, int | None] = {key: first_int(summary, key) for key in COUNT_KEYS}
    for key, value in counts_from_log(log_text).items():
        if counts.get(key) is None:
            counts[key] = value
    return counts


def failure_names(node: object, found: list[str] | None = None, depth: int = 0) -> list[str]:
    if found is None:
        found = []
    if depth > 8 or len(found) >= 40:
        return found
    if isinstance(node, dict):
        text = ""
        for field in ("failureText", "failure", "message"):
            value = node.get(field)
            if isinstance(value, str) and value.strip():
                text = value.strip()
                break
        result = node.get("result") or node.get("status") or ""
        failed = bool(text) or (isinstance(result, str) and result.lower() in {"failed", "failure"})
        if failed:
            for field in NAME_KEYS:
                value = node.get(field)
                if isinstance(value, str) and value.strip() and not value.strip().isdigit():
                    name = value.strip()
                    if name not in found:
                        found.append(name)
                    break
        for child in node.values():
            failure_names(child, found, depth + 1)
    elif isinstance(node, list):
        for child in node:
            failure_names(child, found, depth + 1)
    return found


def failure_names_from_log(text: str) -> list[str]:
    names: list[str] = []
    for match in LOG_FAILURE.finditer(text):
        name = match.group(1)
        if name not in names:
            names.append(name)
    return names


def resolve_result(summary: dict, log_text: str, context: dict[str, str]) -> str:
    raw = summary.get("result") or summary.get("status")
    if isinstance(raw, str) and raw.strip():
        return raw.strip()
    if "** TEST FAILED **" in log_text or "** TEST EXECUTE FAILED **" in log_text:
        return "Failed"
    if "** TEST SUCCEEDED **" in log_text:
        return "Passed"
    if context.get("run_tests") == "0":
        return "Skipped"
    destination = context.get("simulator_destination", "")
    if destination.startswith("not selected") or destination.startswith("skipped"):
        return "not run"
    return "unavailable"


def bundle_device(summary: dict) -> str:
    configs = summary.get("devicesAndConfigurations")
    if not isinstance(configs, list) or not configs or not isinstance(configs[0], dict):
        return ""
    device = configs[0].get("device")
    if not isinstance(device, dict):
        return ""
    parts = [
        str(device.get(key) or "")
        for key in ("deviceName", "platform", "osVersion")
    ]
    return " ".join(part for part in parts if part)


def status_badge(result: str, context: dict[str, str]) -> tuple[str, str]:
    lowered = result.lower()
    if context.get("run_tests") == "0" or lowered == "skipped":
        return "Skipped", "⏭️"
    if lowered.startswith("fail"):
        return "Failed", "❌"
    if lowered.startswith("pass") or lowered == "success":
        return "Passed", "✅"
    return "Warning", "⚠️"


def cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ").replace("`", "'")


def counts_phrase(counts: dict[str, int | None]) -> str:
    labels = (
        ("passedTests", "passed"),
        ("failedTests", "failed"),
        ("skippedTests", "skipped"),
        ("expectedFailures", "expected failures"),
        ("totalTestCount", "total"),
    )
    parts = [
        f"{counts[key]} {label}"
        for key, label in labels
        if counts.get(key) is not None
    ]
    return ", ".join(parts) if parts else "unavailable"


def one_line(result: str, counts: dict[str, int | None], context: dict[str, str]) -> str:
    parts = [f"{result}: {counts_phrase(counts)}"]
    xcode = context.get("xcode_version", "")
    destination = context.get("simulator_destination", "")
    if xcode and xcode != "unavailable":
        parts.append(xcode)
    if destination and destination != "unavailable":
        parts.append(destination)
    return "; ".join(parts)


def render_text(
    result: str,
    counts: dict[str, int | None],
    failures: list[str],
    context: dict[str, str],
    bundle: str,
    artifact: str,
    retention_days: int,
    device: str,
) -> str:
    lines = [
        one_line(result, counts, context),
        "XCTest summary",
        f"result={result}",
    ]
    for key in COUNT_KEYS:
        value = counts.get(key)
        lines.append(f"{key}={value if value is not None else 'unavailable'}")
    lines.append(f"xcode_version={context.get('xcode_version', 'unavailable')}")
    lines.append(
        f"simulator_destination={context.get('simulator_destination', 'unavailable')}"
    )
    if device:
        lines.append(f"bundle_device={device}")
    lines.append(f"scheme={context.get('scheme', 'unavailable')}")
    lines.append(f"project={context.get('project', 'unavailable')}")
    lines.append(f"run_tests={context.get('run_tests', 'unavailable')}")
    lines.append(f"result_bundle={bundle or context.get('result_bundle', 'unavailable')}")
    lines.append(f"artifact={artifact or 'unavailable'}")
    lines.append(f"retention_days={retention_days}")
    if failures:
        lines.append("failed_tests:")
        for name in failures[:30]:
            lines.append(f"  - {name}")
        if len(failures) > 30:
            lines.append(f"  - … {len(failures) - 30} more")
    return "\n".join(lines) + "\n"


def render_markdown(
    result: str,
    counts: dict[str, int | None],
    failures: list[str],
    context: dict[str, str],
    bundle: str,
    artifact: str,
    retention_days: int,
    device: str,
    run_url: str,
) -> str:
    status, verdict = status_badge(result, context)
    bundle_path = bundle or context.get("result_bundle", "unavailable")
    lines = [
        "## 🔨 XCTest evidence",
        "_Native result bundle_",
        "",
        f"**{verdict} {status}**",
        "",
        "| | |",
        "| --- | --- |",
        f"| Xcode | {cell(context.get('xcode_version', 'unavailable'))} |",
        f"| Destination | `{cell(context.get('simulator_destination', 'unavailable'))}` |",
    ]
    if device:
        lines.append(f"| Bundle device | {cell(device)} |")
    lines.extend(
        [
            f"| Result | {cell(result)} |",
            f"| Counts | {cell(counts_phrase(counts))} |",
            f"| Bundle | `{cell(bundle_path)}` |",
            f"| Artifact | `{cell(artifact or 'unavailable')}` |",
            f"| Retention | {retention_days} days |",
        ]
    )
    if run_url:
        lines.append(f"| Run | {run_url} |")
    lines.append("")
    if failures:
        lines.append("Failed tests (see the result bundle for the assertion text):")
        lines.append("")
        for name in failures[:20]:
            lines.append(f"- `{name.replace('`', '')}`")
        if len(failures) > 20:
            lines.append(f"- … {len(failures) - 20} more in the result bundle")
        lines.append("")
    retrieve = artifact or "xctest-results-<run-id>-<attempt>"
    lines.append(
        "Download this artifact from the run page, or "
        f"`gh run download <run-id> --name {retrieve}`. "
        "On a Mac, open `ZynSignTests.xcresult` in Xcode. "
        "The artifact is the test log and the result bundle only — not DerivedData, "
        "signing certificates, private keys, or provisioning profiles."
    )
    lines.append("")
    return "\n".join(lines) + "\n"


def summarize(args: argparse.Namespace) -> int:
    summary_path = Path(args.json) if args.json else Path()
    summary = load_json(summary_path) if args.json else {}
    if args.json and summary_path.is_file() and not summary and summary_path.stat().st_size:
        # Unreadable tool output should not be uploaded as if it were a summary.
        try:
            summary_path.unlink()
        except OSError:
            pass
    log_text = load_text(Path(args.log)) if args.log else ""
    context = load_context(Path(args.context)) if args.context else {}
    result = resolve_result(summary, log_text, context)
    counts = merge_counts(summary, log_text)
    failures = failure_names(summary)
    for name in failure_names_from_log(log_text):
        if name not in failures:
            failures.append(name)
    device = bundle_device(summary)
    text = render_text(
        result,
        counts,
        failures,
        context,
        args.bundle or "",
        args.artifact or "",
        args.retention_days,
        device,
    )
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="utf-8")
    if args.markdown:
        markdown = render_markdown(
            result,
            counts,
            failures,
            context,
            args.bundle or "",
            args.artifact or "",
            args.retention_days,
            device,
            args.run_url or "",
        )
        markdown_path = Path(args.markdown)
        markdown_path.parent.mkdir(parents=True, exist_ok=True)
        markdown_path.write_text(markdown, encoding="utf-8")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    prepare_parser = sub.add_parser("prepare", help="quarantine signing material beside the logs")
    prepare_parser.add_argument("logs_dir", nargs="?", default="build/logs")

    summary_parser = sub.add_parser("summarize", help="write the concise XCTest summary")
    summary_parser.add_argument("--json", default="")
    summary_parser.add_argument("--log", default="")
    summary_parser.add_argument("--context", default="")
    summary_parser.add_argument("--bundle", default="")
    summary_parser.add_argument("--artifact", default="")
    summary_parser.add_argument("--retention-days", type=int, default=14)
    summary_parser.add_argument("--run-url", default="")
    summary_parser.add_argument("--output", required=True)
    summary_parser.add_argument("--markdown", default="")

    args = parser.parse_args(argv)
    if args.command == "prepare":
        return prepare(Path(args.logs_dir))
    return summarize(args)


if __name__ == "__main__":
    raise SystemExit(main())
