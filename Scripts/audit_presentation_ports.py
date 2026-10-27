#!/usr/bin/env python3
"""audit_presentation_ports.py — every shell port is installed by the shell.

A `*Presentation` value in `Presentation/` is a promise the shell makes to the
screens below it: "ask me, and the surface will open". The promise only holds
if the shell actually installs the port into the SwiftUI environment. When it
does not, every caller silently gets the default no-op, the surface never
appears, and nothing fails — the code compiles, the tests pass, and the feature
is simply unreachable.

That is exactly what happened to the Export Center: `ExportsPresentation`,
`ExportCenter`, `ExportsCenterModel`, and the whole detail screen existed,
tested and composed, while nothing ever installed the port or built the list.
"Where did my signed package go?" had no answer.

This script makes the promise mechanical. It reads every presentation port in
`Presentation/`, then requires `Presentation/RootView.swift` — the shell — to
install each one:

    .environment(\\.<key>, <Port>(...))

A port that is deliberately not installed must be listed in
`Scripts/ci/presentation-port-deferrals.txt` with the reason, and an entry that
has since been installed fails the audit, so the list cannot outlive the gap it
describes.

Usage:
    python3 Scripts/audit_presentation_ports.py           # report
    python3 Scripts/audit_presentation_ports.py --json    # machine-readable
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PRESENTATION = ROOT / "ZynSign" / "Presentation"
SHELL = PRESENTATION / "RootView.swift"
DEFERRALS = ROOT / "Scripts" / "ci" / "presentation-port-deferrals.txt"

# A port's declaration: the struct, and the environment key it is installed
# under. Both are plain Swift text, so the audit reads them rather than
# guessing from names.
PORT = re.compile(
    r"^struct (?P<name>\w+Presentation)\s*\{",
    re.M,
)
KEY = re.compile(
    r"var (?P<key>\w+Presentation)\s*:\s*(?P<name>\w+Presentation)\s*\{",
    re.M,
)


@dataclass(frozen=True)
class Port:
    name: str
    key: str
    file: str


def load_ports() -> list[Port]:
    """Every presentation port declared under `Presentation/`."""
    ports: list[Port] = []
    for path in sorted(PRESENTATION.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for declaration in PORT.finditer(text):
            name = declaration.group("name")
            key_match = KEY.search(path.read_text(encoding="utf-8"))
            if key_match is None or key_match.group("name") != name:
                # The environment key lives in the same file as the port it
                # installs; a file with the struct but no key is a port that
                # cannot be installed at all.
                continue
            ports.append(Port(name=name, key=key_match.group("key"), file=str(path.relative_to(ROOT))))
    return ports


def load_deferrals() -> dict[str, str]:
    """Ports the shell does not install, with the recorded reason."""
    if not DEFERRALS.exists():
        return {}
    deferrals: dict[str, str] = {}
    for line in DEFERRALS.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        name, _, reason = stripped.partition("—")
        deferrals[name.strip()] = reason.strip()
    return deferrals


def installs(shell: str, port: Port) -> bool:
    """Whether the shell installs `port` into the environment."""
    pattern = re.compile(
        r"\.environment\(\s*\\\." + re.escape(port.key) + r"\s*,\s*" + re.escape(port.name) + r"\s*\(",
        re.S,
    )
    return pattern.search(shell) is not None


def main() -> int:
    parser = argparse.ArgumentParser(description="Every shell port is installed by the shell.")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    arguments = parser.parse_args()

    ports = load_ports()
    if not ports:
        print("::error title=presentation-ports::no presentation port could be read")
        return 1

    shell = SHELL.read_text(encoding="utf-8")
    deferrals = load_deferrals()

    missing = [port for port in ports if not installs(shell, port) and port.name not in deferrals]
    repaid = [name for name in deferrals if any(installs(shell, port) for port in ports if port.name == name)]
    stale = [name for name in deferrals if not any(port.name == name for port in ports)]

    findings = []
    for port in missing:
        findings.append({
            "port": port.name,
            "file": port.file,
            "problem": f"{port.name} is never installed by the shell, so every caller gets the default "
                       f"no-op and the surface it opens is unreachable",
        })
    for name in repaid:
        findings.append({
            "port": name,
            "file": str(DEFERRALS.relative_to(ROOT)),
            "problem": f"{name} is installed by the shell now — delete its deferral entry",
        })
    for name in stale:
        findings.append({
            "port": name,
            "file": str(DEFERRALS.relative_to(ROOT)),
            "problem": f"{name} is deferred but no such port exists",
        })

    if arguments.json:
        print(json.dumps({"ports": [p.name for p in ports], "findings": findings}, indent=2))
    else:
        print("Presentation ports — every shell surface is installed by the shell\n")
        for port in ports:
            state = "deferred" if port.name in deferrals else ("installed" if installs(shell, port) else "NOT INSTALLED")
            print(f"  {port.name:<34} {port.key:<30} {state}")
        if findings:
            print()
            for finding in findings:
                print(f"  ✗ {finding['port']}: {finding['problem']}")
        else:
            print(f"\n✓ {len(ports)} presentation port(s): every surface the screens ask for is installed.")

    for finding in findings:
        print(f"::error title=presentation-ports::{finding['port']}: {finding['problem']}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
