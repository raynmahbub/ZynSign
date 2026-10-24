"""Deterministic test images: Mach-O slices, an IPA, and a signing identity.

The images are synthetic but structurally valid: a 64-bit header, a ``__TEXT``
segment with one section, a ``__LINKEDIT`` segment, and enough header padding
for the load commands signing adds. They are not runnable programs — nothing
here is executed — but they exercise every byte-level rule the signer and the
verifier implement, including page boundaries and the LINKEDIT growth rule.
"""

from __future__ import annotations

import io
import os
import plistlib
import struct
import subprocess
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

from . import cms, macho

ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64_ALL = 0
PAGE = 0x4000


def _fill(length: int, seed: int) -> bytes:
    """Deterministic, non-repeating bytes — page hashes depend on them."""
    return bytes(((index * 131 + seed * 17 + (index >> 8)) & 0xFF) for index in range(length))


def _segment(name: str, vm_address: int, vm_size: int, file_offset: int, file_size: int,
             sections: list[tuple[str, int, int, int]], initprot: int = 5) -> bytes:
    command_size = 72 + 80 * len(sections)
    body = bytearray(command_size)
    struct.pack_into("<II", body, 0, macho.LC_SEGMENT_64, command_size)
    body[8:8 + len(name)] = name.encode()
    struct.pack_into("<QQQQ", body, 24, vm_address, vm_size, file_offset, file_size)
    struct.pack_into("<iiII", body, 56, 5, initprot, len(sections), 0)
    for index, (section_name, address, size, offset) in enumerate(sections):
        start = 72 + index * 80
        body[start:start + len(section_name)] = section_name.encode()
        body[start + 16:start + 16 + len(name)] = name.encode()
        struct.pack_into("<QQIIIIIII", body, start + 32, address, size, offset, 4, 0, 0, 0x80000400, 0, 0)
        struct.pack_into("<I", body, start + 76, 0)
    return bytes(body)


def build_macho(
    *,
    filetype: int = macho.MH_EXECUTE,
    install_name: str = "@rpath/libdemo.dylib",
    text_offset: int = 0x400,
    text_size: int = PAGE - 0x400,
    payload_size: int = 0x80,
    encrypted: bool = False,
    position_independent: bool = True,
) -> bytes:
    """A thin arm64 image with ``text_offset`` bytes of header room."""
    text_file_size = text_offset + text_size
    total = text_file_size + payload_size
    commands = [
        _segment("__TEXT", 0, text_file_size, 0, text_file_size,
                 [("__text", text_offset, text_size, text_offset)]),
        _segment("__LINKEDIT", text_file_size, PAGE, text_file_size, payload_size, [], initprot=1),
    ]
    if filetype == macho.MH_DYLIB:
        name = install_name.encode() + b"\x00"
        size = macho.align(24 + len(name), 8)
        command = bytearray(size)
        struct.pack_into("<IIIIII", command, 0, macho.LC_ID_DYLIB, size, 24, 2, 0x00010000, 0x00010000)
        command[24:24 + len(name)] = name
        commands.append(bytes(command))
    else:
        commands.append(struct.pack("<IIQQ", 0x80000028, 24, 0, 0))  # LC_MAIN
    if encrypted:
        # LC_ENCRYPTION_INFO_64: cmd, cmdsize, cryptoff, cryptsize, cryptid, pad
        commands.append(struct.pack("<IIIIII", 0x2C, 24, text_offset, text_size, 1, 0))
    command_bytes = b"".join(commands)
    flags = 0x00200085
    if not position_independent:
        flags &= ~0x200000  # MH_PIE
    header = struct.pack(
        "<IiiIIIII", macho.MH_MAGIC_64, ARM64, CPU_SUBTYPE_ARM64_ALL, filetype,
        len(commands), len(command_bytes), flags, 0)
    if len(header) + len(command_bytes) > text_offset:
        raise ValueError("the fixtures' load commands do not fit before the text section")
    data = bytearray(total)
    data[0:len(header)] = header
    data[len(header):len(header) + len(command_bytes)] = command_bytes
    data[text_offset:text_offset + text_size] = _fill(text_size, seed=3)
    data[text_file_size:text_file_size + payload_size] = _fill(payload_size, seed=11)
    return bytes(data)


