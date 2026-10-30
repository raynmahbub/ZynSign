"""The host side of the device bridge: pair, start a session, install a package.

The layering is deliberate. This module owns the conversation, not the socket:
it opens a connection to a device port, sends the usbmux ``Connect`` the daemon
expects, upgrades to TLS with the certificate the pairing record holds, and from
then on speaks property lists or AFC packets. What it never does is claim more
than the device said: an installation is complete when the device's last message
is ``Complete``, and not before.
"""

from __future__ import annotations

import base64
import plistlib
import socket
import ssl
import struct
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from . import protocol


class DeviceError(Exception):
    """The device refused, or the conversation broke."""

    def __init__(self, description: str, code: str = "ZynSignDeviceError"):
        super().__init__(description)
        self.description = description
        self.code = code


@dataclass
class DeviceInfo:
    udid: str
    product_type: str
    product_version: str
    build_version: str
    device_name: str


@dataclass
class InstallOutcome:
    bundle_id: str
    progress: list[dict] = field(default_factory=list)
    uploaded_bytes: int = 0

    @property
    def installed(self) -> bool:
        return bool(self.progress) and self.progress[-1].get("Status") == "Complete" \
            and "Error" not in self.progress[-1]


def _pem(der_bytes: bytes) -> bytes:
    body = base64.encodebytes(der_bytes).replace(b"\n", b"")
    lines = [body[index:index + 64] for index in range(0, len(body), 64)]
    return b"-----BEGIN CERTIFICATE-----\n" + b"\n".join(lines) + b"\n-----END CERTIFICATE-----\n"


