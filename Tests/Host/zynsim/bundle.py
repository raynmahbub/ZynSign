"""Signing a whole app bundle: overrides, nested code, and the resource seal.

The order is not negotiable. Nested code is signed before the code that
contains it, because the outer CodeDirectory hashes the files it contains; the
resource seal is written after every binary, because it hashes what is left.
Overrides and removals happen before either, because they change what gets
hashed.

The bundle model is deliberately a dictionary of path → bytes. That keeps the
transformations pure and reviewable: every step returns a new mapping, nothing
is edited in place, and a failure leaves the caller's input untouched.
"""

from __future__ import annotations

import hashlib
import io
import plistlib
import zipfile
from dataclasses import dataclass, field

from . import codesign, fixtures, macho, profile

MAXIMUM_ENTRIES = 20000
MAXIMUM_TOTAL_BYTES = 512 * 1024 * 1024


class BundleError(ValueError):
    """The package cannot be signed as asked."""


@dataclass
class Overrides:
    """What a user may change about a package while signing it.

    Defaults change nothing. Every field is optional so the pipeline can record
    exactly which edits were requested, and the report can say which were made.
    """

    bundle_id: str | None = None
    display_name: str | None = None
    name: str | None = None
    short_version: str | None = None
    version: str | None = None
    minimum_os: str | None = None
    remove_plugins: bool = False
    remove_watch_apps: bool = False
    remove_extensions: bool = False
    remove_url_schemes: bool = False
    injected_libraries: list[tuple[str, bool]] = field(default_factory=list)
    inject_into_nested: bool = False

    @property
    def is_empty(self) -> bool:
        return not any((self.bundle_id, self.display_name, self.name, self.short_version,
                        self.version, self.minimum_os, self.remove_plugins,
                        self.remove_watch_apps, self.remove_extensions,
                        self.remove_url_schemes, self.injected_libraries))


@dataclass
class SignedBinary:
    path: str
    identifier: str
    adhoc: bool
    injected: list[str]
    size_before: int
    size_after: int

    @property
    def report(self) -> str:
        mode = "ad-hoc" if self.adhoc else "certificate"
        injected = f", injected {self.injected}" if self.injected else ""
        return f"{self.path}: {mode}{injected}, {self.size_before} → {self.size_after} bytes"


@dataclass
class SigningOutcome:
    data: bytes
    bundle_id: str
    binaries: list[SignedBinary]
    verification: list[codesign.VerificationReport]
    removed: list[str]
    entitlements: dict[str, dict]

    @property
    def verified(self) -> bool:
        return all(report.valid for report in self.verification)


