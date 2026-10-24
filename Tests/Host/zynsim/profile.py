"""Provisioning profiles: parse, match, and turn into signing entitlements.

A ``.mobileprovision`` is a CMS message whose payload is an XML property list.
The interesting keys are the team, the application identifier (with its team
prefix and optional wildcard), the entitlement dictionary, the expiry date and
the provisioned device list.

Nothing here validates Apple's signature over the profile. A profile is a
statement by Apple, but this engine can only read it; the suite says so rather
than implying a trust decision it cannot make.
"""

from __future__ import annotations

import plistlib
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone

from . import der

MAXIMUM_PROFILE_BYTES = 4 * 1024 * 1024


class ProfileError(ValueError):
    """The bytes are not a provisioning profile this engine can read."""


@dataclass
class ProvisioningProfile:
    name: str
    app_id: str                  # e.g. "ABCDE12345.com.example.app" or "ABCDE12345.*"
    team_id: str
    entitlements: dict
    expiration: datetime | None
    provisioned_devices: list[str]
    platforms: list[str]
    uuid: str
    is_wildcard: bool
    raw_entitlements: dict = field(default_factory=dict)

    @property
    def team_prefix(self) -> str:
        return self.app_id.split(".", 1)[0]

    @property
    def application_identifier_pattern(self) -> str:
        return self.app_id

    @property
    def is_expired(self) -> bool:
        return self.expiration is not None and self.expiration < datetime.now(timezone.utc)

    def matches(self, bundle_id: str) -> bool:
        """Whether the profile's application identifier covers ``bundle_id``."""
        pattern = self.app_id
        team = self.team_prefix
        if not pattern.startswith(team + "."):
            return False
        suffix = pattern[len(team) + 1:]
        if suffix == "*":
            return True
        if suffix.endswith(".*"):
            return bundle_id == suffix[:-2] or bundle_id.startswith(suffix[:-2] + ".")
        return suffix == bundle_id

    def entitlements_for(self, bundle_id: str, *, nested: bool = False) -> dict:
        """The profile's entitlements, re-pointed at ``bundle_id``.

        A wildcard profile carries placeholders. Apple's own signer rewrites
        ``application-identifier`` and ``keychain-access-groups`` to the real
        identifier, and app extensions get their own suffix; that is what this
        does. Entitlements whose value cannot be re-pointed are left alone.
        """
        team = self.team_id or self.team_prefix
        result = dict(self.entitlements)
        identifier = f"{team}.{bundle_id}"
        if "application-identifier" in result:
            result["application-identifier"] = identifier
        if "com.apple.developer.team-identifier" in result:
            result["com.apple.developer.team-identifier"] = team
        groups = result.get("keychain-access-groups")
        if isinstance(groups, list):
            result["keychain-access-groups"] = [
                group if group.endswith(bundle_id) else f"{team}.{bundle_id}" for group in groups
            ] or [identifier]
        if nested:
            # An extension shares the app's team but not its push environment.
            result.pop("aps-environment", None)
        return result


def extract_plist(profile: bytes) -> bytes:
    """Find the property list inside the CMS wrapper.

    The profile is signed, so the list is not at a fixed offset: scan for a
    plist prologue and parse the longest candidate. A binary plist is accepted
    too, because some tooling re-encodes the payload.
    """
    if len(profile) > MAXIMUM_PROFILE_BYTES:
        raise ProfileError("the profile is larger than this engine will read")
    starts = [index for index in (profile.find(b"<?xml"), profile.find(b"<plist"), profile.find(b"bplist00"))
              if index >= 0]
    if not starts:
        raise ProfileError("no property list found inside the profile")
    start = min(starts)
    payload = profile[start:]
    if payload.startswith(b"bplist00"):
        return payload
    end = payload.find(b"</plist>")
    if end < 0:
        raise ProfileError("the profile's property list is not closed")
    return payload[:end + len(b"</plist>")]


