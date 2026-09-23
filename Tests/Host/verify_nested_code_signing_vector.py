#!/usr/bin/env python3
"""Independent nested code signing checks and vector verification.

Uses Python's standard library and host OpenSSL only.
This is a development check for ZS-028 nested signing, never a product runtime subprocess.
Does not claim execution of Swift or Apple validation.
"""
import base64
import hashlib
from pathlib import Path
import re
import struct
import subprocess
import tempfile


def test_dependency_order():
    """Verifies that dependency graphs order innermost nested code before containers."""
    # Synthetic items:
    # App (root)
    # Framework One (Frameworks/One.framework) -> depends on App
    # Framework Two (Frameworks/One.framework/Frameworks/Two.framework) -> depends on One
    # Dynamic library Loose (Frameworks/Loose.dylib) -> depends on App
    # App Extension Widget (PlugIns/Widget.appex) -> depends on App
    nodes = [
        "",
        "Frameworks/One.framework",
        "Frameworks/One.framework/Frameworks/Two.framework",
        "Frameworks/Loose.dylib",
        "PlugIns/Widget.appex"
    ]
    edges = [
        ("Frameworks/One.framework/Frameworks/Two.framework", "Frameworks/One.framework"),
        ("Frameworks/One.framework", ""),
        ("Frameworks/Loose.dylib", ""),
        ("PlugIns/Widget.appex", "")
    ]
    # In topological sort with tie-breaking by location:
    # Two must precede One.
    # One, Loose, Widget must precede "" (App).
    prereqs = {n: set() for n in nodes}
    for child, parent in edges:
        prereqs[parent].add(child)

    order = []
    emitted = set()
    while len(order) < len(nodes):
        ready = sorted([n for n in nodes if n not in emitted and prereqs[n].issubset(emitted)])
        assert ready, "Dependency cycle detected"
        next_node = ready[0]
        emitted.add(next_node)
        order.append(next_node)

    assert order[-1] == "", "Application must be the final node"
    assert order.index("Frameworks/One.framework/Frameworks/Two.framework") < order.index("Frameworks/One.framework")
    assert order.index("Frameworks/One.framework") < order.index("")
    assert order.index("Frameworks/Loose.dylib") < order.index("")
    assert order.index("PlugIns/Widget.appex") < order.index("")

    # Nested signing items only (excluding root app):
    nested_steps = [n for n in order if n != ""]
    assert len(nested_steps) == 4
    assert nested_steps[0] == "Frameworks/Loose.dylib" or nested_steps[0] == "Frameworks/One.framework/Frameworks/Two.framework"
    print("PASS: deterministic dependency ordering and tie-breaking verified")


def test_nested_macho_vector_and_openssl():
    """Verifies the Mach-O signing vector and detached CMS signature with OpenSSL."""
    fixture_path = Path(__file__).resolve().parents[1] / "ZynSignTests/Support/MachOSigningFixtures.swift"
    fixture = fixture_path.read_text()
    values = {name: base64.b64decode(text) for name, text in re.findall(
        r'static let (\w+): Data = decode\("""(.*?)"""\)', fixture, re.S)}

    source = values["unsignedMachO"]
    output = values["expectedSignedMachO"]
    cd = values["codeDirectory"]
    cms = values["cms"]

    # Structural verification of output:
    cmd, size, offset, reserve = struct.unpack_from("<4I", output, 256)
    assert (cmd, size, offset, reserve) == (0x1D, 16, 4144, 1376)
    assert offset == 4144
    assert len(output) == offset + reserve

    # Non-signature load commands and executable text section preservation:
    # Text section is from 0 to 4096. Bytes in __text (after headers up to 4096) must be identical:
    assert source[272:4096] == output[272:4096], "Executable code bytes must be identical"

    # OpenSSL verification:
    with tempfile.TemporaryDirectory(prefix="zynsign-nested-vector-") as temp:
        root = Path(temp)
        (root / "cms.der").write_bytes(cms)
        (root / "cd.bin").write_bytes(cd)
        command = [
            "openssl", "cms", "-verify", "-binary", "-inform", "DER",
            "-in", str(root / "cms.der"), "-content", str(root / "cd.bin"),
            "-noverify", "-out", str(root / "verified.bin")
        ]
        checked = subprocess.run(command, capture_output=True)
        assert checked.returncode == 0, f"OpenSSL CMS verification failed: {checked.stderr.decode()}"
        assert (root / "verified.bin").read_bytes() == cd
    print("PASS: nested Mach-O binary byte-preservation and OpenSSL CMS verification")


def test_cycle_detection():
    """Verifies that cyclic dependency graphs are detected and refused."""
    nodes = ["Frameworks/A.framework", "Frameworks/B.framework"]
    edges = [
        ("Frameworks/A.framework", "Frameworks/B.framework"),
        ("Frameworks/B.framework", "Frameworks/A.framework")
    ]
    prereqs = {n: set() for n in nodes}
    for child, parent in edges:
        prereqs[parent].add(child)

    emitted = set()
    order = []
    while len(order) < len(nodes):
        ready = [n for n in nodes if n not in emitted and prereqs[n].issubset(emitted)]
        if not ready:
            break
        order.append(ready[0])
        emitted.add(ready[0])

    assert len(order) < len(nodes), "Cycle should prevent topological ordering"
    print("PASS: dependency cycle detection verified")


def main():
    test_dependency_order()
    test_nested_macho_vector_and_openssl()
    test_cycle_detection()
    print("ALL PASS: host nested code signing vector verification completed")


if __name__ == "__main__":
    main()