class IPABundle:
    """An IPA held as an entry table, with the bundle paths derived from it."""

    def __init__(self, entries: dict[str, bytes]):
        if len(entries) > MAXIMUM_ENTRIES:
            raise BundleError("the package has more entries than this engine will read")
        total = sum(len(value) for value in entries.values())
        if total > MAXIMUM_TOTAL_BYTES:
            raise BundleError("the package is larger than this engine will read")
        self.entries = dict(entries)

    @classmethod
    def from_bytes(cls, data: bytes) -> "IPABundle":
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                entries = {info.filename: archive.read(info)
                           for info in archive.infolist() if not info.is_dir()}
        except zipfile.BadZipFile as error:
            raise BundleError("the package is not a readable ZIP archive") from error
        bundle = cls(entries)
        bundle.main_app()
        return bundle

    def to_bytes(self) -> bytes:
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(self.entries):
                info = zipfile.ZipInfo(path, date_time=(2024, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                archive.writestr(info, self.entries[path])
        return buffer.getvalue()

    # MARK: - Structure

    def app_containers(self) -> list[tuple[str, str]]:
        """(bundle directory, executable relative to it) for every app bundle."""
        bundles = []
        for path in self.entries:
            parts = path.split("/")
            if not path.startswith("Payload/"):
                continue
            for index, part in enumerate(parts):
                if part.endswith(".app") or part.endswith(".appex"):
                    directory = "/".join(parts[:index + 1])
                    if any(directory == existing for existing, _ in bundles):
                        continue
                    executable = self._executable_name(directory)
                    if executable:
                        bundles.append((directory, executable))
                    break
        return bundles

    def main_app(self) -> str:
        candidates = [path.split("/")[1] for path in self.entries
                      if path.startswith("Payload/") and path.split("/")[1].endswith(".app")]
        unique = sorted(set(candidates))
        if len(unique) != 1:
            raise BundleError(f"the package holds {len(unique)} app bundles, not one")
        return f"Payload/{unique[0]}"

    def _executable_name(self, directory: str) -> str | None:
        info_key = f"{directory}/Info.plist"
        if info_key not in self.entries:
            return None
        try:
            info = plistlib.loads(self.entries[info_key])
        except Exception:  # noqa: BLE001 - a broken plist is reported by inspection, not here
            return None
        name = info.get("CFBundleExecutable")
        return str(name) if isinstance(name, str) else None

    def executable_path(self, directory: str) -> str | None:
        name = self._executable_name(directory)
        if name is None:
            return None
        path = f"{directory}/{name}"
        return path if path in self.entries else None

    def main_executable(self) -> str:
        app = self.main_app()
        path = self.executable_path(app)
        if path is None:
            raise BundleError("the main bundle declares no executable the package contains")
        return path

    def bundle_identifier(self) -> str:
        info = plistlib.loads(self.entries[f"{self.main_app()}/Info.plist"])
        identifier = info.get("CFBundleIdentifier")
        if not isinstance(identifier, str) or not identifier:
            raise BundleError("the main bundle has no identifier")
        return identifier

    def macho_files(self) -> dict[str, bytes]:
        """Every entry that starts with a thin Mach-O magic."""
        magics = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe")
        return {path: content for path, content in self.entries.items()
                if content[:4] in magics}

    # MARK: - Edits

    def apply_overrides(self, overrides: Overrides) -> list[str]:
        """Rewrite Info.plist values; returns a human-readable change list."""
        changes: list[str] = []
        app = self.main_app()
        info_path = f"{app}/Info.plist"
        if info_path not in self.entries:
            raise BundleError("the main bundle has no Info.plist")
        info = plistlib.loads(self.entries[info_path])
        original_identifier = info.get("CFBundleIdentifier")
        for key, value, label in (
            ("CFBundleIdentifier", overrides.bundle_id, "bundle identifier"),
            ("CFBundleDisplayName", overrides.display_name, "display name"),
            ("CFBundleName", overrides.name, "name"),
            ("CFBundleShortVersionString", overrides.short_version, "version"),
            ("CFBundleVersion", overrides.version, "build"),
            ("MinimumOSVersion", overrides.minimum_os, "minimum iOS"),
        ):
            if value is None:
                continue
            if not value:
                raise BundleError(f"the {label} override is empty")
            info[key] = value
            changes.append(f"{label} → {value}")
        if overrides.remove_url_schemes:
            info.pop("CFBundleURLTypes", None)
            info.pop("LSApplicationQueriesSchemes", None)
            changes.append("URL schemes removed")

        # Nested bundles follow the main identifier, because iOS requires an
        # extension's identifier to be prefixed by its host's.
        if overrides.bundle_id and original_identifier and original_identifier != overrides.bundle_id:
            for directory, _ in self.app_containers():
                if directory == app:
                    continue
                nested_info_path = f"{directory}/Info.plist"
                if nested_info_path not in self.entries:
                    continue
                nested_info = plistlib.loads(self.entries[nested_info_path])
                nested_identifier = nested_info.get("CFBundleIdentifier")
                if not isinstance(nested_identifier, str):
                    continue
                suffix = nested_identifier[len(str(original_identifier)):]
                nested_info["CFBundleIdentifier"] = overrides.bundle_id + suffix
                self.entries[nested_info_path] = plistlib.dumps(nested_info)
                changes.append(f"nested identifier → {nested_info['CFBundleIdentifier']}")
        self.entries[info_path] = plistlib.dumps(info)
        return changes

    def remove_nested_bundles(self, overrides: Overrides) -> list[str]:
        removed: list[str] = []
        prefixes = []
        if overrides.remove_extensions:
            prefixes.append("PlugIns/")
        if overrides.remove_plugins:
            prefixes.extend(("PlugIns/", "Extensions/"))
        if overrides.remove_watch_apps:
            prefixes.extend(("Watch/", "WatchKit/"))
        if not prefixes:
            return removed
        app = self.main_app()
        for path in list(self.entries):
            if not path.startswith(app + "/"):
                continue
            relative = path[len(app) + 1:]
            if any(relative.startswith(prefix) for prefix in prefixes):
                del self.entries[path]
                removed.append(path)
        if overrides.remove_extensions:
            # A widget that stayed in the identifier cascade would now point at
            # an app that no longer exists, so the two edits travel together.
            removed.extend(self._remove_extension_declarations(app))
        return removed

    def _remove_extension_declarations(self, app: str) -> list[str]:
        info_path = f"{app}/Info.plist"
        info = plistlib.loads(self.entries[info_path])
        if "PlugIns" not in info:
            return []
        del info["PlugIns"]
        self.entries[info_path] = plistlib.dumps(info)
        return ["Info.plist: PlugIns declaration removed"]

    # MARK: - Signing

    def _entitlements(self, profile_object: profile.ProvisioningProfile | None,
                      bundle_identifier: str, nested: bool) -> dict:
        if profile_object is None:
            return {}
        return profile_object.entitlements_for(bundle_identifier, nested=nested)

    def sign(self, identity, profile_object: profile.ProvisioningProfile | None = None,
             overrides: Overrides | None = None, version: int = 0x20400) -> SigningOutcome:
        overrides = overrides or Overrides()
        changes = self.apply_overrides(overrides)
        # A profile is an authorisation, not a suggestion: signing an
        # identifier it does not cover produces a package no device accepts,
        # so the refusal happens here rather than after an upload.
        if profile_object is not None:
            identifier = self.bundle_identifier()
            if not profile_object.matches(identifier):
                raise BundleError(
                    f"the profile authorises {profile_object.app_id}, not {identifier}")
            if profile_object.is_expired:
                raise BundleError(
                    f"the profile expired on {profile_object.expiration:%Y-%m-%d}")
        removed = self.remove_nested_bundles(overrides)
        app = self.main_app()
        main_identifier = self.bundle_identifier()  # after the overrides
        binaries: list[SignedBinary] = []
        entitlements_by_path: dict[str, dict] = {}

        # Deepest bundle first: an outer signature covers what is inside it.
        containers = sorted(self.app_containers(), key=lambda item: item[0].count("/"), reverse=True)
        seen: set[str] = set()
        for directory, _ in containers:
            identifier = self.bundle_identifier_of(directory)
            nested = directory != app
            entitlements = self._entitlements(profile_object, identifier, nested)
            # A library is injected into the main executable unless the caller
            # asked for nested images too — the same default zsign uses.
            wants_injection = not nested or overrides.inject_into_nested
            injection = overrides.injected_libraries if wants_injection else []
            self._sign_directory(directory, identifier, identity, entitlements,
                                 injection, version, binaries, entitlements_by_path,
                                 inject_into_libraries=overrides.inject_into_nested)
            seen.add(self.executable_path(directory) or "")
        # Frameworks and loose dylibs are not bundles; they are still code.
        for path, content in list(self.macho_files().items()):
            if path in seen or path in entitlements_by_path:
                continue
            if path.endswith("/Info.plist"):
                continue
            if not self._is_nested_code(path):
                continue
            entitlements = self._entitlements(profile_object, main_identifier, True)
            self._sign_image_entry(path, main_identifier, identity, entitlements,
                                   overrides.injected_libraries if overrides.inject_into_nested else [],
                                   version, binaries, entitlements_by_path)
        self._write_resource_seals()
        data = self.to_bytes()
        verification = []
        for binary in binaries:
            verification.append(self._verify_entry(binary.path))
        return SigningOutcome(data=data, bundle_id=main_identifier, binaries=binaries,
                              verification=verification, removed=removed,
                              entitlements=entitlements_by_path)

    def _sign_directory(self, directory: str, identifier: str, identity,
                        entitlements: dict, injection: list[tuple[str, bool]], version: int,
                        binaries: list[SignedBinary], entitlements_by_path: dict,
                        *, inject_into_libraries: bool) -> None:
        executable = self.executable_path(directory)
        if executable is not None:
            self._sign_image_entry(executable, identifier, identity, entitlements, injection,
                                   version, binaries, entitlements_by_path)
        for path in sorted(self.entries):
            if not path.startswith(directory + "/"):
                continue
            if path == executable or not self._is_nested_code(path):
                continue
            if path in entitlements_by_path:
                continue
            # A library inside a bundle is signed, but the tweak is not linked
            # into it: the loader belongs on the image whose entry point runs.
            self._sign_image_entry(path, identifier, identity, entitlements,
                                   injection if inject_into_libraries else [],
                                   version, binaries, entitlements_by_path)

    def _is_nested_code(self, path: str) -> bool:
        content = self.entries.get(path, b"")
        if content[:4] not in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
            return False
        return True

    def _sign_image_entry(self, path: str, identifier: str, identity, entitlements: dict,
                          injection: list[tuple[str, bool]], version: int,
                          binaries: list[SignedBinary], entitlements_by_path: dict) -> None:
        content = self.entries[path]
        try:
            image = macho.MachO(content)
        except macho.MachOError as error:
            raise BundleError(f"{path}: {error}") from error
        if image.code_signature_command() is not None:
            raise BundleError(f"{path} already carries a signature")
        injected = []
        for install_name, weak in injection:
            try:
                image.inject_dylib(install_name, weak)
            except macho.MachOError as error:
                raise BundleError(f"{path}: {error}") from error
            injected.append(install_name)
        if entitlements:
            options = codesign.SigningOptions(
                identifier=identifier,
                team_id=entitlements.get("com.apple.developer.team-identifier")
                or entitlements.get("application-identifier", ".").split(".", 1)[0],
                entitlements_xml=profile.entitlements_xml(entitlements),
                entitlements_der=profile.der_entitlements(entitlements) if version >= 0x20400 else None,
                identity=identity,
                adhoc=identity is None,
                version=version,
            )
        else:
            options = codesign.SigningOptions(
                identifier=identifier, identity=identity, adhoc=identity is None, version=version)
        signed, _ = codesign.sign_image(image.bytes(), options)
        self.entries[path] = signed
        binaries.append(SignedBinary(path=path, identifier=identifier, adhoc=identity is None,
                                     injected=injected, size_before=len(content), size_after=len(signed)))
        entitlements_by_path[path] = entitlements

    def _write_resource_seals(self) -> None:
        for directory, _ in self.app_containers():
            seal = self._resource_seal(directory)
            self.entries[f"{directory}/_CodeSignature/CodeResources"] = plistlib.dumps(seal)

    def _resource_seal(self, directory: str) -> dict:
        files: dict[str, dict] = {}
        files2: dict[str, dict] = {}
        executable = self.executable_path(directory)
        prefix = directory + "/"
        for path in sorted(self.entries):
            if not path.startswith(prefix) or path == executable:
                continue
            relative = path[len(prefix):]
            if relative.startswith("_CodeSignature/") or relative == "Info.plist":
                continue
            content = self.entries[path]
            files[relative] = {"hash": hashlib.sha1(content).digest()}
            files2[relative] = {"hash2": hashlib.sha256(content).digest()}
        return {"files": files, "files2": files2, "rules": {}, "rules2": {}}

    def bundle_identifier_of(self, directory: str) -> str:
        info_path = f"{directory}/Info.plist"
        if info_path not in self.entries:
            raise BundleError(f"{directory} has no Info.plist")
        identifier = plistlib.loads(self.entries[info_path]).get("CFBundleIdentifier")
        if not isinstance(identifier, str):
            raise BundleError(f"{directory} declares no identifier")
        return identifier

    def _verify_entry(self, path: str) -> codesign.VerificationReport:
        return codesign.verify_image(self.entries[path])


def sign_ipa(data: bytes, identity=None, profile_object=None, overrides=None,
             version: int = 0x20400) -> SigningOutcome:
    return IPABundle.from_bytes(data).sign(identity, profile_object, overrides, version)