def parse_profile(profile: bytes) -> ProvisioningProfile:
    payload = extract_plist(profile)
    try:
        root = plistlib.loads(payload)
    except Exception as error:  # noqa: BLE001 - plistlib raises several types
        raise ProfileError(f"the profile's property list does not parse: {error}") from error
    if not isinstance(root, dict):
        raise ProfileError("the profile's root is not a dictionary")
    for key in ("Name", "Entitlements", "TeamIdentifier"):
        if key not in root:
            raise ProfileError(f"the profile has no {key}")
    teams = root["TeamIdentifier"]
    if not isinstance(teams, list) or not teams:
        raise ProfileError("the profile declares no team identifier")
    entitlements = root["Entitlements"]
    if not isinstance(entitlements, dict):
        raise ProfileError("the profile's Entitlements is not a dictionary")
    app_id = entitlements.get("application-identifier")
    if not isinstance(app_id, str) or "." not in app_id:
        raise ProfileError("the profile has no application-identifier")
    expiration = root.get("ExpirationDate")
    if isinstance(expiration, str):
        try:
            expiration = datetime.fromisoformat(expiration.replace("Z", "+00:00"))
        except ValueError:
            expiration = None
    return ProvisioningProfile(
        name=str(root["Name"]),
        app_id=app_id,
        team_id=str(teams[0]),
        entitlements=entitlements,
        expiration=expiration,
        provisioned_devices=[str(device) for device in root.get("ProvisionedDevices", [])],
        platforms=[str(platform) for platform in root.get("Platform", [])],
        uuid=str(root.get("UUID", "")),
        is_wildcard=app_id.endswith("*"),
        raw_entitlements=root,
    )


def entitlements_xml(entitlements: dict) -> bytes:
    return plistlib.dumps(entitlements, fmt=plistlib.FMT_XML, sort_keys=True)


# MARK: - DER entitlements (slot 7)


def _der_value(value):
    if isinstance(value, bool):
        return der.boolean(value)
    if isinstance(value, int):
        return der.integer(value)
    if isinstance(value, str):
        return der.utf8_string(value)
    if isinstance(value, bytes):
        return der.octet_string(value)
    if isinstance(value, list):
        return der.sequence(*[_der_value(item) for item in value])
    if isinstance(value, dict):
        return der.set_of(*[
            der.sequence(der.utf8_string(key), _der_value(value[key]))
            for key in sorted(value, key=lambda item: item.encode("utf-8"))
        ])
    raise ProfileError(f"entitlement values of type {type(value).__name__} have no DER form")


def der_entitlements(entitlements: dict) -> bytes:
    """The slot-7 payload: a canonical SET of key/value SEQUENCEs.

    This mirrors the in-app serializer: UTF-8 ascending at every level, values
    typed (bool, integer, UTF-8 string, octet string, sequence for an array,
    set for a dictionary).
    """
    return der.set_of(*[
        der.sequence(der.utf8_string(key), _der_value(entitlements[key]))
        for key in sorted(entitlements, key=lambda item: item.encode("utf-8"))
    ])


# MARK: - PKCS#12


@dataclass
class ImportedIdentity:
    certificate_der: bytes
    key_path: object
    passphrase: str = ""


def identity_from_p12(path, passphrase: str = "") -> ImportedIdentity:
    """Split a ``.p12`` into its certificate and its key, with the host OpenSSL.

    The app has its own PKCS#12 importer; this is the host equivalent, used so
    the suite can start from the same kind of file a user imports.
    """
    import subprocess
    import tempfile
    from pathlib import Path

    path = Path(path)
    directory = Path(tempfile.mkdtemp(prefix="zynsign-p12-"))
    key_path = directory / "key.pem"
    cert_path = directory / "cert.pem"
    result = subprocess.run(
        ["openssl", "pkcs12", "-in", str(path), "-nodes", "-passin", f"pass:{passphrase}",
         "-out", str(directory / "bundle.pem")],
        capture_output=True, check=False)
    if result.returncode != 0:
        raise ProfileError("the PKCS#12 archive could not be opened with that passphrase")
    pem = (directory / "bundle.pem").read_text()
    key_blocks = re.findall(r"-----BEGIN (?:ENCRYPTED )?PRIVATE KEY-----.*?-----END (?:ENCRYPTED )?PRIVATE KEY-----",
                            pem, re.S)
    cert_blocks = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S)
    if not key_blocks or not cert_blocks:
        raise ProfileError("the PKCS#12 archive does not contain both a key and a certificate")
    key_path.write_text(key_blocks[0] + "\n")
    cert_path.write_text(cert_blocks[0] + "\n")
    certificate_der = subprocess.run(
        ["openssl", "x509", "-in", str(cert_path), "-outform", "DER"],
        capture_output=True, check=True).stdout
    return ImportedIdentity(certificate_der, key_path, passphrase)