@dataclass
class AppBundle:
    """The files of an app, keyed by path inside the ``.app`` directory."""

    files: dict[str, bytes]
    executable: str
    identifier: str
    version: str
    display_name: str


def build_app(
    identifier: str = "com.example.demo",
    *,
    with_extension: bool = True,
    with_framework: bool = True,
    version: str = "1.0",
) -> AppBundle:
    files: dict[str, bytes] = {}
    executable = "Demo"
    files[executable] = build_macho(filetype=macho.MH_EXECUTE)
    if with_framework:
        files["Frameworks/libdemo.dylib"] = build_macho(
            filetype=macho.MH_DYLIB, install_name="@rpath/libdemo.dylib")
    if with_extension:
        files["PlugIns/DemoWidget.appex/DemoWidget"] = build_macho(filetype=macho.MH_EXECUTE)
        files["PlugIns/DemoWidget.appex/Info.plist"] = plistlib.dumps({
            "CFBundleIdentifier": f"{identifier}.widget",
            "CFBundleExecutable": "DemoWidget",
            "CFBundlePackageType": "XPC!",
            "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
        })
    files["Assets.car"] = _fill(512, seed=5)
    files["en.lproj/Localizable.strings"] = b'"hello" = "Hello";\n'
    files["Info.plist"] = plistlib.dumps({
        "CFBundleIdentifier": identifier,
        "CFBundleExecutable": executable,
        "CFBundleName": "Demo",
        "CFBundleDisplayName": "Demo",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "1",
        "CFBundlePackageType": "APPL",
        "MinimumOSVersion": "14.0",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "UIDeviceFamily": [1, 2],
        "LSRequiresIPhoneOS": True,
        "CFBundleURLTypes": [{
            "CFBundleURLName": identifier,
            "CFBundleURLSchemes": ["zyndemo"],
        }],
    })
    return AppBundle(files, executable, identifier, version, "Demo")


def build_executable(*, encrypted: bool = False, position_independent: bool = True) -> bytes:
    return build_macho(filetype=macho.MH_EXECUTE, encrypted=encrypted,
                       position_independent=position_independent)


def build_dylib(install_name: str = "@rpath/libdemo.dylib", *, text_size: int = PAGE - 0x400,
                text_offset: int = 0x400) -> bytes:
    return build_macho(filetype=macho.MH_DYLIB, install_name=install_name,
                       text_size=text_size, text_offset=text_offset)


def app_info(identifier: str, name: str, executable: str) -> bytes:
    return plistlib.dumps({
        "CFBundleIdentifier": identifier,
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundleExecutable": executable,
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "CFBundlePackageType": "APPL",
        "MinimumOSVersion": "14.0",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "UIDeviceFamily": [1],
    })


