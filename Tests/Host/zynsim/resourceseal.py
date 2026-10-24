"""`_CodeSignature/CodeResources`: the resource seal of one bundle.

The seal is a property list with two parallel dictionaries:

``files``    version 1 — SHA-1 of each resource, plus the bundle's ``Info.plist``
             and ``PkgInfo`` under their own keys.
``files2``   version 2 — SHA-256 for a plain file (``hash2``), the code
             directory hash of a nested binary (``cdhash``), or a
             ``symlink`` target.

``rules``/``rules2`` are the patterns Apple's signer writes. They are not
decoration: the rules are what tell a verifier which entries are *nested code*
(sealed by ``cdhash``, and whose own contents are covered by their own seal)
and which are *omitted* (``Info.plist``, ``PkgInfo``, and the seal itself). A
seal that lists a framework's files individually — instead of one ``cdhash``
for the framework — passes a naive check and fails `codesign --verify --deep
--strict`, because the verifier applies the rules, not our intentions.

`lproj` directories are the other trap: a localised ``.strings`` file is
listed inside ``files2`` under the ``en.lproj/…`` key *and* matched by the
rule, and a seal that omits it because "it is inside a folder" is wrong.
"""

from __future__ import annotations

import hashlib
import plistlib

#: Directories whose contents are nested code rather than resources.
NESTED_CODE_PREFIXES = (
    "Frameworks/",
    "SharedFrameworks/",
    "PlugIns/",
    "Plug-ins/",
    "XPCServices/",
    "Helpers/",
    "MacOS/",
    "Library/Automator/",
    "Library/Spotlight/",
    "Library/LoginItems/",
)

#: Files the seal deliberately does not cover.
OMITTED_FILES = ("Info.plist", "PkgInfo", "embedded.provisionprofile")

#: Directory suffixes that make a directory nested code: one ``cdhash`` covers
#: the bundle, and nothing inside it is sealed individually.
NESTED_BUNDLE_SUFFIXES = (".appex", ".framework", ".bundle", ".xpc", ".app")

#: Entries a seal never lists: it is the seal, and the signature is the seal's.
OMITTED_PREFIXES = ("_CodeSignature/", "CodeResources")

RULES = {
    "^.*": True,
    "^[^/]+$": {"nested": True, "weight": 10},
    "^(Frameworks|SharedFrameworks|PlugIns|Plug-ins|XPCServices|Helpers|MacOS|Library/(Automator|Spotlight|LoginItems))/":
        {"nested": True, "weight": 10},
    "^.*\\.dSYM($|/)": {"weight": 11},
    "^(.*/)?\\.DS_Store$": {"omit": True, "weight": 2000},
    "^Info\\.plist$": {"omit": True, "weight": 20},
    "^PkgInfo$": {"omit": True, "weight": 20},
    "^embedded\\.provisionprofile$": {"weight": 20},
    "^version\\.plist$": {"weight": 20},
    "^_MASReceipt/": {"omit": True, "weight": 90},
}

RULES2 = {
    "^.*": True,
    "^[^/]+$": {"nested": True, "weight": 10},
    "^(Frameworks|SharedFrameworks|PlugIns|Plug-ins|XPCServices|Helpers|MacOS|Library/(Automator|Spotlight|LoginItems))/":
        {"nested": True, "weight": 10},
    "^.*\\.dSYM($|/)": {"weight": 11},
    "^(.*/)?\\.DS_Store$": {"omit": True, "weight": 2000},
    "^(.*/)?\\.lproj/": {"optional": True, "weight": 1000},
    "^Info\\.plist$": {"omit": True, "weight": 20},
    "^PkgInfo$": {"omit": True, "weight": 20},
    "^embedded\\.provisionprofile$": {"weight": 20},
    "^version\\.plist$": {"weight": 20},
    "^_MASReceipt/": {"omit": True, "weight": 90},
}


def cdhash(code_directory: bytes) -> bytes:
    """The code directory hash a seal stores for nested code.

    ``cdhash`` is the first 20 bytes of the SHA-256 of the CodeDirectory blob.
    It is deliberately shorter than the digest: the field predates SHA-256 and
    kept its width.
    """
    return hashlib.sha256(code_directory).digest()[:20]


def is_nested_code(relative_path: str) -> bool:
    return relative_path.startswith(NESTED_CODE_PREFIXES)


def nested_bundle_roots(paths, *, prefix: str = "") -> list[str]:
    """Relative paths of the nested bundles inside one app bundle.

    A ``.framework``, ``.appex`` or ``.bundle`` directory is a bundle: the
    container's seal records one ``cdhash`` for it and says nothing about its
    contents, because the bundle has its own seal. Listing its files instead is
    the mistake a strict verifier catches.
    """
    roots: set[str] = set()
    for path in paths:
        if prefix and not path.startswith(prefix):
            continue
        relative = path[len(prefix):] if prefix else path
        parts = relative.split("/")
        for index, part in enumerate(parts[:-1]):
            if part.endswith(NESTED_BUNDLE_SUFFIXES):
                roots.add("/".join(parts[:index + 1]))
                break
    return sorted(roots)


