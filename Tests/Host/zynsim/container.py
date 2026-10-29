"""Guest containers: an app that runs inside ZynSign instead of being installed.

Two edits make a guest loadable, and both happen before it is signed:

1. the Mach-O file type changes from ``MH_EXECUTE`` to ``MH_DYLIB``, because a
   process maps a library rather than starting a second ``LC_MAIN`` image;
2. the loader is added as an ``LC_LOAD_DYLIB`` so dyld runs its initialiser
   before the guest's entry point is called.

What is left is bookkeeping: a per-app data directory the guest writes into, a
``ZynGuestInfo.plist`` the host reads at launch, a manifest, and a tweak folder.
The launch itself is the one part that cannot be verified here — it needs a
device and a host allowed to map guest images — so it is emitted as an explicit
plan, and the plan says ``BLOCKED`` at its head when a prerequisite is missing.
"""

from __future__ import annotations

import json
import plistlib
from dataclasses import dataclass, field

from . import bundle as bundle_module
from . import codesign, macho

LOADER_NAME = "TweakLoader.dylib"
LOADER_INSTALL_NAME = f"@executable_path/Frameworks/{LOADER_NAME}"
CONTAINER_VERSION = 1
MAXIMUM_GUEST_BYTES = 512 * 1024 * 1024


class ContainerError(ValueError):
    """The guest cannot be prepared as asked."""


@dataclass
class Block:
    """One reason a guest cannot run, with the fact that established it."""

    code: str
    detail: str


@dataclass
class GuestAssessment:
    bundle_id: str
    version: str
    blocks: list[Block] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def runnable(self) -> bool:
        return not self.blocks

    # The names the interface uses.
    @property
    def can_run(self) -> bool:
        return self.runnable

    @property
    def blocked(self) -> list[str]:
        return [block.detail for block in self.blocks]


@dataclass
class ContainerResult:
    entries: dict[str, bytes]
    bundle_id: str
    root: str
    signed_binaries: list[str]
    assessment: GuestAssessment
    launch_plan: list[str]
    metadata: dict

    @property
    def verified(self) -> bool:
        return all(codesign.verify_image(data).valid
                   for _path, data in self._images())

    def _images(self):
        for path, data in self.entries.items():
            if data[:4] not in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
                continue
            if macho.MachO(data).code_signature_command() is not None:
                yield path, data


def _load(ipa) -> tuple[dict[str, bytes], str]:
    if isinstance(ipa, bundle_module.IPABundle):
        entries = dict(ipa.entries)
    elif isinstance(ipa, (bytes, bytearray)):
        entries = dict(bundle_module.IPABundle.from_bytes(bytes(ipa)).entries)
    else:
        raise ContainerError("a container is prepared from an IPA's bytes or an IPABundle")
    if sum(len(value) for value in entries.values()) > MAXIMUM_GUEST_BYTES:
        raise ContainerError("the guest is larger than a container will hold")
    for path in entries:
        parts = path.split("/")
        if path.startswith("Payload/") and len(parts) > 1 and parts[1].endswith(".app"):
            return entries, f"Payload/{parts[1]}"
    raise ContainerError("the package holds no app bundle")


