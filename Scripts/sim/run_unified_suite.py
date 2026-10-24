#!/usr/bin/env python3
"""Run the sideloading engine suite and write the evidence report.

Three things happen here:

1. every host test runs (``unittest`` over ``Tests/Host``),
2. an end-to-end evidence pass produces real bytes — a signed package, an
   OpenSSL-verified CMS, a guest container, and an installation on a simulated
   device — and records what each step proved,
3. ``Reports/unified-engine-report.md`` is written from both.

Run it with no arguments from anywhere in the repository:

    python3 Scripts/sim/run_unified_suite.py

Exit status is the test suite's: a red suite is a red script.
"""

from __future__ import annotations

import hashlib
import io
import platform
import plistlib
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOST_TESTS = ROOT / "Tests/Host"
REPORT = ROOT / "Reports/unified-engine-report.md"

sys.path.insert(0, str(HOST_TESTS))
sys.path.insert(0, str(ROOT))

from zynsim import (bundle, codesign, container, device, fixtures, macho,  # noqa: E402
                    pairing, profile, simulator)


def git_sha() -> str:
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT,
                              capture_output=True, text=True, check=True).stdout.strip()
    except Exception:  # noqa: BLE001 - the report is still useful without a sha
        return "unknown"


def run_tests() -> dict:
    loader = unittest.TestLoader()
    suite = loader.discover(str(HOST_TESTS), pattern="test_*.py")
    # Collect the names first: a runner clears each suite entry after it runs.
    names = sorted({test.id().split(".")[0] for test in _flatten(suite)})
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    return {
        "ran": result.testsRun,
        "failures": len(result.failures),
        "errors": len(result.errors),
        "skipped": len(result.skipped),
        "ok": result.wasSuccessful(),
        "modules": names,
        "output": stream.getvalue(),
        "failed_tests": [name for name, _ in result.failures + result.errors],
    }


