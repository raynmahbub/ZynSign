#!/usr/bin/env python3
"""External validation harness (ZS-031): ZynSign output judged by Apple tooling.

Until this harness, only ZynSign had checked ZynSign's signatures. The harness
hands the artifacts that `ExternalValidationExportTests` writes to Apple's
developer tooling on a macOS host -- `codesign`, `otool`, `ditto`, `unzip` --
and to OpenSSL, signs the same unsigned inputs with `codesign` itself for a
reference comparison, and records every verdict in a JSON and a Markdown
report.

It measures; it does not judge. A `codesign` rejection is a finding, not a
harness failure: the harness exits non-zero only when it could not do its job
(no export, a failed export step, a missing tool, an unreadable artifact).
Nothing here is iOS platform acceptance, trust evaluation, or
installability. `codesign` on macOS is Apple's desktop verifier, not the
device's, and the iOS rules checked below are the ones Apple documents, not
everything a device enforces.

Developer-side validation tooling only (architecture decision 15): never a
product runtime subprocess. Python standard library only.

Subcommands:
  run                  analyze an export directory (macOS with Xcode)
  self-test            check parsing, rules, and rendering on any host
  annotate-xcodebuild  surface xcodebuild errors as workflow annotations
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import platform
import plistlib
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPORT_SCHEMA = 1

APPLE_FORMAT_DOC = (
    "https://developer.apple.com/documentation/xcode/"
    "using-the-latest-code-signature-format"
)

EVIDENCE_STATEMENT = (
    "Verdicts come from Apple's desktop developer tooling and OpenSSL on a "
    "hosted macOS runner. `codesign` acceptance is not iOS acceptance, trust "
    "evaluation, or installability, and the iOS rules below are only the "
    "format requirements Apple documents. The throwaway signing certificate "
    "is self-signed and untrusted by design."
)

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGICS = {0xCAFEBABE, 0xCAFEBABF}
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_REQUIREMENTS = 0xFADE0C01
CS_ADHOC = 0x2

LOAD_COMMAND_NAMES = {
    0x2: "LC_SYMTAB", 0xB: "LC_DYSYMTAB", 0xC: "LC_LOAD_DYLIB",
    0x24: "LC_VERSION_MIN_MACOSX", 0x25: "LC_VERSION_MIN_IPHONEOS",
    0x2F: "LC_VERSION_MIN_TVOS", 0x30: "LC_VERSION_MIN_WATCHOS",
    0xD: "LC_ID_DYLIB", 0xE: "LC_LOAD_DYLINKER", 0x19: "LC_SEGMENT_64",
    0x1B: "LC_UUID", 0x1D: "LC_CODE_SIGNATURE", 0x26: "LC_FUNCTION_STARTS",
    0x29: "LC_DATA_IN_CODE", 0x2A: "LC_SOURCE_VERSION", 0x2C: "LC_ENCRYPTION_INFO_64",
    0x32: "LC_BUILD_VERSION", 0x80000028: "LC_MAIN",
    0x80000033: "LC_DYLD_EXPORTS_TRIE", 0x80000034: "LC_DYLD_CHAINED_FIXUPS",
}

PLATFORM_COMMANDS = {
    "LC_BUILD_VERSION", "LC_VERSION_MIN_MACOSX", "LC_VERSION_MIN_IPHONEOS",
    "LC_VERSION_MIN_TVOS", "LC_VERSION_MIN_WATCHOS",
}

INPUT_DEPENDENT_NOTE = (
    "codesign's choice for an input that declares no platform or minimum OS "
    "(no LC_BUILD_VERSION); not evidence about ZynSign"
)

BLOB_TYPE_NAMES = {
    0: "CodeDirectory", 2: "Requirements", 3: "ResourceDirectory",
    4: "Application", 5: "Entitlements", 6: "RepSpecific",
    7: "DEREntitlements", 0x10000: "CMS", 0x10001: "Identification",
    0x10002: "Ticket",
}
for _index in range(5):
    BLOB_TYPE_NAMES[0x1000 + _index] = f"AlternateCodeDirectory{_index}"

SPECIAL_SLOT_NAMES = {
    1: "Info.plist", 2: "Requirements", 3: "CodeResources", 4: "Application",
    5: "Entitlements", 6: "RepSpecific", 7: "DEREntitlements",
    8: "LaunchConstraintSelf", 9: "LaunchConstraintParent",
    10: "LaunchConstraintResponsible", 11: "LibraryConstraint",
}

HASH_TYPE_NAMES = {1: "sha1", 2: "sha256", 3: "sha256-truncated", 4: "sha384"}

REQUIREMENT_TYPE_NAMES = {1: "host", 2: "guest", 3: "designated", 4: "library", 5: "plugin"}

OUTPUT_LIMIT = 6000


class FormatError(Exception):
    """An artifact that is not the shape this harness parses."""


# --------------------------------------------------------------------------
# Signature format parsing (independent of ZynSign's Swift parser)
# --------------------------------------------------------------------------

def _unpack(fmt: str, data: bytes, offset: int) -> tuple:
    size = struct.calcsize(fmt)
    if offset < 0 or offset + size > len(data):
        raise FormatError(f"read of {size} bytes at {offset} is out of bounds")
    return struct.unpack_from(fmt, data, offset)


def _has_nonzero(hex_digest: str) -> bool:
    return any(character != "0" for character in hex_digest)


def parse_code_directory(blob: bytes) -> dict:
    """Parses one CodeDirectory blob, version-aware, big-endian."""
    (magic, length, version, flags, hash_offset, ident_offset,
     special_count, code_count, code_limit) = _unpack(">9I", blob, 0)
    hash_size, hash_type, platform_byte, page_log2 = _unpack(">4B", blob, 36)
    if magic != CSMAGIC_CODEDIRECTORY:
        raise FormatError(f"CodeDirectory magic is {magic:#010x}")
    if length < 44 or length > len(blob):
        raise FormatError("CodeDirectory length is out of bounds")
    blob = blob[:length]

    def cstring(offset: int) -> str:
        if not 0 < offset < length:
            raise FormatError("CodeDirectory string offset is out of bounds")
        end = blob.find(b"\0", offset)
        if end < 0:
            raise FormatError("CodeDirectory string is unterminated")
        return blob[offset:end].decode("utf-8", "replace")

    result = {
        "version": version,
        "versionHex": f"{version:x}",
        "flags": flags,
        "flagsHex": f"{flags:#x}",
        "identifier": cstring(ident_offset),
        "teamIdentifier": None,
        "specialSlotCount": special_count,
        "codeSlotCount": code_count,
        "codeLimit": code_limit,
        "hashSize": hash_size,
        "hashType": HASH_TYPE_NAMES.get(hash_type, str(hash_type)),
        "platform": platform_byte,
        "pageSize": (1 << page_log2) if page_log2 else 0,
        "execSegment": None,
        "runtime": None,
    }
    if version >= 0x20200 and length >= 52:
        team_offset = _unpack(">I", blob, 48)[0]
        if team_offset:
            result["teamIdentifier"] = cstring(team_offset)
    if version >= 0x20300 and length >= 64:
        code_limit_64 = _unpack(">Q", blob, 56)[0]
        if code_limit_64:
            result["codeLimit64"] = code_limit_64
    if version >= 0x20400 and length >= 88:
        base, limit, segment_flags = _unpack(">3Q", blob, 64)
        result["execSegment"] = {
            "base": base, "limit": limit,
            "flags": segment_flags, "flagsHex": f"{segment_flags:#x}",
        }
    if version >= 0x20500 and length >= 96:
        result["runtime"] = _unpack(">I", blob, 88)[0]
    special = {}
    for index in range(1, special_count + 1):
        start = hash_offset - index * hash_size
        if start < 0 or start + hash_size > length:
            raise FormatError("CodeDirectory special slot is out of bounds")
        special[index] = blob[start:start + hash_size].hex()
    if hash_offset + code_count * hash_size > length:
        raise FormatError("CodeDirectory code slots are out of bounds")
    result["specialSlots"] = {f"-{index}": digest for index, digest in sorted(special.items())}
    result["presentSpecialSlots"] = [
        -index for index, digest in sorted(special.items()) if _has_nonzero(digest)
    ]
    return result


def parse_requirements_set(blob: bytes) -> dict:
    magic, length, count = _unpack(">3I", blob, 0)
    if magic != CSMAGIC_REQUIREMENTS:
        return {"magicHex": f"{magic:#010x}", "parsed": False}
    kinds = []
    for index in range(count):
        kind, _offset = _unpack(">2I", blob, 12 + 8 * index)
        kinds.append(REQUIREMENT_TYPE_NAMES.get(kind, str(kind)))
    return {"parsed": True, "length": length, "count": count, "kinds": kinds}


def parse_superblob(data: bytes, offset: int, size: int) -> tuple[dict, dict]:
    """Parses the embedded-signature SuperBlob; returns (summary, raw blobs)."""
    magic, length, count = _unpack(">3I", data, offset)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        raise FormatError(f"SuperBlob magic is {magic:#010x}")
    if length < 12 + 8 * count or length > size or offset + length > len(data):
        raise FormatError("SuperBlob length is out of bounds")
    entries = []
    raw: dict[int, bytes] = {}
    for index in range(count):
        blob_type, blob_offset = _unpack(">2I", data, offset + 12 + 8 * index)
        if blob_offset + 8 > length:
            raise FormatError("SuperBlob entry offset is out of bounds")
        start = offset + blob_offset
        blob_magic, blob_length = _unpack(">2I", data, start)
        if blob_length < 8 or blob_offset + blob_length > length:
            raise FormatError("SuperBlob entry length is out of bounds")
        raw[blob_type] = data[start:start + blob_length]
        entries.append({
            "type": blob_type,
            "typeHex": f"{blob_type:#x}",
            "name": BLOB_TYPE_NAMES.get(blob_type, f"{blob_type:#x}"),
            "magicHex": f"{blob_magic:#010x}",
            "length": blob_length,
        })
    trailing = data[offset + length:offset + size]
    summary = {
        "length": length,
        "count": count,
        "entries": entries,
        "reservedBytes": size - length,
        "trailingBytesAllZero": all(byte == 0 for byte in trailing),
        "codeDirectories": [],
    }
    for blob_type in sorted(raw):
        if blob_type == 0 or 0x1000 <= blob_type < 0x1005:
            directory = parse_code_directory(raw[blob_type])
            directory["slot"] = blob_type
            directory["sha256"] = hashlib.sha256(raw[blob_type]).hexdigest()
            summary["codeDirectories"].append(directory)
    if 0x10000 in raw:
        summary["cmsBytes"] = len(raw[0x10000]) - 8
    if 5 in raw:
        summary["entitlementsXML"] = raw[5][8:].decode("utf-8", "replace")[:OUTPUT_LIMIT]
    if 7 in raw:
        summary["derEntitlementsBytes"] = len(raw[7]) - 8
    if 2 in raw:
        summary["requirements"] = parse_requirements_set(raw[2])
    return summary, raw


def parse_macho(data: bytes) -> tuple[dict, dict]:
    """Parses a thin 64-bit little-endian Mach-O; returns (summary, raw blobs)."""
    if len(data) < 32:
        raise FormatError("file is too small to be Mach-O")
    if _unpack(">I", data, 0)[0] in FAT_MAGICS:
        raise FormatError("universal (fat) Mach-O is outside this harness's parser")
    (magic, cpu, subtype, file_type, command_count, commands_size,
     flags, _reserved) = _unpack("<8I", data, 0)
    if magic != MH_MAGIC_64:
        raise FormatError(f"not a thin 64-bit little-endian Mach-O (magic {magic:#010x})")
    end = 32 + commands_size
    if end > len(data):
        raise FormatError("load commands exceed the file")
    offset = 32
    commands = []
    segments = []
    code_signature = None
    for _ in range(command_count):
        command, command_size = _unpack("<2I", data, offset)
        if command_size < 8 or offset + command_size > end:
            raise FormatError("load command size is out of bounds")
        commands.append(LOAD_COMMAND_NAMES.get(command, f"{command:#x}"))
        if command == LC_SEGMENT_64:
            if command_size < 72:
                raise FormatError("segment command is truncated")
            name = data[offset + 8:offset + 24].rstrip(b"\0").decode("ascii", "replace")
            vm_address, vm_size, file_offset, file_size = _unpack("<4Q", data, offset + 24)
            _max_protection, _initial_protection, section_count, _flags = _unpack(
                "<4I", data, offset + 56)
            segments.append({
                "name": name, "fileoff": file_offset, "filesize": file_size,
                "vmaddr": vm_address, "vmsize": vm_size, "sections": section_count,
            })
        elif command == LC_CODE_SIGNATURE:
            if command_size < 16:
                raise FormatError("code signature command is truncated")
            data_offset, data_size = _unpack("<2I", data, offset + 8)
            code_signature = {"dataoff": data_offset, "datasize": data_size}
        offset += command_size
    summary = {
        "container": "thin",
        "cpuType": cpu,
        "cpuSubtype": subtype,
        "fileType": file_type,
        "headerFlagsHex": f"{flags:#x}",
        "loadCommands": commands,
        "segments": segments,
        "codeSignature": code_signature,
        "fileSize": len(data),
        "signature": None,
    }
    raw: dict[int, bytes] = {}
    if code_signature is not None:
        summary["signature"], raw = parse_superblob(
            data, code_signature["dataoff"], code_signature["datasize"])
    return summary, raw


def primary_code_directory(summary: dict | None) -> dict | None:
    if not summary or not summary.get("signature"):
        return None
    for directory in summary["signature"]["codeDirectories"]:
        if directory["slot"] == 0:
            return directory
    return None


def declares_platform(summary: dict | None) -> bool:
    """Whether a parsed image carries a platform / minimum-OS load command."""
    return bool(summary) and any(command in PLATFORM_COMMANDS
                                 for command in summary.get("loadCommands", []))


# --------------------------------------------------------------------------
# Rules and structural checks
# --------------------------------------------------------------------------

def _rule(rule_id: str, requirement: str, result: str, detail: str) -> dict:
    return {
        "id": rule_id, "requirement": requirement, "result": result,
        "detail": detail, "source": APPLE_FORMAT_DOC,
    }


def ios_format_rules(summary: dict | None, role: str) -> list[dict]:
    """Apple-documented iOS 15+ signature-format requirements (APPLE_FORMAT_DOC).

    R1 and R2 come from "Using the latest code signature format"; R3 from its
    instruction not to include entitlements when signing frameworks. They are
    the documented floor, not everything a device enforces.
    """
    directory = primary_code_directory(summary)
    if directory is None:
        return [_rule("R1", "CodeDirectory version is at least 0x20400",
                      "not-evaluated", "no CodeDirectory")]
    rules = [_rule(
        "R1", "CodeDirectory version is at least 0x20400",
        "pass" if directory["version"] >= 0x20400 else "fail",
        f"v={directory['versionHex']}",
    )]
    present = set(directory["presentSpecialSlots"])
    if -5 in present:
        rules.append(_rule(
            "R2", "DER entitlements (slot -7) accompany XML entitlements (slot -5)",
            "pass" if -7 in present else "fail",
            "slot -7 present" if -7 in present else "slot -5 present, slot -7 absent",
        ))
    else:
        rules.append(_rule(
            "R2", "DER entitlements (slot -7) accompany XML entitlements (slot -5)",
            "not-applicable", "no XML entitlements (slot -5)",
        ))
    if role == "framework":
        entry_types = {entry["type"] for entry in summary["signature"]["entries"]}
        carries = bool({-5, -7} & present) or bool({5, 7} & entry_types)
        rules.append(_rule(
            "R3", "a framework's signature carries no entitlements",
            "fail" if carries else "pass",
            "entitlements present" if carries else "no entitlements",
        ))
    return rules


def _check(check_id: str, description: str, passed: bool | None, detail: str) -> dict:
    if passed is None:
        result = "not-evaluated"
    else:
        result = "pass" if passed else "fail"
    return {"id": check_id, "check": description, "result": result, "detail": detail}


def layout_checks(summary: dict, otool_commands: list[dict] | None,
                  expected_offset: int | None) -> list[dict]:
    """E5: the signature region's placement, cross-checked against otool."""
    signature_command = summary.get("codeSignature")
    if signature_command is None:
        return [_check("E5-1", "LC_CODE_SIGNATURE is present", False, "absent")]
    size = summary["fileSize"]
    data_offset = signature_command["dataoff"]
    data_size = signature_command["datasize"]
    linkedit = next((segment for segment in summary["segments"]
                     if segment["name"] == "__LINKEDIT"), None)
    checks = [
        _check("E5-1", "signature data offset is 16-byte aligned",
               data_offset % 16 == 0, f"dataoff={data_offset}"),
        _check("E5-2", "signature region ends at the end of the file",
               data_offset + data_size == size,
               f"dataoff+datasize={data_offset + data_size}, file={size}"),
        _check("E5-3", "__LINKEDIT ends at the end of the file",
               None if linkedit is None else linkedit["fileoff"] + linkedit["filesize"] == size,
               "no __LINKEDIT" if linkedit is None else
               f"fileoff+filesize={linkedit['fileoff'] + linkedit['filesize']}, file={size}"),
    ]
    directory = primary_code_directory(summary)
    if directory is not None:
        checks.append(_check(
            "E5-4", "CodeDirectory code limit equals the signature offset",
            directory["codeLimit"] == data_offset,
            f"codeLimit={directory['codeLimit']}, dataoff={data_offset}"))
    if otool_commands is not None:
        otool_signature = next((command for command in otool_commands
                                if command.get("cmd") == "LC_CODE_SIGNATURE"), None)
        if otool_signature is None:
            checks.append(_check("E5-5", "otool reports the same LC_CODE_SIGNATURE",
                                 False, "otool reports no LC_CODE_SIGNATURE"))
        else:
            reported = (_int(otool_signature.get("dataoff")), _int(otool_signature.get("datasize")))
            checks.append(_check("E5-5", "otool reports the same LC_CODE_SIGNATURE",
                                 reported == (data_offset, data_size),
                                 f"otool dataoff={reported[0]} datasize={reported[1]}"))
        otool_linkedit = next((command for command in otool_commands
                               if command.get("segname") == "__LINKEDIT"), None)
        if linkedit is not None and otool_linkedit is not None:
            reported = (_int(otool_linkedit.get("fileoff")), _int(otool_linkedit.get("filesize")))
            checks.append(_check("E5-6", "otool reports the same __LINKEDIT extent",
                                 reported == (linkedit["fileoff"], linkedit["filesize"]),
                                 f"otool fileoff={reported[0]} filesize={reported[1]}"))
    if expected_offset is not None:
        checks.append(_check("E5-7", "ZynSign's recorded signature offset matches the file",
                             expected_offset == data_offset,
                             f"recorded={expected_offset}, file={data_offset}"))
    return checks


