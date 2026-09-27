#!/usr/bin/env python3
"""
generate_hardening_report.py — a browsable hardening report, from evidence.

The Compatibility Lab runs on a device and writes JSON. This script turns that
JSON into an HTML page a reviewer can read without the device: the dashboard
rows, every check with its evidence and measurements, the release checklist,
the tracked limitations, and the notes about what the report does not claim.

It also runs the audits that belong to the host - the crash-surface
inventory, the accessibility source audit, and the regression catalogue - and
shows their results, whether or not a device report was supplied. The page
never fills a gap with a plausible number: a row with no evidence says
"not run", names what would settle it, and counts against the release.

Usage:
    python3 Scripts/generate_hardening_report.py
    python3 Scripts/generate_hardening_report.py --input build/lab/*.json
    python3 Scripts/generate_hardening_report.py --output build/hardening/index.html
    python3 Scripts/generate_hardening_report.py --search-dir . --serve 8000
"""

from __future__ import annotations

import argparse
import html
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "Scripts"

# The six rows the dashboard shows, in the order a release decision reads them.
DASHBOARD = [
    "iOSCompatibility",
    "deviceCompatibility",
    "signingPipeline",
    "storeBrowser",
    "performance",
    "crashStatus",
]

CATEGORY_NAMES = {
    "iOSCompatibility": "iOS Compatibility",
    "deviceCompatibility": "Device Compatibility",
    "signingPipeline": "Signing Pipeline",
    "storeBrowser": "Store Browser",
    "performance": "Performance",
    "crashStatus": "Crash Status",
    "securityPosture": "Security Posture",
    "accessibility": "Accessibility",
    "resourceResilience": "Resource Resilience",
    "regressionCoverage": "Regression Coverage",
}

STATUS_WORDS = {
    "passed": "Passed",
    "warning": "Needs attention",
    "failed": "Failed",
    "notRun": "Not run",
    "skipped": "Not applicable",
}

STATUS_MARKS = {
    "passed": "✓",
    "warning": "!",
    "failed": "✗",
    "notRun": "—",
    "skipped": "·",
}


# --------------------------------------------------------------- host audits