def is_omitted(relative_path: str) -> bool:
    if relative_path.startswith(OMITTED_PREFIXES):
        return True
    if "/" not in relative_path and relative_path in OMITTED_FILES:
        return True
    name = relative_path.rsplit("/", 1)[-1]
    return name == ".DS_Store"


def build(entries: dict[str, bytes], *, bundle_prefix: str, executable: str | None,
          cdhashes: dict[str, bytes] | None = None) -> dict:
    """Seal one bundle: ``Entries/<bundle_prefix>/…`` → plist payload.

    ``cdhashes`` maps bundle-relative paths of nested code to their code
    directory hash. A nested binary without one is a programming error: the
    seal would then hash the binary as a resource, which is what a strict
    verifier rejects.
    """
    cdhashes = cdhashes or {}
    files: dict[str, dict] = {}
    files2: dict[str, object] = {}
    prefix = bundle_prefix + "/" if bundle_prefix else ""
    roots = set(cdhashes)
    # A nested bundle is a directory, so it has no file entry of its own; its
    # single cdhash entry is written here.
    for root, cdhash_value in sorted(cdhashes.items()):
        files2[root] = {"cdhash": cdhash_value}
        files[root] = {"hash": cdhash_value[:16]}
    for path in sorted(entries):
        if not path.startswith(prefix):
            continue
        relative = path[len(prefix):]
        if not relative or is_omitted(relative):
            continue
        if path == executable:
            continue
        # Anything inside a nested bundle is covered by that bundle's cdhash.
        if any(relative == root or relative.startswith(root + "/") for root in roots):
            continue
        content = entries[path]
        files[relative] = {"hash": hashlib.sha1(content).digest()}
        files2[relative] = {"hash2": hashlib.sha256(content).digest()}
    # `Info.plist` is omitted from the per-file rules but present in v1 under
    # its own key, because that is how Apple's signer writes it.
    info_key = f"{prefix}Info.plist"
    if info_key in entries:
        files["Info.plist"] = {"hash": hashlib.sha1(entries[info_key]).digest()}
    files2["Info.plist"] = {"hash2": hashlib.sha256(entries[info_key]).digest()} if info_key in entries else {}
    if not files2.get("Info.plist"):
        files2.pop("Info.plist", None)
    return {
        "files": files,
        "files2": files2,
        "rules": RULES,
        "rules2": RULES2,
    }


def serialize(seal: dict) -> bytes:
    return plistlib.dumps(seal, fmt=plistlib.FMT_XML, sort_keys=True)


def verify(seal_bytes: bytes, entries: dict[str, bytes], *, bundle_prefix: str,
           executable: str | None, cdhashes: dict[str, bytes] | None = None) -> list[str]:
    """Check a seal against the bundle's actual contents.

    Returns the problems found — an empty list means the seal agrees with the
    bundle. This is the check `codesign --verify --deep --strict` performs for
    resources, done here so it can run without macOS.
    """
    cdhashes = cdhashes or {}
    try:
        seal = plistlib.loads(seal_bytes)
    except Exception as error:  # noqa: BLE001 - a broken seal is a finding, not a crash
        return [f"the resource seal does not parse: {error}"]
    problems: list[str] = []
    for key in ("files", "files2", "rules", "rules2"):
        if key not in seal:
            problems.append(f"the seal has no {key} dictionary")
    files2 = seal.get("files2", {})
    if not isinstance(files2, dict):
        return problems + ["files2 is not a dictionary"]

    prefix = bundle_prefix + "/" if bundle_prefix else ""
    roots = set(cdhashes)
    expected: dict[str, object] = {root: {"cdhash": value} for root, value in cdhashes.items()}
    for path in sorted(entries):
        if not path.startswith(prefix):
            continue
        relative = path[len(prefix):]
        if not relative or is_omitted(relative) or path == executable:
            continue
        if any(relative == root or relative.startswith(root + "/") for root in roots):
            continue
        expected[relative] = {"hash2": hashlib.sha256(entries[path]).digest()}

    for relative, value in expected.items():
        recorded = files2.get(relative)
        if recorded is None:
            problems.append(f"{relative} is not sealed")
            continue
        if isinstance(recorded, dict) and "cdhash" in recorded:
            if recorded["cdhash"] != value.get("cdhash"):
                problems.append(f"{relative} records a different code directory hash")
        elif isinstance(recorded, dict) and "hash2" in recorded:
            if recorded["hash2"] != value.get("hash2"):
                problems.append(f"{relative} does not match its sealed digest")
        else:
            problems.append(f"{relative} is sealed in an unrecognised form")

    for relative in files2:
        if relative == "Info.plist":
            continue
        if relative not in expected:
            problems.append(f"{relative} is sealed but not present in the bundle")

    if "Info.plist" in seal.get("files", {}):
        info_key = f"{prefix}Info.plist"
        if info_key in entries:
            recorded = seal["files"]["Info.plist"].get("hash")
            if recorded != hashlib.sha1(entries[info_key]).digest():
                problems.append("the sealed Info.plist digest does not match the bundle's")
    return problems