def _int(text) -> int | None:
    if text is None:
        return None
    try:
        return int(str(text).split()[0], 0)
    except ValueError:
        return None


# --------------------------------------------------------------------------
# Tool output parsing
# --------------------------------------------------------------------------

def parse_otool_load_commands(text: str) -> list[dict]:
    """Parses `otool -l` output into one dictionary per load command.

    Segment-level keys precede section blocks, so the first occurrence of a
    key is the load command's own value.
    """
    commands = []
    for block in re.split(r"^Load command \d+\s*$", text, flags=re.M)[1:]:
        values: dict[str, str] = {}
        for line in block.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[0] not in values:
                values[parts[0]] = parts[1].strip()
        commands.append(values)
    return commands


def parse_codesign_display(text: str) -> dict:
    """Parses `codesign --display --verbose=4` output."""
    fields: dict = {}
    match = re.search(
        r"CodeDirectory v=([0-9a-fA-F]+) size=(\d+) flags=(0x[0-9a-fA-F]+)\(([^)]*)\) "
        r"hashes=(\d+)\+(\d+)", text)
    if match:
        fields["codeDirectoryVersion"] = match.group(1)
        fields["codeDirectorySize"] = int(match.group(2))
        fields["flags"] = match.group(3)
        fields["flagNames"] = match.group(4)
        fields["codeSlots"] = int(match.group(5))
        fields["specialSlots"] = int(match.group(6))
    for key in ("Identifier", "Format", "TeamIdentifier", "Info.plist",
                "Sealed Resources", "Signature", "Signature size", "Hash type",
                "Hash choices", "Runtime Version", "Signed Time", "Timestamp",
                "Internal requirements count"):
        # codesign writes both "Key=value" and "Key value=..." forms, e.g.
        # "Info.plist=not bound" and "Info.plist entries=6".
        found = re.search(rf"^{re.escape(key)}[= ](.*)$", text, re.M)
        if found:
            fields[key] = found.group(1).strip()
    authorities = re.findall(r"^Authority=(.*)$", text, re.M)
    if authorities:
        fields["Authority"] = authorities
    return fields