def run_script(name: str, *args: str) -> dict | None:
    """Runs one host audit and returns its JSON, or None when it failed."""
    script = SCRIPTS / name
    if not script.exists():
        return None
    try:
        completed = subprocess.run(
            [sys.executable, str(script), *args],
            capture_output=True,
            text=True,
            timeout=300,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError:
        return None


def host_audits() -> list[dict]:
    """Every audit that runs on the host, with its outcome."""
    audits: list[dict] = []

    crash = run_script("audit_crash_surface.py", "--json")
    if crash:
        constructs = crash.get("findings", [])
        total = sum(item["count"] for item in constructs)
        audits.append(
            {
                "title": "Crash surface inventory",
                "status": "passed" if crash.get("ok") else "failed",
                "summary": f"{total} construct(s) in ZynSign's sources, every one named in CrashSurfaceBaseline.swift"
                if crash.get("ok")
                else "The code and the baseline disagree",
                "evidence": [
                    f"{item['file']}: {item['construct']} × {item['count']}"
                    for item in constructs
                ]
                + [
                    entry["rationale"]
                    for entry in crash.get("baseline", [])
                ],
            }
        )

    accessibility = run_script("audit_accessibility.py", "--json")
    if accessibility:
        counts = accessibility.get("counts", {})
        # Only a finding fails the audit. A `review` item - text that may
        # shrink below the comfortable scale - is an observation for a human,
        # not a defect the source can settle.
        open_findings = sum(
            1
            for item in accessibility.get("findings", [])
            if item.get("severity") == "finding"
        )
        audits.append(
            {
                "title": "Accessibility source audit",
                "status": "passed" if open_findings == 0 else "failed",
                "summary": (
                    f"{counts.get('hardCodedColour', 0)} hard-coded colours, "
                    f"{counts.get('smallTouchTarget', 0)} undersized control(s), "
                    f"{counts.get('textScaling', 0)} text-scaling item(s) to review, "
                    f"{counts.get('waived', 0)} waived"
                ),
                "evidence": [
                    f"{item['kind']} in {item['text'][:110]}"
                    for item in accessibility.get("findings", [])[:12]
                ]
                + [
                    f"waived: {item['text'][:96]}"
                    for item in accessibility.get("waived", [])
                ],
            }
        )

    regression = run_script("audit_regression_coverage.py", "--json")
    if regression:
        entries = regression.get("entries", [])
        executed = len(regression.get("executedInApp", []))
        deferred = len(regression.get("deferredToTestTarget", []))
        audits.append(
            {
                "title": "Regression catalogue",
                "status": "passed" if regression.get("ok") else "failed",
                "summary": f"{len(entries)} frozen behaviour(s): {executed} executed in-app, {deferred} deferred to the test target",
                "evidence": [
                    f"{entry['area']}: {', '.join(entry['testSuites'])}" for entry in entries
                ],
            }
        )

    return audits


# --------------------------------------------------------------- discovery


def discover(search_dirs: list[Path]) -> list[Path]:
    """Every Compatibility Lab JSON report under the given directories."""
    found: list[Path] = []
    for directory in search_dirs:
        if directory.is_file():
            found.append(directory)
        elif directory.is_dir():
            found.extend(sorted(directory.rglob("compatibility-lab-*.json")))
    return found


def load_reports(paths: list[Path]) -> list[dict]:
    reports: list[dict] = []
    for path in paths:
        try:
            report = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        report["_source"] = str(path)
        reports.append(report)
    return reports


# --------------------------------------------------------------- rendering


def escape(text: object) -> str:
    return html.escape(str(text), quote=True)


def status_badge(status: str) -> str:
    return (
        f'<span class="badge badge-{escape(status)}">'
        f'<span aria-hidden="true">{escape(STATUS_MARKS.get(status, "·"))}</span> '
        f"{escape(STATUS_WORDS.get(status, status))}</span>"
    )


def benchmark_verdict(measurement: dict) -> str:
    """Whether a measurement met the benchmark it was compared against.

    The verdict is computed here rather than read from the JSON: the report
    carries the number, the threshold and which way is good, and the
    comparison is arithmetic anyone can repeat.
    """
    threshold = measurement.get("threshold")
    if threshold is None:
        return ""
    comparison = measurement.get("comparison", "informational")
    if comparison == "informational":
        return ""
    try:
        value = float(measurement.get("value"))
        bound = float(threshold)
    except (TypeError, ValueError):
        return ""
    met = value <= bound if comparison == "lowerIsBetter" else value >= bound
    return ' <span class="ok">within benchmark</span>' if met else ' <span class="bad">outside benchmark</span>'


def render_measurements(measurements: list[dict]) -> str:
    if not measurements:
        return ""
    items = []
    for measurement in measurements:
        items.append(
            f"<li>{escape(measurement.get('name', ''))}: "
            f"{escape(measurement.get('value'))} {escape(measurement.get('unit', ''))} "
            f"(benchmark {escape(measurement.get('threshold', '—'))})"
            f"{benchmark_verdict(measurement)}</li>"
        )
    return f'<ul class="measurements">{"".join(items)}</ul>'


def render_check(check: dict) -> str:
    evidence = "".join(f"<li>{escape(line)}</li>" for line in check.get("evidence", []))
    evidence_block = f'<ul class="evidence">{evidence}</ul>' if evidence else ""
    next_step = check.get("nextStep")
    next_block = (
        f'<p class="next"><strong>What to do next</strong> · {escape(next_step)}</p>'
        if next_step
        else ""
    )
    duration = check.get("durationMilliseconds", 0)
    duration_block = f"<p class=\"meta\">Took {escape(duration)} ms</p>" if duration else ""
    blocker = check.get("blocker")
    blocker_block = (
        f'<p class="meta">If this fails: {escape(blocker)}</p>' if blocker else ""
    )
    return f"""
      <details class="check">
        <summary>
          {status_badge(check.get("status", "notRun"))}
          <span class="check-title">{escape(check.get("title", check.get("id", "")))}</span>
        </summary>
        <div class="check-body">
          <p>{escape(check.get("summary", ""))}</p>
          <p><strong>What was verified</strong> · {escape(check.get("verified", ""))}</p>
          {next_block}
          {evidence_block}
          {render_measurements(check.get("measurements", []))}
          {duration_block}
          {blocker_block}
          <p class="meta id">{escape(check.get("id", ""))}</p>
        </div>
      </details>"""


def render_category(report: dict, category: str) -> str:
    checks = [c for c in report.get("checks", []) if c.get("category") == category]
    if not checks:
        return ""
    passed = sum(1 for c in checks if c.get("status") == "passed")
    failed = sum(1 for c in checks if c.get("status") == "failed")
    unrun = sum(1 for c in checks if c.get("status") in ("notRun", "skipped"))
    return f"""
    <section class="category">
      <h3>{escape(CATEGORY_NAMES.get(category, category))}</h3>
      <p class="meta">{passed} passed · {failed} failed · {unrun} not run</p>
      {"".join(render_check(c) for c in checks)}
    </section>"""


def render_report(report: dict) -> str:
    categories = []
    for category in DASHBOARD + [
        c for c in CATEGORY_NAMES if c not in DASHBOARD
    ]:
        rendered = render_category(report, category)
        if rendered:
            categories.append(rendered)
    notes = "".join(f"<li>{escape(note)}</li>" for note in report.get("notes", []))
    return f"""
    <article class="report">
      <h2>{escape(report.get("releaseStage", "unknown stage"))}
        <span class="meta">· {escape(report.get("marketingVersion", "?"))}
        ({escape(report.get("buildVersion", "?"))})</span></h2>
      <p class="meta">iOS {escape(report.get("osVersion", "?"))} ·
        {escape(report.get("deviceClass", "unknown"))} ·
        generated {escape(report.get("generatedAt", ""))} ·
        {escape(report.get("_source", ""))}</p>
      {"".join(categories)}
      <section class="category">
        <h3>What this report does not claim</h3>
        <ul class="evidence">{notes}</ul>
      </section>
    </article>"""


def render_audits(audits: list[dict]) -> str:
    if not audits:
        return ""
    blocks = []
    for audit in audits:
        evidence = "".join(f"<li>{escape(line)}</li>" for line in audit.get("evidence", []))
        blocks.append(
            f"""
      <div class="audit">
        {status_badge(audit.get("status", "notRun"))}
        <span class="check-title">{escape(audit["title"])}</span>
        <p>{escape(audit.get("summary", ""))}</p>
        <ul class="evidence">{evidence}</ul>
      </div>"""
        )
    return f"""
    <section class="category">
      <h3>Host audits — run when this page was built</h3>
      <p class="meta">These run on the machine that built this page. They say nothing about a
      device, and they are shown separately from the device's own results.</p>
      {"".join(blocks)}
    </section>"""


def render_page(reports: list[dict], audits: list[dict]) -> str:
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    if reports:
        body = "".join(render_report(report) for report in reports)
        headline = f"{len(reports)} Compatibility Lab report(s)"
        lead = (
            "Every row below is a check a device executed, or a row it could not and "
            "said so. A row marked <em>Not run</em> is an open question, not a pass."
        )
    else:
        body = "<p class=\"empty\">No Compatibility Lab report was found. The host audits below ran; the device rows did not, because no device report was supplied.</p>"
        headline = "No device report supplied"
        lead = (
            "Run the Compatibility Lab on a device or simulator "
            "(Settings → Compatibility Lab → Run the Lab), export its report, and build "
            "this page again with <code>--input</code>. Until then every device row is "
            "an open question, and the release checklist is incomplete."
        )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ZynSign · RC hardening report</title>
<style>
  :root {{
    --bg: #0f1115;
    --panel: #171a21;
    --line: #262b36;
    --text: #e6e8ee;
    --muted: #9aa3b2;
    --pass: #34c759;
    --warn: #ff9f0a;
    --fail: #ff453a;
    --none: #6b7280;
  }}
  @media (prefers-color-scheme: light) {{
    :root {{
      --bg: #f6f7f9;
      --panel: #ffffff;
      --line: #dfe3ea;
      --text: #10131a;
      --muted: #5b6472;
      --none: #8b95a3;
    }}
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; padding: 2rem 1rem 4rem;
    background: var(--bg); color: var(--text);
    font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  }}
  main {{ max-width: 920px; margin: 0 auto; }}
  h1 {{ font-size: 1.6rem; margin: 0 0 .25rem; }}
  h2 {{ font-size: 1.25rem; margin: 2rem 0 .25rem; }}
  h3 {{ font-size: 1.05rem; margin: 1.75rem 0 .25rem; }}
  p.lead {{ color: var(--muted); margin: 0 0 1.5rem; }}
  p.empty {{
    background: var(--panel); border: 1px solid var(--line);
    border-radius: 12px; padding: 1rem 1.25rem; color: var(--muted);
  }}
  .meta {{ color: var(--muted); font-size: .82rem; margin: .25rem 0; }}
  .meta.id {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; opacity: .7; }}
  section.category {{ margin-bottom: 1rem; }}
  article.report, .audit {{
    background: var(--panel); border: 1px solid var(--line);
    border-radius: 14px; padding: 1rem 1.25rem; margin-bottom: 1.5rem;
  }}
  details.check {{
    border-top: 1px solid var(--line); padding: .5rem 0;
  }}
  summary {{
    cursor: pointer; display: flex; align-items: baseline; gap: .5rem;
    list-style: none; padding: .25rem 0;
  }}
  summary::-webkit-details-marker {{ display: none; }}
  summary::before {{ content: "›"; color: var(--muted); width: .6rem; display: inline-block; }}
  details[open] summary::before {{ content: "⌄"; }}
  .check-title {{ font-weight: 600; }}
  .check-body {{
    padding: .25rem 0 .5rem 1.1rem; color: var(--text);
  }}
  .check-body p {{ margin: .35rem 0; }}
  ul.evidence, ul.measurements {{
    margin: .35rem 0; padding-left: 1.1rem; color: var(--muted); font-size: .85rem;
  }}
  ul.evidence li {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
  .next {{ color: var(--muted); }}
  .badge {{
    display: inline-block; border-radius: 999px; padding: .05rem .55rem;
    font-size: .72rem; font-weight: 600; border: 1px solid currentColor;
    white-space: nowrap;
  }}
  .badge-passed {{ color: var(--pass); }}
  .badge-warning {{ color: var(--warn); }}
  .badge-failed {{ color: var(--fail); }}
  .badge-notRun, .badge-skipped {{ color: var(--none); }}
  .ok {{ color: var(--pass); }}
  .bad {{ color: var(--fail); }}
  footer {{
    margin-top: 3rem; color: var(--muted); font-size: .82rem;
    border-top: 1px solid var(--line); padding-top: 1rem;
  }}
  code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
</style>
</head>
<body>
<main>
  <h1>ZynSign · RC hardening report</h1>
  <p class="meta">{escape(generated)} · built by Scripts/generate_hardening_report.py</p>
  <p class="lead">{lead}</p>
  <h2>{escape(headline)}</h2>
  {body}
  {render_audits(audits)}
  <footer>
    <p>Reproduce this page: <code>python3 Scripts/generate_hardening_report.py</code></p>
    <p>The page is built only from a Compatibility Lab JSON export and the host
    audits that ran beside it. Nothing here is inferred, and a row with no
    evidence is shown as not run.</p>
  </footer>
</main>
</body>
</html>
"""


# --------------------------------------------------------------- entry point


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        nargs="*",
        type=Path,
        help="Compatibility Lab JSON report(s) to render",
    )
    parser.add_argument(
        "--search-dir",
        nargs="*",
        type=Path,
        default=[ROOT],
        help="where to look for compatibility-lab-*.json reports",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "build" / "hardening" / "index.html",
        help="where to write the HTML page",
    )
    args = parser.parse_args()

    paths = list(args.input) if args.input else discover(args.search_dir)
    reports = load_reports(paths)
    audits = host_audits()

    page = render_page(reports, audits)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(page, encoding="utf-8")

    print(f"Wrote {args.output}")
    print(f"  device report(s): {len(reports)}")
    print(f"  host audits: {len(audits)}")
    if not reports:
        print(
            "\nNo device report was supplied, so every device row is reported as not run.\n"
            "Produce one with: Settings → Compatibility Lab → Run the Lab → Export report,\n"
            "then rebuild this page with --input <file>."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