def build_ipa(bundle: AppBundle | None = None, *, with_extension: bool = True,
              with_watch: bool = False, with_framework: bool = True,
              bundle_id: str | None = None,
              extra: dict[str, bytes] | None = None) -> bytes:
    """A stored ZIP with ``Payload/<Name>.app`` — the shape an IPA has."""
    if bundle is None:
        bundle = build_app(identifier=bundle_id or "com.example.demo",
                           with_extension=with_extension, with_framework=with_framework)
        if with_watch:
            bundle.files["Watch/WatchDemo.app/WatchDemo"] = build_macho(filetype=macho.MH_EXECUTE)
            bundle.files["Watch/WatchDemo.app/Info.plist"] = app_info(
                f"{bundle.identifier}.watchkitapp", "WatchDemo", "WatchDemo")
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for path, content in bundle.files.items():
            info = zipfile.ZipInfo(f"Payload/Demo.app/{path}", date_time=(2024, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, content)
        for path, content in (extra or {}).items():
            info = zipfile.ZipInfo(f"Payload/Demo.app/{path}", date_time=(2024, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, content)
    return buffer.getvalue()


def read_ipa(data: bytes) -> dict[str, bytes]:
    entries: dict[str, bytes] = {}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for info in archive.infolist():
            if info.is_dir():
                continue
            entries[info.filename] = archive.read(info)
    return entries


def write_ipa(entries: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(entries):
            info = zipfile.ZipInfo(path, date_time=(2024, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, entries[path])
    return buffer.getvalue()


# MARK: - Identities


@dataclass
class TestIdentity:
    """A self-signed RSA identity plus the provisioning profile it authorises."""

    directory: Path
    key_path: Path
    certificate_path: Path
    certificate_der: bytes
    p12_path: Path
    team_identifier: str = "ZYNTEAM1A2"
    _profiles: dict[str, bytes] = field(default_factory=dict)

    def __init__(self, directory: Path, team: str = "ZYNTEAM1A2"):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self._profiles = {}
        self.team_identifier = team
        self.key_path = self.directory / "signer.key.pem"
        self.certificate_path = self.directory / "signer.cert.pem"
        self.p12_path = self.directory / "signer.p12"
        if not self.key_path.exists():
            subprocess.run(
                ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                 "-keyout", str(self.key_path), "-out", str(self.certificate_path),
                 "-days", "30", "-subj", f"/CN=ZynSign Development/O={team}/OU={team}",
                 "-addext", "basicConstraints=critical,CA:false",
                 "-addext", "keyUsage=critical,digitalSignature",
                 "-addext", "extendedKeyUsage=codeSigning"],
                check=True, capture_output=True)
            subprocess.run(
                ["openssl", "pkcs12", "-export", "-inkey", str(self.key_path),
                 "-in", str(self.certificate_path), "-out", str(self.p12_path),
                 "-passout", "pass:"],
                check=True, capture_output=True)
        self.certificate_der = subprocess.run(
            ["openssl", "x509", "-in", str(self.certificate_path), "-outform", "DER"],
            check=True, capture_output=True).stdout

    @property
    def identity(self) -> cms.CertificateIdentity:
        return cms.CertificateIdentity(self.certificate_der, self.key_path)

    def profile_plist(self, bundle_id: str = "com.example.demo") -> dict:
        return {
            "AppIDName": bundle_id,
            "Name": f"ZynSign Development {bundle_id}",
            "TeamIdentifier": [self.team_identifier],
            "TeamName": "ZynSign Development",
            "UUID": "B1C2D3E4-0000-4000-8000-000000000001",
            "CreationDate": "2024-01-01T00:00:00Z",
            "ExpirationDate": "2030-01-01T00:00:00Z",
            "Platform": ["iOS"],
            "ProvisionedDevices": ["0000803000000000000000000000000000000000"],
            "Entitlements": {
                "application-identifier": f"{self.team_identifier}.{bundle_id}",
                "com.apple.developer.team-identifier": self.team_identifier,
                "get-task-allow": True,
                "keychain-access-groups": [f"{self.team_identifier}.{bundle_id}"],
                "aps-environment": "development",
                "beta-reports-active": True,
            },
        }

    def wrapped_profile(self, bundle_id: str = "com.example.demo") -> bytes:
        """A profile as it ships: a plist inside a CMS SignedData.

        Cached per application identifier: a wildcard profile and a concrete
        one are different documents, and returning the first one for both is
        how a test starts proving the wrong thing.
        """
        if bundle_id not in self._profiles:
            payload = plistlib.dumps(self.profile_plist(bundle_id), fmt=plistlib.FMT_XML)
            self._profiles[bundle_id] = cms.sign_attached(payload, self.identity)
        return self._profiles[bundle_id]