def summarize_codesign(output: str) -> str:
    """The distinct verdict messages of a codesign run, without paths."""
    messages = []
    for line in output.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("--") or stripped.startswith("In architecture"):
            continue
        message = stripped.split(": ", 1)[1] if ": " in stripped else stripped
        if message not in messages:
            messages.append(message)
    return "; ".join(messages[:3])


XCODEBUILD_ERROR = re.compile(
    r"^(?P<file>/[^:]+):(?P<line>\d+):(?:(?P<column>\d+):)? "
    r"(?:fatal )?error: (?P<message>.*)$")


def xcodebuild_annotations(log: str, workspace: str | None, limit: int = 10) -> list[str]:
    """Workflow `::error` commands for the distinct errors in an xcodebuild log."""
    annotations = []
    seen = set()
    for line in log.splitlines():
        match = XCODEBUILD_ERROR.match(line.strip())
        if not match:
            continue
        key = (match["file"], match["line"], match["message"])
        if key in seen:
            continue
        seen.add(key)
        path = match["file"]
        if workspace and path.startswith(workspace.rstrip("/") + "/"):
            path = path[len(workspace.rstrip("/")) + 1:]
        properties = f"file={_escape_property(path)},line={match['line']}"
        if match["column"]:
            properties += f",col={match['column']}"
        annotations.append(f"::error {properties}::{_escape_data(match['message'])}")
        if len(annotations) >= limit:
            break
    return annotations