class DeviceBridge:
    """One host, one device, one session at a time."""

    def __init__(self, port: int, host: str = "127.0.0.1", timeout: float = 20.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.record = None
        self._lockdown: ssl.SSLSocket | None = None
        self._info: DeviceInfo | None = None
        self._service_ports: dict[str, int] = {}

    # MARK: - Connections

    def _open(self, port: int) -> ssl.SSLSocket:
        raw = socket.create_connection((self.host, port), timeout=self.timeout)
        try:
            raw.settimeout(self.timeout)
            protocol.send_usbmux(raw, protocol.USBMUX_CONNECT, 1,
                                 protocol.connect_message(protocol.LOCKDOWN_PORT))
            message, _tag, payload = protocol.receive_usbmux(raw)
            if message != protocol.USBMUX_RESULT:
                raise DeviceError("the multiplexer did not answer the connect request", "MuxConnectFailed")
            result = plistlib.loads(payload) if payload else {}
            if int(result.get("Number", 1)) != 0:
                raise DeviceError("the multiplexer refused to open the device port", "MuxConnectRefused")
            context = self._client_context()
            return context.wrap_socket(raw, server_hostname="zynsim.device")
        except ssl.SSLError as error:
            raw.close()
            raise DeviceError(f"the TLS handshake with the device failed: {error}", "TLSHandshakeFailed") from error
        except BaseException:
            raw.close()
            raise

    def _client_context(self) -> ssl.SSLContext:
        if self.record is None:
            raise DeviceError("no pairing record is loaded", "NoPairingRecord")
        # SSLContext loads the identity before this private temporary directory
        # is removed; no pairing key is left on disk for the session's lifetime.
        with tempfile.TemporaryDirectory(prefix="zynsign-pairing-") as name:
            directory = Path(name)
            certificate = directory / "host.crt"
            key = directory / "host.key"
            certificate.write_bytes(_pem(self.record.host_certificate))
            key.write_bytes(self.record.host_private_key)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_REQUIRED
            context.load_verify_locations(cadata=_pem(self.record.root_certificate).decode())
            context.load_cert_chain(str(certificate), str(key))
            return context

    # MARK: - Session

    def connect(self, record) -> DeviceInfo:
        self.record = record
        self._lockdown = self._open(self.port)
        try:
            reply = self._request("QueryType")
            if reply.get("Type") != "com.apple.mobile.lockdown":
                raise DeviceError("the service is not lockdownd", "WrongService")
            values = self._request("GetValue")
            value = values.get("Value", {})
            self._info = DeviceInfo(
                udid=str(value.get("UniqueDeviceID", record.udid)),
                product_type=str(value.get("ProductType", "")),
                product_version=str(value.get("ProductVersion", "")),
                build_version=str(value.get("BuildVersion", "")),
                device_name=str(value.get("DeviceName", "")),
            )
            return self._info
        except BaseException:
            self.close()
            raise

    def pair(self) -> bool:
        """Offer the record's own data. A device that is already paired ignores it."""
        reply = self._request("Pair", PairRecordData=self.record.to_plist(),
                              PairingOptions={"ExtendedSequence": False})
        return "Error" not in reply

    def start_session(self) -> str:
        reply = self._request("StartSession", HostID=self.record.host_id,
                              SystemBUID=self.record.system_buid)
        if "Error" in reply:
            raise DeviceError(reply.get("ErrorDescription", "the session was refused"),
                              reply.get("Error", "StartSessionFailed"))
        return "zysim-1" if reply.get("EnableSessionID") else ""

    def _request(self, name: str, **fields) -> dict:
        if self._lockdown is None:
            raise DeviceError("no device session is open", "NoSession")
        message = {"Label": "ZynSign", "Request": name, "ClientVersionString": "zynsign-1",
                   "ProgName": "ZynSign", "kLibUSBMuxVersion": 3}
        message.update(fields)
        protocol.send_plist(self._lockdown, message)
        reply = protocol.receive_plist(self._lockdown)
        if "Error" in reply and name != "StartSession":
            raise DeviceError(reply.get("ErrorDescription", reply["Error"]), str(reply["Error"]))
        return reply

    def service(self, name: str) -> ssl.SSLSocket:
        if name in self._service_ports:
            port = self._service_ports[name]
            reply = {"Port": port}
        else:
            reply = self._request("StartService", Service=name)
            port = int(reply["Port"])
            self._service_ports[name] = port
        return self._open(port)

    def close(self) -> None:
        for connection in (self._lockdown,):
            if connection is not None:
                try:
                    connection.close()
                except OSError:
                    pass
        self._lockdown = None

    # MARK: - AFC

    def upload(self, data: bytes, remote_path: str) -> int:
        connection = self.service("com.apple.afc")
        transaction = 1
        try:
            directory = remote_path.rsplit("/", 1)[0] or "/"
            connection.sendall(protocol.afc_packet(
                protocol.AFC_MAKE_DIR, directory.encode() + b"\x00", transaction))
            operation, payload, _ = protocol.receive_afc(connection)
            status, text = protocol.parse_afc_status(payload)
            if status not in (protocol.AFC_SUCCESS, protocol.AFC_OBJECT_EXISTS):
                raise DeviceError(f"AFC could not create {directory}: {text}", "AFCError")

            transaction += 1
            connection.sendall(protocol.afc_packet(
                protocol.AFC_WRITE_FILE, remote_path.encode() + b"\x00" + data, transaction))
            operation, payload, _ = protocol.receive_afc(connection)
            if operation != protocol.AFC_STATUS:
                raise DeviceError("AFC answered a write with a non-status packet", "AFCError")
            status, text = protocol.parse_afc_status(payload)
            if status != protocol.AFC_SUCCESS:
                raise DeviceError(f"AFC refused the upload: {text}", "AFCError")
        finally:
            connection.close()
        return len(data)

    # MARK: - installation_proxy

    def install_package(self, package: bytes, bundle_id: str, filename: str = "package.ipa") -> InstallOutcome:
        remote = f"/PublicStaging/{filename}"
        uploaded = self.upload(package, remote)
        connection = self.service("com.apple.mobile.installation_proxy")
        outcome = InstallOutcome(bundle_id=bundle_id, uploaded_bytes=uploaded)
        try:
            protocol.send_plist(connection, {
                "Command": "Install",
                "PackagePath": remote,
                "ClientOptions": {"PackageType": "Developer", "CFBundleIdentifier": bundle_id},
            })
            while True:
                message = protocol.receive_plist(connection)
                outcome.progress.append(message)
                if message.get("Status") == "Complete":
                    if "Error" in message:
                        raise DeviceError(str(message.get("ErrorDescription", message["Error"])),
                                          str(message["Error"]))
                    break
        finally:
            connection.close()
        return outcome

    def list_apps(self) -> dict:
        connection = self.service("com.apple.mobile.installation_proxy")
        try:
            protocol.send_plist(connection, {"Command": "ListApps"})
            message = protocol.receive_plist(connection)
            return message.get("Apps", {})
        finally:
            connection.close()