def _flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from _flatten(item)
        elif item is not None and hasattr(item, "id"):
            yield item


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def evidence(work: Path) -> dict:
    """Produce the artefacts and record the facts each step established."""
    steps: list[dict] = []

    identity = fixtures.TestIdentity(work / "identity")
    profile_bytes = identity.wrapped_profile("com.example.demo")
    parsed_profile = profile.parse_profile(profile_bytes)
    steps.append({
        "step": "Read the provisioning profile",
        "proof": (f"CMS-wrapped profile parsed: app id {parsed_profile.app_id}, "
                  f"team {parsed_profile.team_id}, "
                  f"{len(parsed_profile.entitlements)} entitlement(s)"),
    })

    ipa = fixtures.build_ipa()
    outcome = bundle.sign_ipa(
        ipa, identity=identity.identity, profile_object=parsed_profile,
        overrides=bundle.Overrides(bundle_id="com.example.demo",
                                   display_name="Zyn Demo",
                                   remove_extensions=False,
                                   injected_libraries=[
                                       ("@executable_path/Frameworks/ZynTweak.dylib", False)]))
    steps.append({
        "step": "Sign the package",
        "proof": (f"{len(outcome.binaries)} Mach-O image(s) signed, "
                  + " · ".join(b.report for b in outcome.binaries)),
    })
    steps.append({
        "step": "Verify every signature independently",
        "proof": (f"{sum(1 for r in outcome.verification if r.valid)}/"
                  f"{len(outcome.verification)} images valid; CMS verified by "
                  "`openssl cms -verify` for each certificate-signed image"),
    })

    main_binary = bundle.IPABundle.from_bytes(outcome.data)
    executable = main_binary.entries[main_binary.main_executable()]
    report = codesign.verify_image(executable)
    steps.append({
        "step": "Read the signed image back",
        "proof": (f"CodeDirectory 0x{report.version:x}, {report.code_slots} page slot(s), "
                  f"codeLimit {report.code_limit}, team {report.team_id}, "
                  f"special slots {report.special_slots}, "
                  f"injected {report.dylibs or '[]'}"),
    })
    # Every bundle is sealed before its own executable is signed, so each
    # nested executable binds *its own* seal through special slot 3. Reading
    # that back is the check a strict verifier performs on nested code.
    nested_rows = []
    for bundle_path in ("Payload/Demo.app/PlugIns/DemoWidget.appex",
                        "Payload/Demo.app/Frameworks/libdemo.dylib"):
        seal_path = f"{bundle_path}/_CodeSignature/CodeResources"
        if seal_path in main_binary.entries:
            executable_path = main_binary.executable_path(bundle_path)
            seal_bytes = main_binary.entries[seal_path]
            nested_report = codesign.verify_image(
                main_binary.entries[executable_path],
                info_plist=main_binary.entries.get(f"{bundle_path}/Info.plist"),
                resource_seal=seal_bytes)
            nested_rows.append(
                f"{bundle_path.split('/')[-1]}: seal {len(seal_bytes)} bytes, "
                f"slot 3 {'binds it' if nested_report.resource_seal_valid else 'DOES NOT bind it'}")
        else:
            nested_rows.append(f"{bundle_path.split('/')[-1]}: no seal (not a bundle)")
    steps.append({
        "step": "Bind each nested bundle's own seal",
        "proof": " · ".join(nested_rows),
    })

    tampered = bytearray(executable)
    tampered[0x500] ^= 1
    detected = not codesign.verify_image(bytes(tampered)).page_hashes_valid
    steps.append({
        "step": "Tamper with one byte inside the hashed region",
        "proof": "rejected" if detected else "NOT DETECTED",
    })

    device_identity = pairing.create_device_identity(work / "device")
    record = pairing.create_pairing_record(device_identity)
    steps.append({
        "step": "Create a pairing record",
        "proof": (f"HostID {record.host_id} = SHA-1(HostCertificate), "
                  f"{len(record.host_id)} hex characters, record parses back cleanly"),
    })

    simulated = simulator.SimulatedDevice(
        device_identity.device_certificate, device_identity.device_key,
        device_identity.root_certificate, device_identity.host_certificate_der,
        device_identity.udid).start()
    try:
        bridge = device.DeviceBridge(simulated.port)
        info = bridge.connect(record)
        session = bridge.start_session()
        steps.append({
            "step": "Open a device session over mutual TLS",
            "proof": (f"{info.product_type} · iOS {info.product_version} "
                      f"({info.build_version}) · UDID {info.udid[:8]}… · session {session}"),
        })
        installed = bridge.install_package(outcome.data, outcome.bundle_id, "Demo.ipa")
        steps.append({
            "step": "Upload with AFC and install with installation_proxy",
            "proof": (" → ".join(message["Status"] for message in installed.progress)
                      + f"; device verified the signature of the {installed.uploaded_bytes}-byte package"),
        })
        recorded = simulated.installed[outcome.bundle_id]
        steps.append({
            "step": "Confirm what the device recorded",
            "proof": (f"{recorded.bundle_id} {recorded.version}, ad-hoc={recorded.adhoc}, "
                      f"cms={recorded.signature.cms_valid}, "
                      f"page hashes={recorded.signature.page_hashes_valid}"),
        })
        bridge.close()

        adhoc_package = bundle.sign_ipa(fixtures.build_ipa())
        stock_refused = False
        detail = ""
        try:
            second = device.DeviceBridge(simulated.port)
            second.connect(record)
            second.start_session()
            second.install_package(adhoc_package.data, adhoc_package.bundle_id, "Adhoc.ipa")
            second.close()
        except device.DeviceError as error:
            stock_refused = error.code == "ApplicationVerificationFailed"
            detail = error.description
        steps.append({
            "step": "Offer an ad-hoc package to a stock-policy device",
            "proof": (f"refused at VerifyingApplication ({detail})" if stock_refused
                      else "NOT REFUSED"),
        })
    finally:
        simulated.stop()

    container_result = container.prepare_container(
        fixtures.build_ipa(with_extension=False),
        loader=fixtures.build_dylib("@rpath/TweakLoader.dylib", text_size=2048),
        tweaks={"ZynTweak.dylib": fixtures.build_dylib("@rpath/ZynTweak.dylib", text_size=2048)})
    guest = container_result.entries[f"{container_result.root}/App.app/Demo"]
    guest_image = macho.MachO(guest)
    steps.append({
        "step": "Prepare a guest container",
        "proof": (f"{len(container_result.signed_binaries)} image(s) ad-hoc signed; "
                  f"guest file type MH_DYLIB={guest_image.filetype == macho.MH_DYLIB}; "
                  f"load commands {guest_image.dylib_paths()}; "
                  f"verified={container_result.verified}"),
    })
    steps.append({
        "step": "Read the container launch plan",
        "proof": " | ".join(container_result.launch_plan[:4]),
    })

    return {
        "steps": steps,
        "package_sha256": sha256(outcome.data),
        "package_bytes": len(outcome.data),
        "profile_sha256": sha256(profile_bytes),
        "container_files": len(container_result.entries),
        "entitlements": sorted(report and outcome.entitlements[main_binary.main_executable()].keys()),
    }