def _escape_data(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _escape_property(text: str) -> str:
    return _escape_data(text).replace(":", "%3A").replace(",", "%2C")


# --------------------------------------------------------------------------
# Tools
# --------------------------------------------------------------------------

class Tools:
    """Resolved paths of the external tools; None marks a tool as unavailable."""

    NAMES = ("codesign", "otool", "ditto", "unzip")

    def __init__(self, paths: dict[str, str | None], openssl: str | None):
        self.paths = paths
        self.openssl = openssl

    @classmethod
    def discover(cls) -> "Tools":
        return cls({name: shutil.which(name) for name in cls.NAMES}, _find_openssl())

    @classmethod
    def unavailable(cls) -> "Tools":
        return cls({name: None for name in cls.NAMES}, None)

    def path(self, name: str) -> str | None:
        return self.paths.get(name)


def _find_openssl() -> str | None:
    candidates = []
    if os.environ.get("ZYNSIGN_OPENSSL"):
        candidates.append(os.environ["ZYNSIGN_OPENSSL"])
    candidates += ["/opt/homebrew/opt/openssl@3/bin/openssl",
                   "/usr/local/opt/openssl@3/bin/openssl"]
    found = shutil.which("openssl")
    if found:
        candidates.append(found)
    for candidate in dict.fromkeys(candidates):
        if not Path(candidate).exists():
            continue
        probe = _execute([candidate, "cms", "-help"])
        text = probe["output"].lower()
        if probe["exitCode"] == 0 and "invalid command" not in text:
            return candidate
    return None


def _execute(arguments: list[str], timeout: int = 180) -> dict:
    command = " ".join(shlex.quote(argument) for argument in arguments)
    try:
        completed = subprocess.run(arguments, capture_output=True, text=True,
                                   errors="replace", timeout=timeout)
    except FileNotFoundError:
        return {"command": command, "exitCode": None, "output": "tool not found"}
    except subprocess.TimeoutExpired:
        return {"command": command, "exitCode": None, "output": f"timed out after {timeout}s"}
    output = (completed.stdout + completed.stderr).strip()
    return {"command": command, "exitCode": completed.returncode, "output": output}


class Session:
    """One harness run: tools, directories, path redaction, harness errors."""

    def __init__(self, export_dir: Path, work_dir: Path, tools: Tools):
        self.export_dir = export_dir
        self.work_dir = work_dir
        self.tools = tools
        self.errors: list[str] = []

    def redact(self, text: str) -> str:
        replacements = [(str(self.work_dir), "<work>"), (str(self.export_dir), "<export>")]
        resolved_work = str(self.work_dir.resolve())
        resolved_export = str(self.export_dir.resolve())
        replacements += [(resolved_work, "<work>"), (resolved_export, "<export>")]
        home = os.environ.get("HOME")
        for original, label in sorted(replacements, key=lambda pair: -len(pair[0])):
            text = text.replace(original, label)
        if home:
            text = text.replace(home, "~")
        if len(text) > OUTPUT_LIMIT:
            text = text[:OUTPUT_LIMIT] + "\n[output truncated]"
        return text

    def run(self, tool: str, arguments: list[str]) -> dict:
        path = self.tools.path(tool)
        if path is None:
            return {"command": self.redact(" ".join([tool] + arguments)), "exitCode": None,
                    "output": f"{tool} is not available on this host", "verdict": "unavailable"}
        result = _execute([path] + arguments)
        result["command"] = self.redact(result["command"].replace(path, tool, 1))
        result["output"] = self.redact(result["output"])
        result["verdict"] = _verdict(result)
        return result

    def openssl(self, arguments: list[str]) -> dict:
        if self.tools.openssl is None:
            return {"command": "openssl " + " ".join(arguments), "exitCode": None,
                    "output": "no OpenSSL with the cms command was found",
                    "verdict": "unavailable"}
        result = _execute([self.tools.openssl] + arguments)
        result["command"] = self.redact(result["command"].replace(self.tools.openssl, "openssl", 1))
        result["output"] = self.redact(result["output"])
        result["verdict"] = _verdict(result)
        return result


def _verdict(result: dict) -> str:
    if result["exitCode"] is None:
        return "unavailable"
    return "accepted" if result["exitCode"] == 0 else "rejected"


# --------------------------------------------------------------------------
# Analysis
# --------------------------------------------------------------------------

def codesign_verify(session: Session, path: Path, deep: bool = False) -> dict:
    arguments = ["--verify", "--verbose=4"]
    if deep:
        arguments += ["--deep", "--strict"]
    result = session.run("codesign", arguments + [str(path)])
    result["summary"] = summarize_codesign(result["output"])
    return result


def codesign_display(session: Session, path: Path) -> dict:
    display = session.run("codesign", ["--display", "--verbose=4", str(path)])
    display["parsed"] = parse_codesign_display(display["output"])
    requirements = session.run("codesign", ["--display", "--requirements", "-", str(path)])
    entitlements = session.run("codesign", ["--display", "--entitlements", "-", str(path)])
    return {"display": display, "requirements": requirements, "entitlements": entitlements}


def openssl_cms_verify(session: Session, raw: dict, label: str) -> dict:
    cms = raw.get(0x10000)
    directory = raw.get(0)
    if not cms or len(cms) <= 8 or not directory:
        return {"verdict": "not-applicable", "output": "no CMS signature over a CodeDirectory"}
    cms_path = session.work_dir / f"{label}.cms.der"
    directory_path = session.work_dir / f"{label}.codedirectory.bin"
    cms_path.write_bytes(cms[8:])
    directory_path.write_bytes(directory)
    return session.openssl(["cms", "-verify", "-binary", "-inform", "DER",
                            "-in", str(cms_path), "-content", str(directory_path),
                            "-noverify", "-out", os.devnull])


def inspect_binary(session: Session, path: Path, label: str, role: str,
                   expected_offset: int | None = None) -> dict:
    """Parses one signed binary and runs the per-binary tools and rules."""
    result: dict = {"path": session.redact(str(path)), "role": role}
    try:
        summary, raw = parse_macho(path.read_bytes())
    except (OSError, FormatError) as error:
        result["parseError"] = str(error)
        result["rules"] = ios_format_rules(None, role)
        return result
    result["parse"] = summary
    result["rules"] = ios_format_rules(summary, role)
    otool = session.run("otool", ["-l", str(path)])
    result["otool"] = {"command": otool["command"], "exitCode": otool["exitCode"],
                       "verdict": otool["verdict"]}
    otool_commands = parse_otool_load_commands(otool["output"]) if otool["exitCode"] == 0 else None
    if otool["exitCode"] not in (0, None):
        result["otool"]["output"] = otool["output"]
    result["layout"] = layout_checks(summary, otool_commands, expected_offset)
    result["openssl"] = openssl_cms_verify(session, raw, label)
    return result


def compare_code_directories(zynsign: dict | None, reference: dict | None,
                             reference_kind: str = "ad hoc") -> list[dict]:
    """Field differences between ZynSign's and the reference's signature.

    Digest selection and the CodeDirectory version codesign emits follow the
    input's declared platform and minimum OS. For an input that declares
    neither, those rows are classified `input-dependent`: they describe
    codesign's reaction to the input, not a ZynSign defect.
    """
    if zynsign is None or reference is None:
        return []
    input_dependent = None if declares_platform(zynsign) else INPUT_DEPENDENT_NOTE
    ours = primary_code_directory(zynsign)
    theirs = primary_code_directory(reference)
    if ours is None or theirs is None:
        return []
    rows = []

    def add(field: str, mine, apple, expected_reason: str | None = None,
            dependent_reason: str | None = None):
        if mine == apple:
            return
        if expected_reason:
            classification, note = "expected", expected_reason
        elif dependent_reason:
            classification, note = "input-dependent", dependent_reason
        else:
            classification, note = "divergence", ""
        rows.append({
            "field": field,
            "zynsign": mine,
            "reference": apple,
            "classification": classification,
            "note": note,
        })

    add("CodeDirectory version", ours["versionHex"], theirs["versionHex"],
        dependent_reason=input_dependent)
    ours_flags = ours["flags"]
    theirs_flags = theirs["flags"]
    if reference_kind == "ad hoc":
        add("CodeDirectory flags (ad hoc bit masked)", f"{ours_flags & ~CS_ADHOC:#x}",
            f"{theirs_flags & ~CS_ADHOC:#x}")
        add("CodeDirectory flags", ours["flagsHex"], theirs["flagsHex"],
            "an ad hoc reference sets CS_ADHOC (0x2)"
            if (ours_flags & ~CS_ADHOC) == (theirs_flags & ~CS_ADHOC) else None)
    else:
        add("CodeDirectory flags", ours["flagsHex"], theirs["flagsHex"])
    add("hash type", ours["hashType"], theirs["hashType"], dependent_reason=input_dependent)
    add("page size", ours["pageSize"], theirs["pageSize"])
    add("identifier", ours["identifier"], theirs["identifier"])
    add("team identifier", ours["teamIdentifier"], theirs["teamIdentifier"],
        "ad hoc signatures carry no team identifier" if reference_kind == "ad hoc" else None)
    add("code limit", ours["codeLimit"], theirs["codeLimit"])
    add("platform", ours["platform"], theirs["platform"])
    add("present special slots", ours["presentSpecialSlots"], theirs["presentSpecialSlots"])
    add("special slot count", ours["specialSlotCount"], theirs["specialSlotCount"])
    add("executable segment", ours["execSegment"], theirs["execSegment"])
    add("runtime version", ours["runtime"], theirs["runtime"])
    ours_types = [entry["name"] for entry in zynsign["signature"]["entries"]
                  if not entry["name"].startswith("AlternateCodeDirectory")]
    theirs_types = [entry["name"] for entry in reference["signature"]["entries"]
                    if not entry["name"].startswith("AlternateCodeDirectory")]
    add("SuperBlob entries (alternate CodeDirectories aside)", ours_types, theirs_types)
    ours_directories = [f"{directory['hashType']} v={directory['versionHex']}"
                        for directory in zynsign["signature"]["codeDirectories"]]
    theirs_directories = [f"{directory['hashType']} v={directory['versionHex']}"
                          for directory in reference["signature"]["codeDirectories"]]
    add("CodeDirectories", ours_directories, theirs_directories,
        dependent_reason=input_dependent)
    ours_cms = zynsign["signature"].get("cmsBytes", 0)
    theirs_cms = reference["signature"].get("cmsBytes", 0)
    if (ours_cms > 0) != (theirs_cms > 0):
        add("CMS signature present", ours_cms > 0, theirs_cms > 0,
            "ad hoc signatures carry an empty CMS wrapper" if reference_kind == "ad hoc" else None)
    ours_requirements = zynsign["signature"].get("requirements")
    theirs_requirements = reference["signature"].get("requirements")
    add("requirements set", ours_requirements, theirs_requirements)
    return rows


def summarize_code_resources(path: Path) -> dict:
    if not path.exists():
        return {"present": False}
    try:
        document = plistlib.loads(path.read_bytes())
    except Exception as error:  # plistlib raises several unrelated types
        return {"present": True, "parseError": str(error)}
    if not isinstance(document, dict):
        return {"present": True, "parseError": "top level is not a dictionary"}
    files2 = document.get("files2", {})
    entries = {}
    if isinstance(files2, dict):
        for key in sorted(files2):
            value = files2[key]
            if isinstance(value, dict):
                entries[key] = {"kind": "nested" if "cdhash" in value else "file",
                                "keys": sorted(value.keys())}
            else:
                entries[key] = {"kind": "file (data value)", "keys": []}
    rules2 = document.get("rules2")
    return {
        "present": True,
        "topLevelKeys": sorted(document.keys()),
        "files2": entries,
        "rules2Count": len(rules2) if isinstance(rules2, dict) else None,
        "rules2": _json_safe(rules2) if isinstance(rules2, dict) else None,
    }


def _json_safe(value):
    if isinstance(value, dict):
        return {str(key): _json_safe(item) for key, item in sorted(value.items())}
    if isinstance(value, list):
        return [_json_safe(item) for item in value]
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def compare_code_resources(zynsign: dict, reference: dict) -> list[dict]:
    rows = []
    if not zynsign.get("present") or not reference.get("present"):
        if zynsign.get("present") != reference.get("present"):
            rows.append({"field": "CodeResources present", "zynsign": zynsign.get("present"),
                         "reference": reference.get("present"),
                         "classification": "divergence", "note": ""})
        return rows
    if zynsign.get("topLevelKeys") != reference.get("topLevelKeys"):
        rows.append({"field": "top-level keys", "zynsign": zynsign.get("topLevelKeys"),
                     "reference": reference.get("topLevelKeys"),
                     "classification": "divergence", "note": ""})
    ours = zynsign.get("files2", {})
    theirs = reference.get("files2", {})
    only_ours = sorted(set(ours) - set(theirs))
    only_theirs = sorted(set(theirs) - set(ours))
    if only_ours:
        rows.append({"field": "files2 entries only in ZynSign's seal", "zynsign": only_ours,
                     "reference": [], "classification": "divergence", "note": ""})
    if only_theirs:
        rows.append({"field": "files2 entries only in the reference seal", "zynsign": [],
                     "reference": only_theirs, "classification": "divergence", "note": ""})
    for key in sorted(set(ours) & set(theirs)):
        if ours[key] != theirs[key]:
            rows.append({"field": f"files2[{key}]", "zynsign": ours[key],
                         "reference": theirs[key], "classification": "divergence", "note": ""})
    return rows


def _entitlements_payload(raw: dict) -> bytes | None:
    blob = raw.get(5)
    return blob[8:] if blob and len(blob) > 8 else None


def reference_sign_macho(session: Session, unsigned: Path, identifier: str,
                         entitlements: bytes | None, label: str) -> dict:
    reference = session.work_dir / f"{label}.reference"
    shutil.copyfile(unsigned, reference)
    arguments = ["--sign", "-", "--force", "--identifier", identifier]
    if entitlements is not None:
        entitlements_path = session.work_dir / f"{label}.entitlements.plist"
        entitlements_path.write_bytes(entitlements)
        arguments += ["--entitlements", str(entitlements_path), "--generate-entitlement-der"]
    sign = session.run("codesign", arguments + [str(reference)])
    result: dict = {"kind": "ad hoc", "sign": sign}
    if sign["verdict"] != "accepted":
        return result
    result["verify"] = codesign_verify(session, reference)
    try:
        result["parse"], _ = parse_macho(reference.read_bytes())
    except (OSError, FormatError) as error:
        result["parseError"] = str(error)
    return result


def analyze_macho_artifact(session: Session, artifact: dict) -> dict:
    identifier = artifact["id"]
    result: dict = {"id": identifier, "kind": "macho", "zynsign": _zynsign_fields(artifact)}
    if artifact.get("status") != "signed" or not artifact.get("file"):
        result["refused"] = True
        return result
    signed = session.export_dir / artifact["file"]
    if not signed.exists():
        session.errors.append(f"{identifier}: exported file {artifact['file']} is missing")
        return result
    result["codesign"] = {"verify": codesign_verify(session, signed)}
    result["codesign"].update(codesign_display(session, signed))
    result["binary"] = inspect_binary(session, signed, identifier, "executable",
                                      artifact.get("signatureOffset"))
    unsigned_name = artifact.get("unsignedFile")
    unsigned = session.export_dir / unsigned_name if unsigned_name else None
    if unsigned is not None and unsigned.exists():
        _summary, raw = _parse_quietly(signed)
        reference = reference_sign_macho(
            session, unsigned, artifact.get("identifier") or identifier,
            _entitlements_payload(raw), identifier)
        result["reference"] = reference
        if reference.get("parse") is not None and result["binary"].get("parse") is not None:
            result["referenceDifferences"] = compare_code_directories(
                result["binary"]["parse"], reference["parse"])
    return result


def _parse_quietly(path: Path) -> tuple[dict | None, dict]:
    try:
        return parse_macho(path.read_bytes())
    except (OSError, FormatError):
        return None, {}


def _zynsign_fields(artifact: dict) -> dict:
    keys = ("status", "zynsignVerdict", "detail", "identifier", "teamIdentifier",
            "codeLimit", "signatureOffset", "codeDirectorySHA256", "notes")
    return {key: artifact[key] for key in keys if key in artifact}


def extract_container(session: Session, container: Path, destination: Path) -> dict:
    destination.mkdir(parents=True, exist_ok=True)
    ditto = session.run("ditto", ["-x", "-k", str(container), str(destination)])
    if ditto["verdict"] == "accepted":
        return {"tool": "ditto", "result": ditto}
    # Fallback for hosts without ditto; modes and links are not restored.
    try:
        with zipfile.ZipFile(container) as archive:
            archive.extractall(destination)
        return {"tool": "zipfile", "result": ditto}
    except (OSError, zipfile.BadZipFile) as error:
        return {"tool": "none", "result": ditto, "error": str(error)}


def _nested_executable(bundle: Path) -> Path | None:
    information = bundle / "Info.plist"
    try:
        document = plistlib.loads(information.read_bytes())
    except Exception:  # plistlib raises several unrelated types
        return None
    name = document.get("CFBundleExecutable") if isinstance(document, dict) else None
    return bundle / name if isinstance(name, str) and name else None


def bundle_observation(session: Session, bundle: Path, label: str, signer: str) -> dict:
    """How codesign describes one bundle's binding of Info.plist and resources."""
    display = codesign_display(session, bundle)["display"]
    parsed = display.get("parsed", {})
    return {
        "display": display.get("output", ""),
        "bundle": label,
        "signer": signer,
        "infoPlist": parsed.get("Info.plist", "not reported"),
        "sealedResources": parsed.get("Sealed Resources", "not reported"),
        "codeResourcesFile": (bundle / "_CodeSignature" / "CodeResources").exists(),
        "embeddedProfile": (bundle / "embedded.mobileprovision").exists(),
    }


BUNDLE_MUTATIONS = (
    ("resource-modified", "A sealed resource's content changed (asset.dat)."),
    ("resource-added", "An unsealed file was added at the bundle root."),
    ("profile-modified", "The embedded provisioning profile's content changed."),
    ("main-executable-code-byte", "One byte inside the main executable's signed code flipped."),
    ("nested-executable-code-byte", "One byte inside the nested framework executable flipped."),
)


def _apply_bundle_mutation(name: str, app: Path, executable: str,
                           nested: list[str]) -> bool:
    def flip(path: Path, offset: int) -> bool:
        if not path.exists() or path.stat().st_size <= offset:
            return False
        data = bytearray(path.read_bytes())
        data[offset] ^= 0x01
        path.write_bytes(bytes(data))
        return True

    def append(path: Path) -> bool:
        if not path.exists():
            return False
        with path.open("ab") as handle:
            handle.write(b"\n")
        return True

    if name == "resource-modified":
        return append(app / "asset.dat")
    if name == "resource-added":
        (app / "unsealed-addition.txt").write_bytes(b"added after signing\n")
        return True
    if name == "profile-modified":
        return append(app / "embedded.mobileprovision")
    if name == "main-executable-code-byte":
        return flip(app / executable, 512)
    if name == "nested-executable-code-byte":
        for bundle in nested:
            binary = _nested_executable(app / bundle)
            if binary is not None:
                return flip(binary, 512)
        return False
    return False


def reference_sign_bundle(session: Session, artifact: dict, zynsign_app: Path,
                          entitlements: bytes | None) -> dict:
    source = session.export_dir / artifact["unsignedFile"]
    root = session.work_dir / f"{artifact['id']}-reference"
    extraction = extract_container(session, source, root)
    result: dict = {"kind": "ad hoc", "extraction": extraction["tool"]}
    app = root / artifact["bundlePath"]
    if not app.exists():
        result["error"] = "the unsigned source bundle could not be extracted"
        return result
    profile = zynsign_app / "embedded.mobileprovision"
    if profile.exists():
        shutil.copyfile(profile, app / "embedded.mobileprovision")
    steps = []
    for nested in artifact.get("nestedBundles") or []:
        steps.append(session.run("codesign", ["--sign", "-", "--force", str(app / nested)]))
    arguments = ["--sign", "-", "--force"]
    if entitlements is not None:
        entitlements_path = session.work_dir / f"{artifact['id']}.entitlements.plist"
        entitlements_path.write_bytes(entitlements)
        arguments += ["--entitlements", str(entitlements_path), "--generate-entitlement-der"]
    steps.append(session.run("codesign", arguments + [str(app)]))
    result["sign"] = steps
    if any(step["verdict"] != "accepted" for step in steps):
        return result
    result["verifyDeep"] = codesign_verify(session, app, deep=True)
    result["observations"] = [bundle_observation(session, app, artifact["bundlePath"], "reference")]
    for nested in artifact.get("nestedBundles") or []:
        result["observations"].append(
            bundle_observation(session, app / nested, nested, "reference"))
    main_summary, _ = _parse_quietly(app / artifact["executable"])
    result["main"] = main_summary
    result["nested"] = {}
    for nested in artifact.get("nestedBundles") or []:
        binary = _nested_executable(app / nested)
        result["nested"][nested] = _parse_quietly(binary)[0] if binary else None
    result["codeResources"] = summarize_code_resources(app / "_CodeSignature" / "CodeResources")
    return result


def analyze_ipa_artifact(session: Session, artifact: dict) -> dict:
    identifier = artifact["id"]
    result: dict = {"id": identifier, "kind": "ipa", "zynsign": _zynsign_fields(artifact)}
    if artifact.get("status") != "signed" or not artifact.get("file"):
        result["refused"] = True
        return result
    signed = session.export_dir / artifact["file"]
    if not signed.exists():
        session.errors.append(f"{identifier}: exported file {artifact['file']} is missing")
        return result
    result["unzip"] = session.run("unzip", ["-tqq", str(signed)])
    root = session.work_dir / f"{identifier}-signed"
    extraction = extract_container(session, signed, root)
    result["extraction"] = {"tool": extraction["tool"], "ditto": extraction["result"]}
    app = root / artifact["bundlePath"]
    if not app.exists():
        session.errors.append(f"{identifier}: the signed container could not be extracted")
        return result
    result["codesign"] = {
        "verifyDeepStrict": codesign_verify(session, app, deep=True),
        "verify": codesign_verify(session, app),
    }
    result["codesign"].update(codesign_display(session, app))
    main_binary = app / artifact["executable"]
    result["main"] = inspect_binary(session, main_binary, f"{identifier}-main", "application")
    result["nested"] = {}
    nested_bundles = artifact.get("nestedBundles") or []
    for nested in nested_bundles:
        bundle = app / nested
        binary = _nested_executable(bundle)
        role = "framework" if nested.endswith(".framework") else "nested"
        entry: dict = {
            "codesignVerify": codesign_verify(session, bundle),
            "embeddedProfilePresent": (bundle / "embedded.mobileprovision").exists(),
            "codeResourcesPresent": (bundle / "_CodeSignature" / "CodeResources").exists(),
        }
        entry.update(codesign_display(session, bundle))
        if binary is None:
            entry["error"] = "the nested bundle declares no readable executable"
        else:
            label = f"{identifier}-{Path(nested).name}"
            entry["binary"] = inspect_binary(session, binary, label, role)
        result["nested"][nested] = entry
    result["codeResources"] = summarize_code_resources(app / "_CodeSignature" / "CodeResources")
    observations = [bundle_observation(session, app, artifact["bundlePath"], "ZynSign")]
    for nested in nested_bundles:
        observations.append(bundle_observation(session, app / nested, nested, "ZynSign"))
    _, main_raw = _parse_quietly(main_binary)
    reference = reference_sign_bundle(session, artifact, app, _entitlements_payload(main_raw))
    result["reference"] = {key: value for key, value in reference.items()
                           if key not in ("main", "nested", "observations")}
    result["bundleObservations"] = observations + reference.get("observations", [])
    differences = None
    if reference.get("main") is not None and result["main"].get("parse") is not None:
        differences = []
        for row in compare_code_directories(result["main"].get("parse"), reference["main"]):
            differences.append(dict(row, scope="main executable"))
        for nested in nested_bundles:
            ours = result["nested"].get(nested, {}).get("binary", {}).get("parse")
            theirs = reference.get("nested", {}).get(nested)
            for row in compare_code_directories(ours, theirs):
                differences.append(dict(row, scope=nested))
        for row in compare_code_resources(result["codeResources"],
                                          reference.get("codeResources", {})):
            differences.append(dict(row, scope="CodeResources"))
    result["referenceDifferences"] = differences
    baseline = result["codesign"]["verifyDeepStrict"]["verdict"]
    mutations = []
    for name, description in BUNDLE_MUTATIONS:
        copy_root = session.work_dir / f"{identifier}-mutation-{name}"
        copy = copy_root / app.name
        shutil.copytree(app, copy, symlinks=True)
        applied = _apply_bundle_mutation(name, copy, artifact["executable"], nested_bundles)
        row = {"artifact": identifier, "mutation": name, "description": description}
        if not applied:
            row.update({"codesign": "skipped", "meaningful": False,
                        "note": "the mutation target is absent"})
        else:
            verify = codesign_verify(session, copy, deep=True)
            row.update({
                "codesign": verify["verdict"],
                "codesignSummary": verify["summary"],
                "meaningful": baseline == "accepted",
                "note": "" if baseline == "accepted" else
                        "the unmodified container was not accepted, so a rejection here "
                        "does not show that tampering was detected",
            })
        mutations.append(row)
    result["bundleMutations"] = mutations
    return result


def analyze_mutations(session: Session, mutations: list[dict],
                      baselines: dict[str, str]) -> list[dict]:
    rows = []
    for mutation in mutations:
        path = session.export_dir / mutation["file"]
        row = {
            "artifact": mutation["artifact"],
            "mutation": mutation["mutation"],
            "description": mutation.get("description", ""),
            "zynsign": mutation.get("zynsignVerdict"),
            "zynsignDetail": mutation.get("zynsignDetail", ""),
        }
        if not path.exists():
            session.errors.append(f"mutation {mutation['file']} is missing")
            row.update({"codesign": "missing", "parity": None, "meaningful": False})
            rows.append(row)
            continue
        verify = codesign_verify(session, path)
        baseline = baselines.get(mutation["artifact"])
        meaningful = baseline == "accepted"
        row.update({
            "codesign": verify["verdict"],
            "codesignSummary": verify["summary"],
            "meaningful": meaningful,
            "parity": (row["zynsign"] == verify["verdict"]) if meaningful and
                      verify["verdict"] in ("accepted", "rejected") else None,
        })
        if not meaningful:
            row["note"] = ("the unmodified artifact was not accepted by codesign, so parity "
                           "is not meaningful")
        rows.append(row)
    return rows


def environment_facts(session: Session) -> dict:
    facts: dict = {
        "python": platform.python_version(),
        "platform": platform.platform(),
        "openssl": None,
        "tools": {name: bool(session.tools.path(name)) for name in Tools.NAMES},
    }
    for variable in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA", "GITHUB_REF_NAME",
                     "ImageOS", "ImageVersion", "RUNNER_OS"):
        if os.environ.get(variable):
            facts[variable] = os.environ[variable]
    if shutil.which("sw_vers"):
        facts["macOS"] = _execute(["sw_vers"])["output"]
    if shutil.which("xcodebuild"):
        facts["xcode"] = _execute(["xcodebuild", "-version"])["output"]
    if session.tools.openssl:
        facts["openssl"] = _execute([session.tools.openssl, "version"])["output"]
    return facts


