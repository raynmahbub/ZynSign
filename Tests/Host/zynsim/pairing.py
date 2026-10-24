"""Device identities and pairing records.

A pairing record is the credential that replaces a cable: the host's
certificate and private key, the device's certificate, the root both chain to,
and the host's identifier. Everything after ``Pair`` is carried over a TLS
connection whose two ends those certificates authenticate.

The keys here are the ones a real record uses. The parsing rules are the ones
that matter for safety: the record must name one device, its host identifier
must be the SHA-1 of the host certificate it carries, and none of its fields
may be empty.
"""

from __future__ import annotations

import base64
import hashlib
import plistlib
import subprocess
from dataclasses import dataclass
from pathlib import Path


class PairingError(ValueError):
    """The bytes are not a pairing record this engine will use."""


@dataclass
class DeviceIdentity:
    """The three certificates a simulated device needs, and their keys."""

    directory: Path
    root_certificate: bytes
    root_key: Path
    device_certificate: Path
    device_key: Path
    host_certificate: Path
    host_key: Path
    host_certificate_der: bytes
    udid: str = "0000803000000000000000000000000000000001"


def _openssl(*arguments: str) -> None:
    result = subprocess.run(["openssl", *arguments], capture_output=True, check=False)
    if result.returncode != 0:
        raise PairingError(f"openssl failed: {result.stderr.decode(errors='replace').strip()}")


def create_device_identity(directory: Path) -> DeviceIdentity:
    """A root, a device leaf, and a host leaf — the three a record names."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    root_key, root_cert = directory / "root.key", directory / "root.crt"
    if not root_cert.exists():
        _openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
                 "-keyout", str(root_key), "-out", str(root_cert),
                 "-subj", "/CN=ZynSim Device Root",
                 "-addext", "basicConstraints=critical,CA:TRUE",
                 "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    extensions = directory / "leaf.ext"
    extensions.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                          "extendedKeyUsage=serverAuth,clientAuth\n")

    def leaf(name: str) -> tuple[Path, Path]:
        key = directory / f"{name}.key"
        certificate = directory / f"{name}.crt"
        if not certificate.exists():
            csr = directory / f"{name}.csr"
            _openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key),
                     "-out", str(csr), "-subj", f"/CN=ZynSim {name}")
            _openssl("x509", "-req", "-in", str(csr), "-CA", str(root_cert), "-CAkey", str(root_key),
                     "-CAcreateserial", "-days", "30", "-extfile", str(extensions), "-out", str(certificate))
        return key, certificate

    device_key, device_cert = leaf("device")
    host_key, host_cert = leaf("host")
    host_der = subprocess.run(["openssl", "x509", "-in", str(host_cert), "-outform", "DER"],
                              capture_output=True, check=True).stdout
    return DeviceIdentity(
        directory=directory,
        root_certificate=root_cert.read_bytes(),
        root_key=root_key,
        device_certificate=device_cert,
        device_key=device_key,
        host_certificate=host_cert,
        host_key=host_key,
        host_certificate_der=host_der,
    )


def pem_to_der(pem: bytes | str) -> bytes:
    text = pem.decode() if isinstance(pem, bytes) else pem
    body = "".join(line for line in text.splitlines() if not line.startswith("-----"))
    return base64.b64decode(body)


def host_id(certificate_der: bytes) -> str:
    """The record's ``HostID``: uppercase hex SHA-1 of the host certificate."""
    return hashlib.sha1(certificate_der).hexdigest().upper()


@dataclass
class PairingRecord:
    device_certificate: bytes
    host_certificate: bytes
    host_private_key: bytes
    root_certificate: bytes
    host_id: str
    system_buid: str
    udid: str

    def to_plist(self) -> bytes:
        return plistlib.dumps({
            "DeviceCertificate": self.device_certificate,
            "HostCertificate": self.host_certificate,
            "HostPrivateKey": self.host_private_key,
            "RootCertificate": self.root_certificate,
            "HostID": self.host_id,
            "SystemBUID": self.system_buid,
            "UDID": self.udid,
            "Version": 1,
        }, fmt=plistlib.FMT_BINARY)

    @classmethod
    def parse(cls, data: bytes) -> "PairingRecord":
        try:
            root = plistlib.loads(data)
        except Exception as error:  # noqa: BLE001 - plistlib raises several types
            raise PairingError("the record is not a property list") from error
        if not isinstance(root, dict):
            raise PairingError("the record's root is not a dictionary")
        fields = {}
        for key in ("DeviceCertificate", "HostCertificate", "HostPrivateKey",
                    "RootCertificate", "HostID", "SystemBUID", "UDID"):
            value = root.get(key)
            if not isinstance(value, (bytes, str)) or not value:
                raise PairingError(f"the record has no {key}")
            fields[key] = value if isinstance(value, bytes) else value.encode()
        expected = host_id(fields["HostCertificate"])
        if fields["HostID"].decode(errors="replace").upper() != expected:
            raise PairingError("the record's HostID is not the digest of its host certificate")
        return cls(
            device_certificate=fields["DeviceCertificate"],
            host_certificate=fields["HostCertificate"],
            host_private_key=fields["HostPrivateKey"],
            root_certificate=fields["RootCertificate"],
            host_id=expected,
            system_buid=fields["SystemBUID"].decode(errors="replace"),
            udid=fields["UDID"].decode(errors="replace"),
        )


def create_pairing_record(identity: DeviceIdentity, system_buid: str = "ZYN-SIM-BUID-0001") -> PairingRecord:
    return PairingRecord(
        device_certificate=pem_to_der(identity.device_certificate.read_text()),
        host_certificate=identity.host_certificate_der,
        host_private_key=identity.host_key.read_bytes(),
        root_certificate=pem_to_der(identity.root_certificate),
        host_id=host_id(identity.host_certificate_der),
        system_buid=system_buid,
        udid=identity.udid,
    )