def assess_guest(ipa, *, loader: bytes | None = None) -> GuestAssessment:
    """What stands between this guest and a launch, stated as facts."""
    entries, app = _load(ipa)
    info = plistlib.loads(entries[f"{app}/Info.plist"])
    bundle_id = str(info.get("CFBundleIdentifier", ""))
    version = str(info.get("CFBundleShortVersionString", ""))
    executable = info.get("CFBundleExecutable")
    assessment = GuestAssessment(bundle_id=bundle_id, version=version)
    if not executable or f"{app}/{executable}" not in entries:
        assessment.blocks.append(Block("missingExecutable",
                                       "the bundle declares an executable it does not contain"))
        return assessment

    for path in entries:
        if not path.startswith(app + "/"):
            continue
        relative = path[len(app) + 1:]
        if relative.endswith(".appex") or relative.startswith("PlugIns/"):
            if not any(block.code == "appExtensions" for block in assessment.blocks):
                assessment.blocks.append(Block(
                    "appExtensions",
                    f"{relative} is an app extension; a container runs one bundle, so it must be removed first"))
        if relative.startswith("Watch/") or relative.startswith("WatchKit/"):
            if not any(block.code == "watchApp" for block in assessment.blocks):
                assessment.blocks.append(Block(
                    "watchApp", f"{relative} is a watchOS bundle and cannot load in an iOS process"))

    image = macho.MachO(entries[f"{app}/{executable}"])
    if _cryptid(image) != 0:
        assessment.blocks.append(Block(
            "fairplayEncrypted",
            "the guest executable is FairPlay-encrypted; only a decrypted image can be mapped"))
    if not image.flags & 0x200000:
        assessment.blocks.append(Block(
            "notPositionIndependent",
            "the guest executable is not position independent, so it cannot be mapped as a library"))
    if image.filetype != macho.MH_EXECUTE:
        assessment.blocks.append(Block("notExecutable", "the declared executable is not MH_EXECUTE"))
    needed = macho.align(24 + len(LOADER_INSTALL_NAME) + 1, 8)
    if image.header_padding() < needed:
        assessment.blocks.append(Block(
            "insufficientHeaderSpace",
            f"the guest header has {image.header_padding()} bytes of padding, the loader command needs {needed}"))
    if loader is None:
        assessment.warnings.append(
            "no TweakLoader is bundled, so tweaks cannot run in the guest")
    return assessment


def _cryptid(image: macho.MachO) -> int:
    for command in image.commands:
        if command.type == 0x2C:  # LC_ENCRYPTION_INFO_64
            return int.from_bytes(image.data[command.offset + 16:command.offset + 20], "little")
    return 0


def prepare_container(ipa, *, loader: bytes | None = None, tweaks: dict[str, bytes] | None = None,
                      rename: bundle_module.Overrides | None = None,
                      identity=None, version: int = 0x20400) -> ContainerResult:
    """Move an app's bundle under ``Applications/<id>/App.app`` and sign it."""
    entries, app = _load(ipa)
    assessment = assess_guest(bundle_module.IPABundle(entries), loader=loader)
    if assessment.blocks:
        raise ContainerError(f"the guest cannot run: {assessment.blocks[0].detail}")

    if rename is not None:
        package = bundle_module.IPABundle(entries)
        package.apply_overrides(rename)
        entries = dict(package.entries)
    bundle_id = str(plistlib.loads(entries[f"{app}/Info.plist"])["CFBundleIdentifier"])
    executable = str(plistlib.loads(entries[f"{app}/Info.plist"])["CFBundleExecutable"])

    root = f"Applications/{bundle_id}"
    container: dict[str, bytes] = {}
    for path, content in entries.items():
        if path.startswith(app + "/"):
            container[f"{root}/App.app/{path[len(app) + 1:]}"] = content

    guest_prefix = f"{root}/App.app/"
    source_paths: dict[str, str] = {f"{guest_prefix}{path[len(app) + 1:]}": path
                                    for path in entries if path.startswith(app + "/")}
    signed: list[str] = []

    if loader is not None:
        loader_path = f"{guest_prefix}Frameworks/{LOADER_NAME}"
        container[loader_path] = loader
        _sign(container, loader_path, bundle_id, version, identity)
        signed.append(source_paths.get(loader_path, loader_path))

    for path in sorted(container):
        content = container[path]
        if content[:4] not in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
            continue
        if path == f"{guest_prefix}Frameworks/{LOADER_NAME}":
            continue
        image = macho.MachO(content)
        if path == f"{guest_prefix}{executable}":
            image.set_filetype(macho.MH_DYLIB)
            image.inject_dylib(LOADER_INSTALL_NAME)
        _sign(container, path, bundle_id, version, identity, image=image)
        signed.append(source_paths[path])

    tweak_names = []
    for name, content in (tweaks or {}).items():
        path = f"{root}/Tweaks/{name}"
        container[path] = content
        _sign(container, path, bundle_id, version, identity)
        signed.append(source_paths.get(path, path))
        tweak_names.append(name)

    for directory in ("Data/Documents", "Data/Library/Caches", "Data/Library/Preferences", "Data/tmp"):
        container[f"{root}/{directory}/.keep"] = b""

    metadata = {
        "ZynBundleId": bundle_id,
        "ZynBundleName": str(plistlib.loads(entries[f"{app}/Info.plist"]).get("CFBundleName", executable)),
        "ZynDisplayName": str(plistlib.loads(entries[f"{app}/Info.plist"]).get("CFBundleDisplayName", executable)),
        "ZynGuestPath": f"{root}/App.app",
        "ZynExecutable": executable,
        "ZynDataPath": f"{root}/Data",
        "ZynSignature": "adhoc" if identity is None else "certificate",
        "ZynContainerVersion": CONTAINER_VERSION,
        "ZynLoader": LOADER_INSTALL_NAME,
        "ZynTweaks": tweak_names,
        "ZynGuestVersion": str(plistlib.loads(entries[f"{app}/Info.plist"]).get("CFBundleShortVersionString", "")),
        "ZynNeedsJIT": bool(plistlib.loads(entries[f"{app}/Info.plist"]).get("ZynNeedsJIT", False)),
    }
    container[f"{root}/ZynGuestInfo.plist"] = plistlib.dumps(metadata)
    container[f"{root}/ZynContainer.json"] = json.dumps({
        "version": CONTAINER_VERSION,
        "bundleIdentifier": bundle_id,
        "guest": f"{root}/App.app",
        "data": f"{root}/Data",
        "tweaks": f"{root}/Tweaks",
        "loader": LOADER_NAME,
        "entryPoint": "main",
        "signature": metadata["ZynSignature"],
    }, indent=2, sort_keys=True).encode()

    return ContainerResult(
        entries=container,
        bundle_id=bundle_id,
        root=root,
        signed_binaries=signed,
        assessment=assessment,
        launch_plan=launch_plan(bundle_id, executable, root, loader_present=loader is not None),
        metadata=metadata,
    )