def load_manifests(session: Session) -> list[dict]:
    manifests = []
    for path in sorted(session.export_dir.glob("manifest-*.json")):
        try:
            manifests.append(json.loads(path.read_text()))
        except (OSError, json.JSONDecodeError) as error:
            session.errors.append(f"{path.name} could not be read: {error}")
    if not manifests:
        session.errors.append(
            "no manifest-*.json in the export directory; the export test did not run "
            "(was ZYNSIGN_EXPORT_DIR passed to the test runner?)")
    return manifests


def analyze(session: Session, export_status: int | None = None,
            require_tools: bool = True) -> dict:
    if export_status not in (None, 0):
        session.errors.append(f"the export step failed (xcodebuild exit status {export_status})")
    if require_tools:
        for name in Tools.NAMES:
            if session.tools.path(name) is None:
                session.errors.append(f"{name} is not available on this host")
    manifests = load_manifests(session)
    artifacts = []
    mutation_inputs = []
    for manifest in manifests:
        for artifact in manifest.get("artifacts", []):
            try:
                if artifact.get("kind") == "ipa":
                    artifacts.append(analyze_ipa_artifact(session, artifact))
                else:
                    artifacts.append(analyze_macho_artifact(session, artifact))
            except Exception as error:  # a harness defect must not hide other results
                session.errors.append(f"{artifact.get('id')}: analysis failed: {error!r}")
        mutation_inputs += manifest.get("mutations", [])
    baselines = {
        artifact["id"]: artifact["codesign"]["verify"]["verdict"]
        for artifact in artifacts
        if artifact.get("kind") == "macho" and "codesign" in artifact
    }
    mutations = analyze_mutations(session, mutation_inputs, baselines)
    return {
        "schema": REPORT_SCHEMA,
        "evidence": EVIDENCE_STATEMENT,
        "appleFormatDocument": APPLE_FORMAT_DOC,
        "environment": environment_facts(session),
        "artifacts": artifacts,
        "mutations": mutations,
        "harnessErrors": list(session.errors),
    }


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