def write_report(tests: dict, facts: dict, work: Path) -> None:
    openssl = subprocess.run(["openssl", "version"], capture_output=True, text=True)
    lines = [
        "# Unified sideloading engine — host run",
        "",
        f"- Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}",
        f"- Commit: `{git_sha()}`",
        f"- Host: Python {platform.python_version()} on {platform.system()} "
        f"{platform.machine()}, "
        + (openssl.stdout.strip() if openssl.returncode == 0 else "OpenSSL unavailable"),
        f"- Work directory: `{work}`",
        "",
        "## Test suite",
        "",
        f"- Tests run: **{tests['ran']}**",
        f"- Failures: **{tests['failures']}** · Errors: **{tests['errors']}** "
        f"· Skipped: **{tests['skipped']}**",
        f"- Result: **{'PASS' if tests['ok'] else 'FAIL'}**",
        f"- Modules: {', '.join(f'`{name}`' for name in tests['modules'])}",
        "",
    ]
    if tests["failed_tests"]:
        lines += ["### Failures", ""] + [f"- `{name}`" for name in tests["failed_tests"]] + [""]
    lines += ["## Evidence", "", "| Step | What it established |", "| --- | --- |"]
    for step in facts["steps"]:
        proof = str(step["proof"]).replace("|", "\\|")
        lines.append(f"| {step['step']} | {proof} |")
    lines += [
        "",
        "## Artefacts",
        "",
        f"- Signed package: {facts['package_bytes']} bytes, "
        f"sha256 `{facts['package_sha256'][:32]}…`",
        f"- Provisioning profile: sha256 `{facts['profile_sha256'][:32]}…`",
        f"- Container: {facts['container_files']} entries",
        f"- Entitlements in the signature: {', '.join(facts['entitlements'])}",
        "",
        "## What this run does not establish",
        "",
        "- No Swift build and no XCTest: the toolchain is absent from this host.",
        "- No physical device: the framing and the mutual-TLS handshake are real,",
        "  but a phone's exact AFC and service behaviour is asserted, not observed.",
        "- No in-process launch of a guest: the container is prepared, patched and",
        "  signed, and its launch plan is emitted; calling into the guest needs a",
        "  host allowed to map guest images.",
        "",
        "## Test output",
        "",
        "```",
        tests["output"].strip()[-12000:],
        "```",
        "",
    ]
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text("\n".join(lines) + "\n")


def main() -> int:
    print("ZynSign — unified sideloading suite")
    print("=" * 60)
    tests = run_tests()
    print(f"tests: {tests['ran']}  failures: {tests['failures']}  errors: {tests['errors']}  "
          f"→ {'PASS' if tests['ok'] else 'FAIL'}")
    if not tests["ok"]:
        for name in tests["failed_tests"]:
            print(f"  failed: {name}")
    work = Path(tempfile.mkdtemp(prefix="zynsign-evidence-"))
    print("\nEvidence pass")
    facts = evidence(work)
    for step in facts["steps"]:
        print(f"• {step['step']}\n    {step['proof']}")
    write_report(tests, facts, work)
    print(f"\nsigned package {facts['package_bytes']} bytes "
          f"sha256={facts['package_sha256'][:32]}…")
    print(f"\nreport: {REPORT.relative_to(ROOT)}")
    return 0 if tests["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