def _sign(container: dict[str, bytes], path: str, identifier: str, version: int,
          identity, image: macho.MachO | None = None) -> None:
    image = image or macho.MachO(container[path])
    options = codesign.SigningOptions(
        identifier=identifier, adhoc=identity is None, identity=identity, version=version,
        entitlements_xml=_guest_entitlements(identifier),
        entitlements_der=_guest_entitlements_der(identifier) if version >= 0x20400 else None,
    )
    signed, _ = codesign.sign_image(image.bytes(), options)
    container[path] = signed


def _guest_entitlements(identifier: str) -> bytes:
    return plistlib.dumps({
        "application-identifier": identifier,
        "get-task-allow": True,
        "com.apple.security.get-task-allow": True,
    }, fmt=plistlib.FMT_XML, sort_keys=True)


def _guest_entitlements_der(identifier: str) -> bytes:
    from . import profile
    return profile.der_entitlements({
        "application-identifier": identifier,
        "get-task-allow": True,
        "com.apple.security.get-task-allow": True,
    })


def launch_plan(bundle_id: str, executable: str, root: str, *, loader_present: bool = True) -> list[str]:
    guest = f"{root}/App.app/{executable}"
    steps = [
        f"1. Map the guest: dlopen(\"{guest}\", RTLD_NOW | RTLD_LOCAL)",
        "2. Resolve the entry point: dlsym(handle, \"main\")",
        f"3. Redirect the guest's container path to {root}/Data via NSHomeDirectory",
        "4. Call the entry point on the main thread with the launch arguments",
        f"5. Swizzle NSBundle.mainBundle and UIApplication's delegate for {bundle_id}",
        f"6. Register the guest's URL schemes behind the {bundle_id} identifier",
    ]
    if not loader_present:
        return [
            "BLOCKED: no TweakLoader is bundled, so step 1 would map a guest whose initialisers never run",
            *steps,
        ]
    return steps