def _cell(value) -> str:
    if value is None:
        return "—"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, (list, dict)):
        value = json.dumps(value, sort_keys=True)
    text = str(value).replace("|", "\\|").replace("\n", " ")
    return text if len(text) <= 160 else text[:157] + "…"


def _rules_cell(rules: list[dict] | None) -> str:
    if not rules:
        return "—"
    return ", ".join(f"{rule['id']} {rule['result']}" for rule in rules)


def artifact_verdict(artifact: dict) -> tuple[str, str]:
    """The headline codesign verdict and message for one artifact."""
    codesign = artifact.get("codesign") or {}
    verify = codesign.get("verifyDeepStrict") or codesign.get("verify")
    if artifact.get("refused"):
        return "not signed", artifact.get("zynsign", {}).get("detail", "")
    if not verify:
        return "not evaluated", ""
    return verify.get("verdict", "not evaluated"), verify.get("summary", "")


def _binary_rows(artifact: dict) -> list[tuple[str, dict]]:
    rows = []
    if "binary" in artifact:
        rows.append((artifact["id"], artifact["binary"]))
    if "main" in artifact:
        rows.append((f"{artifact['id']} main executable", artifact["main"]))
    for nested, entry in (artifact.get("nested") or {}).items():
        if "binary" in entry:
            rows.append((f"{artifact['id']} {nested}", entry["binary"]))
    return rows


def render_markdown(report: dict) -> str:
    lines = ["# External validation report", "", f"> {report['evidence']}", ""]
    environment = report.get("environment", {})
    facts = []
    for key in ("GITHUB_RUN_ID", "GITHUB_SHA", "ImageOS", "ImageVersion"):
        if environment.get(key):
            facts.append(f"{key}={environment[key]}")
    if environment.get("xcode"):
        facts.append(environment["xcode"].replace("\n", " "))
    if environment.get("openssl"):
        facts.append(environment["openssl"])
    if facts:
        lines += ["Environment: " + "; ".join(facts), ""]

    if report.get("harnessErrors"):
        lines += ["## Harness errors", ""]
        lines += [f"- {error}" for error in report["harnessErrors"]]
        lines.append("")

    lines += ["## Verdicts", "",
              "| Artifact | ZynSign | codesign | codesign message | iOS format rules |",
              "| --- | --- | --- | --- | --- |"]
    for artifact in report.get("artifacts", []):
        verdict, message = artifact_verdict(artifact)
        rules = None
        if "binary" in artifact:
            rules = artifact["binary"].get("rules")
        elif "main" in artifact:
            rules = artifact["main"].get("rules")
        lines.append(
            f"| {_cell(artifact['id'])} | {_cell(artifact.get('zynsign', {}).get('zynsignVerdict'))} "
            f"| {_cell(verdict)} | {_cell(message)} | {_cell(_rules_cell(rules))} |")
        for nested, entry in (artifact.get("nested") or {}).items():
            verify = entry.get("codesignVerify", {})
            lines.append(
                f"| {_cell(artifact['id'] + ' ' + nested)} | — | {_cell(verify.get('verdict'))} "
                f"| {_cell(verify.get('summary'))} "
                f"| {_cell(_rules_cell(entry.get('binary', {}).get('rules')))} |")
    lines.append("")

    lines += ["## Apple-documented iOS format rules", "",
              f"Source: [Using the latest code signature format]({report['appleFormatDocument']})",
              "", "| Binary | Rule | Requirement | Result | Detail |",
              "| --- | --- | --- | --- | --- |"]
    for artifact in report.get("artifacts", []):
        for label, binary in _binary_rows(artifact):
            for rule in binary.get("rules", []):
                lines.append(f"| {_cell(label)} | {rule['id']} | {_cell(rule['requirement'])} "
                             f"| {rule['result']} | {_cell(rule['detail'])} |")
    lines.append("")

    lines += ["## Signature layout and CMS (E5)", "",
              "| Binary | Layout checks | OpenSSL CMS verify |", "| --- | --- | --- |"]
    for artifact in report.get("artifacts", []):
        for label, binary in _binary_rows(artifact):
            layout = binary.get("layout") or []
            failed = [check["id"] for check in layout if check["result"] == "fail"]
            summary = (f"{len(layout)} checked, all pass" if layout and not failed
                       else ("failed: " + ", ".join(failed) if failed else "not evaluated"))
            openssl = binary.get("openssl", {})
            lines.append(f"| {_cell(label)} | {_cell(summary)} | {_cell(openssl.get('verdict'))} |")
    lines.append("")

    observation_rows = [row for artifact in report.get("artifacts", [])
                        for row in artifact.get("bundleObservations", [])]
    if observation_rows:
        lines += ["## Bundle observations", "",
                  "How `codesign --display` describes each bundle's Info.plist binding and "
                  "resource seal. \"not reported\" means codesign printed no such line.", "",
                  "| Bundle | Signer | Info.plist | Sealed Resources | own CodeResources file "
                  "| embedded profile |", "| --- | --- | --- | --- | --- | --- |"]
        for row in observation_rows:
            lines.append(f"| {_cell(row['bundle'])} | {row['signer']} | {_cell(row['infoPlist'])} "
                         f"| {_cell(row['sealedResources'])} | {_cell(row['codeResourcesFile'])} "
                         f"| {_cell(row['embeddedProfile'])} |")
        lines.append("")

    lines += ["## Reference comparison", "",
              "The same unsigned input signed ad hoc by `codesign` "
              "(`--sign - --generate-entitlement-der`). *expected* differences follow from ad "
              "hoc signing itself; *input-dependent* differences follow from the input declaring "
              "no platform or minimum OS, so they describe codesign's reaction to the synthetic "
              "input rather than ZynSign; every other difference is a *divergence*.", ""]
    for artifact in report.get("artifacts", []):
        differences = artifact.get("referenceDifferences")
        reference = artifact.get("reference") or {}
        lines.append(f"### {artifact['id']}")
        lines.append("")
        verify = reference.get("verify") or reference.get("verifyDeep")
        if verify:
            lines.append(f"Reference `codesign --verify`: {verify.get('verdict')} "
                         f"({_cell(verify.get('summary'))})")
            lines.append("")
        signing = reference.get("sign")
        steps = signing if isinstance(signing, list) else ([signing] if signing else [])
        failed_steps = [step for step in steps if step.get("verdict") != "accepted"]
        if failed_steps:
            lines.append("Reference signing did not complete: "
                         + "; ".join(_cell(step.get("output")) for step in failed_steps))
            lines.append("")
        if differences is None:
            lines += ["Not compared.", ""]
            continue
        if not differences:
            lines += ["No differences.", ""]
            continue
        lines += ["| Scope | Field | ZynSign | Reference | Classification |",
                  "| --- | --- | --- | --- | --- |"]
        for row in differences:
            classification = row["classification"]
            if row.get("note"):
                classification += f" ({row['note']})"
            lines.append(f"| {_cell(row.get('scope', 'binary'))} | {_cell(row['field'])} "
                         f"| {_cell(row['zynsign'])} | {_cell(row['reference'])} "
                         f"| {_cell(classification)} |")
        lines.append("")

    lines += ["## Tamper detection", "",
              "| Artifact | Mutation | ZynSign | codesign | Parity / meaning |",
              "| --- | --- | --- | --- | --- |"]
    for row in report.get("mutations", []):
        if row.get("parity") is None:
            meaning = row.get("note") or "not meaningful"
        else:
            meaning = "agree" if row["parity"] else "DISAGREE"
        lines.append(f"| {_cell(row['artifact'])} | {_cell(row['mutation'])} "
                     f"| {_cell(row.get('zynsign'))} | {_cell(row.get('codesign'))} "
                     f"| {_cell(meaning)} |")
    for artifact in report.get("artifacts", []):
        for row in artifact.get("bundleMutations", []):
            meaning = "codesign only" if row.get("meaningful") else (row.get("note") or "")
            lines.append(f"| {_cell(row['artifact'])} | {_cell(row['mutation'])} | not measured "
                         f"| {_cell(row.get('codesign'))} | {_cell(meaning)} |")
    lines.append("")

    lines += ["<details><summary>Raw codesign output</summary>", ""]
    for artifact in report.get("artifacts", []):
        codesign = artifact.get("codesign") or {}
        for key in ("verifyDeepStrict", "verify", "display", "requirements", "entitlements"):
            entry = codesign.get(key)
            if not entry:
                continue
            lines += [f"**{artifact['id']} — {entry.get('command', key)}** "
                      f"(exit {entry.get('exitCode')})", "", "```",
                      entry.get("output", ""), "```", ""]
    lines += ["</details>", ""]
    return "\n".join(lines)


def notices(report: dict) -> list[str]:
    """Workflow annotations: one headline per artifact, plus harness errors."""
    commands = []
    for artifact in report.get("artifacts", [])[:8]:
        verdict, message = artifact_verdict(artifact)
        rules = []
        for _label, binary in _binary_rows(artifact):
            rules += [f"{rule['id']} {rule['result']}" for rule in binary.get("rules", [])
                      if rule["result"] == "fail"]
        text = f"codesign: {verdict}"
        if message:
            text += f" — {message}"
        if rules:
            text += f"; failed iOS rules: {', '.join(sorted(set(rules)))}"
        differences = artifact.get("referenceDifferences")
        if differences is None:
            text += "; reference comparison: not completed"
        else:
            divergences = [row for row in differences if row["classification"] == "divergence"]
            text += f"; reference divergences: {len(divergences)}"
        title = _escape_property(f"External validation: {artifact['id']}")
        commands.append(f"::notice title={title}::{_escape_data(text)}")
    for error in report.get("harnessErrors", [])[:10]:
        commands.append(f"::error title=External validation harness::{_escape_data(error)}")
    return commands


def publish(report: dict, markdown: str) -> None:
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(markdown[:900_000] + "\n")
    for command in notices(report):
        print(command)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def command_run(arguments: argparse.Namespace) -> int:
    export_dir = Path(arguments.export_dir).resolve()
    report_dir = Path(arguments.report_dir).resolve()
    tools = Tools.discover()
    with tempfile.TemporaryDirectory(prefix="zynsign-external-validation-") as temporary:
        session = Session(export_dir, Path(temporary).resolve(), tools)
        report = analyze(session, arguments.export_status,
                         require_tools=not arguments.allow_missing_tools)
    report_dir.mkdir(parents=True, exist_ok=True)
    (report_dir / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    markdown = render_markdown(report)
    (report_dir / "report.md").write_text(markdown)
    publish(report, markdown)
    for artifact in report["artifacts"]:
        verdict, message = artifact_verdict(artifact)
        print(f"{artifact['id']}: codesign {verdict}" + (f" — {message}" if message else ""))
    for error in report["harnessErrors"]:
        print(f"HARNESS ERROR: {error}", file=sys.stderr)
    print(f"Report: {report_dir / 'report.md'}")
    return 1 if report["harnessErrors"] else 0


def command_annotate_xcodebuild(arguments: argparse.Namespace) -> int:
    log = Path(arguments.log).read_text(errors="replace")
    annotations = xcodebuild_annotations(log, os.environ.get("GITHUB_WORKSPACE"))
    for annotation in annotations:
        print(annotation)
    if not annotations:
        tail = "\n".join(log.splitlines()[-40:])
        print(f"::error title=Export step failed::{_escape_data(tail or 'no output')}")
    return 0


# --------------------------------------------------------------------------
# Self-test (any host; no Apple tooling required)
# --------------------------------------------------------------------------

SAMPLE_OTOOL = """<export>/single/single-plain:
Load command 0
      cmd LC_SEGMENT_64
  cmdsize 152
  segname __TEXT
   vmaddr 0x0000000100000000
   vmsize 0x0000000000001000
  fileoff 0
 filesize 4096
  maxprot 0x00000007
 initprot 0x00000005
   nsects 1
    flags 0x0
Section
  sectname __text
   segname __TEXT
     addr 0x0000000100000200
     size 0x0000000000000e00
   offset 512
    align 2^2 (4)
   reloff 0
   nreloc 0
    flags 0x80000400
Load command 1
      cmd LC_SEGMENT_64
  cmdsize 72
  segname __LINKEDIT
   vmaddr 0x0000000100001000
   vmsize 0x0000000000001000
  fileoff 4096
 filesize 1424
  maxprot 0x00000007
 initprot 0x00000001
   nsects 0
    flags 0x0
Load command 2
      cmd LC_CODE_SIGNATURE
  cmdsize 16
  dataoff 4144
 datasize 1376
"""

SAMPLE_BUNDLE_DISPLAY = """Executable=<work>/Payload/Synthetic.app/Synthetic
Identifier=com.example.synthetic
Format=bundle with Mach-O thin (arm64)
CodeDirectory v=20100 size=412 flags=0x2(adhoc) hashes=2+7 location=embedded
Info.plist entries=6
Sealed Resources version=2 rules=10 files=5
Internal requirements count=0 size=12
"""

SAMPLE_DISPLAY = """Executable=<export>/single/single-plain
Identifier=com.example.single
Format=Mach-O thin (arm64)
CodeDirectory v=20200 size=144 flags=0x0(none) hashes=2+0 location=embedded
Hash type=sha256 size=32
Signature size=1204
Authority=ZynSign External Validation
Info.plist=not bound
TeamIdentifier=TESTTEAM
Sealed Resources=none
Internal requirements count=0 size=12
"""

SAMPLE_XCODEBUILD_LOG = """
/Users/runner/work/ZynSign/ZynSign/Tests/ZynSignTests/ExternalValidationExportTests.swift:42:17: error: cannot find 'Missing' in scope
/Users/runner/work/ZynSign/ZynSign/Tests/ZynSignTests/ExternalValidationExportTests.swift:42:17: error: cannot find 'Missing' in scope
/Users/runner/work/ZynSign/ZynSign/Tests/ZynSignTests/ExternalValidationExportTests.swift:57: error: -[ZynSignTests.ExternalValidationExportTests testExportsSingleImageSignatures] : failed: caught error: "x"
** TEST FAILED **
"""


def _synthetic_code_directory(version: int, special: dict[int, bytes], special_count: int,
                              identifier: bytes = b"com.example.selftest") -> bytes:
    header = 88 if version >= 0x20400 else 52
    hash_size = 32
    identifier_bytes = identifier + b"\0"
    hash_offset = header + len(identifier_bytes) + special_count * hash_size
    length = hash_offset + hash_size
    blob = bytearray(length)
    struct.pack_into(">9I", blob, 0, CSMAGIC_CODEDIRECTORY, length, version, 0,
                     hash_offset, header, special_count, 1, 4096)
    struct.pack_into(">4B", blob, 36, hash_size, 2, 0, 12)
    blob[header:header + len(identifier_bytes)] = identifier_bytes
    for index, digest in special.items():
        start = hash_offset - index * hash_size
        blob[start:start + hash_size] = digest
    if version >= 0x20400:
        struct.pack_into(">3Q", blob, 64, 0, 4096, 1)
    return bytes(blob)


def _load_vector() -> dict[str, bytes]:
    fixture = (Path(__file__).resolve().parents[1] /
               "ZynSignTests/Support/MachOSigningFixtures.swift").read_text()
    return {name: base64.b64decode(text) for name, text in re.findall(
        r'static let (\w+): Data = decode\("""(.*?)"""\)', fixture, re.S)}


def command_self_test(_arguments: argparse.Namespace) -> int:
    values = _load_vector()
    signed, unsigned = values["expectedSignedMachO"], values["unsignedMachO"]

    summary, raw = parse_macho(signed)
    assert summary["codeSignature"] == {"dataoff": 4144, "datasize": 1376}
    assert summary["loadCommands"] == ["LC_SEGMENT_64", "LC_SEGMENT_64", "LC_CODE_SIGNATURE"]
    assert [entry["type"] for entry in summary["signature"]["entries"]] == [0, 0x10000]
    directory = primary_code_directory(summary)
    assert directory["version"] == 0x20200
    assert directory["identifier"] == "com.example.single"
    assert directory["teamIdentifier"] == "TESTTEAM"
    assert directory["codeLimit"] == 4144 and directory["codeSlotCount"] == 2
    assert directory["specialSlotCount"] == 0 and directory["presentSpecialSlots"] == []
    assert directory["execSegment"] is None
    assert directory["sha256"] == hashlib.sha256(values["codeDirectory"]).hexdigest()
    assert raw[0x10000][8:] == values["cms"]
    assert summary["signature"]["trailingBytesAllZero"]
    assert parse_macho(unsigned)[0]["codeSignature"] is None
    for damaged in (signed[:40], b"\xca\xfe\xba\xbe" + signed[4:]):
        try:
            parse_macho(damaged)
        except FormatError:
            pass
        else:
            raise AssertionError("a damaged or universal input must be refused")

    rules = ios_format_rules(summary, "application")
    assert [(rule["id"], rule["result"]) for rule in rules] == [
        ("R1", "fail"), ("R2", "not-applicable")]
    xml_only = parse_code_directory(_synthetic_code_directory(0x20400, {5: b"\x11" * 32}, 5))
    assert xml_only["presentSpecialSlots"] == [-5] and xml_only["execSegment"]["limit"] == 4096
    synthetic = {"signature": {"codeDirectories": [dict(xml_only, slot=0)],
                               "entries": [{"type": 0}, {"type": 5}]}}
    assert [(rule["id"], rule["result"]) for rule in ios_format_rules(synthetic, "framework")] == [
        ("R1", "pass"), ("R2", "fail"), ("R3", "fail")]
    both = parse_code_directory(_synthetic_code_directory(
        0x20500, {5: b"\x11" * 32, 7: b"\x22" * 32}, 7))
    assert both["presentSpecialSlots"] == [-5, -7]
    assert ios_format_rules({"signature": {"codeDirectories": [dict(both, slot=0)],
                                           "entries": []}}, "application")[1]["result"] == "pass"

    otool = parse_otool_load_commands(SAMPLE_OTOOL)
    assert otool[2]["cmd"] == "LC_CODE_SIGNATURE" and otool[1]["filesize"] == "1424"
    assert otool[0]["flags"] == "0x0", "segment keys must win over section keys"
    checks = layout_checks(summary, otool, 4144)
    assert [check["result"] for check in checks] == ["pass"] * 7, checks

    display = parse_codesign_display(SAMPLE_DISPLAY)
    assert display["codeDirectoryVersion"] == "20200" and display["specialSlots"] == 0
    assert display["Info.plist"] == "not bound" and display["Authority"] == [
        "ZynSign External Validation"]
    bundle_display = parse_codesign_display(SAMPLE_BUNDLE_DISPLAY)
    assert bundle_display["Info.plist"] == "entries=6"
    assert bundle_display["Sealed Resources"] == "version=2 rules=10 files=5"
    assert bundle_display["flagNames"] == "adhoc" and bundle_display["specialSlots"] == 7
    assert summarize_codesign(
        "x: valid on disk\nx: satisfies its Designated Requirement") == (
        "valid on disk; satisfies its Designated Requirement")

    annotations = xcodebuild_annotations(SAMPLE_XCODEBUILD_LOG, "/Users/runner/work/ZynSign/ZynSign")
    assert len(annotations) == 2, annotations
    assert annotations[0].startswith(
        "::error file=Tests/ZynSignTests/ExternalValidationExportTests.swift,line=42,col=17::")

    reference = parse_macho(signed)[0]
    changed = json.loads(json.dumps(reference))
    changed["signature"]["codeDirectories"][0]["versionHex"] = "20400"
    changed["signature"]["codeDirectories"][0]["flags"] = CS_ADHOC
    changed["signature"]["codeDirectories"][0]["flagsHex"] = "0x2"
    rows = compare_code_directories(reference, changed)
    assert [(row["field"], row["classification"]) for row in rows] == [
        ("CodeDirectory version", "input-dependent"), ("CodeDirectory flags", "expected"),
        ("CodeDirectories", "input-dependent")], rows
    declared = json.loads(json.dumps(reference))
    declared["loadCommands"].insert(2, "LC_BUILD_VERSION")
    rows = compare_code_directories(declared, changed)
    assert [(row["field"], row["classification"]) for row in rows] == [
        ("CodeDirectory version", "divergence"), ("CodeDirectory flags", "expected"),
        ("CodeDirectories", "divergence")], rows
    assert summarize_codesign(
        "x: invalid signature (code or signature have been modified)\n"
        "In architecture: arm64") == "invalid signature (code or signature have been modified)"

    with tempfile.TemporaryDirectory(prefix="zynsign-external-validation-self-test-") as temp:
        root = Path(temp).resolve()
        export = root / "export"
        (export / "single" / "mutations").mkdir(parents=True)
        (export / "single" / "single-plain").write_bytes(signed)
        (export / "single" / "unsigned").write_bytes(unsigned)
        damaged = bytearray(signed)
        damaged[512] ^= 1
        (export / "single" / "mutations" / "single-plain.code-byte").write_bytes(bytes(damaged))
        manifest = {
            "schema": 1,
            "producer": "self-test",
            "artifacts": [
                {"id": "single-plain", "kind": "macho", "status": "signed",
                 "file": "single/single-plain", "unsignedFile": "single/unsigned",
                 "certificateFile": "single/certificate.der",
                 "identifier": "com.example.single", "signatureOffset": 4144,
                 "zynsignVerdict": "accepted", "detail": "self-test"},
                {"id": "refused-example", "kind": "ipa", "status": "refused",
                 "unsignedFile": "pipeline/source-unsigned.ipa",
                 "certificateFile": "pipeline/certificate.der", "identifier": "x",
                 "zynsignVerdict": "refused", "detail": "self-test refusal"},
            ],
            "mutations": [
                {"artifact": "single-plain", "mutation": "code-byte",
                 "file": "single/mutations/single-plain.code-byte",
                 "description": "flip", "zynsignVerdict": "rejected", "zynsignDetail": "x"},
            ],
        }
        (export / "manifest-single.json").write_text(json.dumps(manifest))
        information = plistlib.dumps({"CFBundleIdentifier": "com.example.synthetic",
                                      "CFBundleExecutable": "Synthetic"})
        nested_information = plistlib.dumps({"CFBundleIdentifier": "com.example.nested",
                                             "CFBundleExecutable": "Test"})
        seal = plistlib.dumps({"files2": {"asset.dat": {"hash2": b"\x00" * 32}}})
        (export / "pipeline").mkdir()
        for name, entries in (
            ("signed.ipa", {"Synthetic": signed, "_CodeSignature/CodeResources": seal,
                            "embedded.mobileprovision": b"profile",
                            "Frameworks/Test.framework/Test": signed}),
            ("source-unsigned.ipa", {"Synthetic": unsigned,
                                     "Frameworks/Test.framework/Test": unsigned}),
        ):
            with zipfile.ZipFile(export / "pipeline" / name, "w") as archive:
                archive.writestr("Payload/Synthetic.app/Info.plist", information)
                archive.writestr("Payload/Synthetic.app/asset.dat", b"resource")
                archive.writestr("Payload/Synthetic.app/Frameworks/Test.framework/Info.plist",
                                 nested_information)
                for path, content in entries.items():
                    archive.writestr(f"Payload/Synthetic.app/{path}", content)
        (export / "manifest-pipeline.json").write_text(json.dumps({
            "schema": 1, "producer": "self-test", "mutations": [],
            "artifacts": [{
                "id": "pipeline-ipa", "kind": "ipa", "status": "signed",
                "file": "pipeline/signed.ipa", "unsignedFile": "pipeline/source-unsigned.ipa",
                "certificateFile": "pipeline/certificate.der",
                "identifier": "com.example.synthetic", "zynsignVerdict": "accepted",
                "detail": "self-test", "bundlePath": "Payload/Synthetic.app",
                "executable": "Synthetic", "nestedBundles": ["Frameworks/Test.framework"]}],
        }))
        work = root / "work"
        work.mkdir()
        session = Session(export, work, Tools.unavailable())
        report = analyze(session, export_status=0, require_tools=False)
        assert report["harnessErrors"] == [], report["harnessErrors"]
        by_id = {artifact["id"]: artifact for artifact in report["artifacts"]}
        plain = by_id["single-plain"]
        assert plain["codesign"]["verify"]["verdict"] == "unavailable"
        assert [rule["result"] for rule in plain["binary"]["rules"]] == ["fail", "not-applicable"]
        assert by_id["refused-example"]["refused"] is True
        container = by_id["pipeline-ipa"]
        assert container["extraction"]["tool"] == "zipfile"
        assert container["codeResources"]["topLevelKeys"] == ["files2"]
        assert container["nested"]["Frameworks/Test.framework"]["binary"]["rules"][-1]["id"] == "R3"
        assert container["referenceDifferences"] is None
        assert [row["codesign"] for row in container["bundleMutations"]] == ["unavailable"] * 5
        assert [row["signer"] for row in container["bundleObservations"]] == ["ZynSign"] * 2
        assert report["mutations"][0]["meaningful"] is False
        markdown = render_markdown(report)
        assert "# External validation report" in markdown and "R1 fail" in markdown
        json.dumps(report)
        assert all(command.startswith("::notice") for command in notices(report))
        missing = analyze(Session(root / "empty", work, Tools.unavailable()), export_status=65,
                          require_tools=True)
        assert len(missing["harnessErrors"]) == 2 + len(Tools.NAMES), missing["harnessErrors"]

    print("PASS: signature parser on the committed ZS-026 vector (layout, SuperBlob, "
          "CodeDirectory fields, CMS bytes)")
    print("PASS: Apple-documented iOS format rules R1-R3 on the vector and synthetic "
          "CodeDirectories")
    print("PASS: otool, codesign, and xcodebuild output parsing; reference comparison; "
          "report rendering and harness-error accounting")
    print("Not an Apple tooling run: the verdicts come from `run` on macOS")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subcommands = parser.add_subparsers(dest="command", required=True)
    run = subcommands.add_parser("run", help="analyze an export directory")
    run.add_argument("--export-dir", required=True)
    run.add_argument("--report-dir", required=True)
    run.add_argument("--export-status", type=int, default=None,
                     help="exit status of the export step; non-zero is a harness error")
    run.add_argument("--allow-missing-tools", action="store_true",
                     help="record missing tools as unavailable instead of harness errors")
    run.set_defaults(handler=command_run)
    self_test = subcommands.add_parser("self-test", help="check the harness on any host")
    self_test.set_defaults(handler=command_self_test)
    annotate = subcommands.add_parser("annotate-xcodebuild",
                                      help="surface xcodebuild errors as annotations")
    annotate.add_argument("log")
    annotate.set_defaults(handler=command_annotate_xcodebuild)
    arguments = parser.parse_args(argv)
    return arguments.handler(arguments)


if __name__ == "__main__":
    sys.exit(main())
