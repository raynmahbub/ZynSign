"""A simulated iOS device: real framing, real TLS, and real verification.

This is not a mock. It terminates a mutual-TLS handshake that requires the
host certificate from the pairing record, answers ``lockdownd`` queries, hands
out service ports, stores what AFC uploads, and then verifies the signature of
the package it was given with the same code the host suite uses. What it does
not do is run on a phone: the framing is the published one, but the device is a
thread in this process.

The policy knob matters for the report. A stock device refuses an ad-hoc
signature at ``VerifyingApplication``; a development device that has been told
to accept one installs it. Both behaviours are exercised by the suite, so the
refusal path is evidence too.
"""

from __future__ import annotations

import hashlib
import io
import plistlib
import socket
import ssl
import threading
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

from . import codesign, macho, protocol

STAGING = "/PublicStaging"


@dataclass
class InstalledApp:
    bundle_id: str
    version: str
    path: str
    adhoc: bool
    signature: codesign.VerificationReport
    entitlements: dict


@dataclass
class SimulatedDevice:
    """One device, listening on loopback ports, with a small virtual file system."""

    device_certificate: Path
    device_key: Path
    root_certificate: bytes
    host_certificate: bytes
    udid: str
    product_version: str = "17.4"
    build_version: str = "21E219"
    product_type: str = "iPhone15,3"
    accept_adhoc: bool = False
    files: dict[str, bytes] = field(default_factory=dict)
    installed: dict[str, InstalledApp] = field(default_factory=dict)
    port: int = 0
    afc_port: int = 0
    installation_port: int = 0
    _sockets: list[socket.socket] = field(default_factory=list)
    _threads: list[threading.Thread] = field(default_factory=list)
    _stop: threading.Event = field(default_factory=threading.Event)
    _lock: threading.Lock = field(default_factory=threading.Lock)
    _transactions: int = 0
    _clients: list = field(default_factory=list)
    last_error: str = ""

    def __post_init__(self) -> None:
        # Both certificates may arrive as PEM or DER; TLS wants one shape.
        self.root_certificate = _der(self.root_certificate)
        self.host_certificate = _der(self.host_certificate)
        self.files.setdefault(STAGING, b"")

    # MARK: - Lifecycle

    def start(self) -> "SimulatedDevice":
        self.port = self._listen(self._serve_lockdown)
        self.afc_port = self._listen(self._serve_afc)
        self.installation_port = self._listen(self._serve_installation)
        return self

    def stop(self) -> None:
        self._stop.set()
        for listener in self._sockets:
            try:
                listener.close()
            except OSError:
                pass
        with self._lock:
            clients = list(self._clients)
            self._clients.clear()
        for client in clients:
            try:
                client.close()
            except OSError:
                pass
        for thread in self._threads:
            thread.join(timeout=2)

    def _listen(self, handler) -> int:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(8)
        # A blocking accept() is not woken by closing the socket from another
        # thread, so the loop polls; stop() then finishes in a quarter second
        # instead of waiting out a join timeout.
        listener.settimeout(0.25)
        self._sockets.append(listener)
        port = listener.getsockname()[1]

        def accept_loop() -> None:
            while not self._stop.is_set():
                try:
                    connection, _ = listener.accept()
                except TimeoutError:
                    continue
                except OSError:
                    return
                threading.Thread(target=self._guard, args=(handler, connection), daemon=True).start()

        thread = threading.Thread(target=accept_loop, daemon=True)
        thread.start()
        self._threads.append(thread)
        return port

    def _guard(self, handler, connection) -> None:
        try:
            handler(connection)
        except Exception as error:  # noqa: BLE001 - a simulator must not die on a bad client
            self.last_error = f"{type(error).__name__}: {error}"
        finally:
            try:
                connection.close()
            except OSError:
                pass

    # MARK: - TLS

    def _server_context(self) -> ssl.SSLContext:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(self.device_certificate), str(self.device_key))
        context.verify_mode = ssl.CERT_REQUIRED
        context.load_verify_locations(cadata=_pem(self.root_certificate).decode())
        return context

    def _upgrade(self, connection: socket.socket) -> ssl.SSLSocket:
        secure = self._server_context().wrap_socket(connection, server_side=True)
        with self._lock:
            self._clients.append(secure)
        # The record names one host; a different certificate is a different host
        # even if it chains to the same root.
        if secure.getpeercert(binary_form=True) != self.host_certificate:
            secure.close()
            raise ssl.SSLError("the host certificate is not the paired one")
        return secure

    def _open_tunnel(self, connection: socket.socket) -> ssl.SSLSocket:
        """Accept the usbmux ``Connect`` a host sends before any service."""
        message, _tag, payload = protocol.receive_usbmux(connection)
        request = plistlib.loads(payload) if payload else {}
        if message != protocol.USBMUX_CONNECT or request.get("MessageType") != "Connect":
            protocol.send_usbmux(connection, protocol.USBMUX_RESULT, 0,
                                 plistlib.dumps({"MessageType": "Result", "Number": 1}))
            raise protocol.ProtocolError("the host did not send a Connect request")
        protocol.send_usbmux(connection, protocol.USBMUX_RESULT, 0,
                             plistlib.dumps({"MessageType": "Result", "Number": 0}))
        return self._upgrade(connection)

    # MARK: - lockdownd

    def _serve_lockdown(self, connection: socket.socket) -> None:
        secure = self._open_tunnel(connection)
        try:
            self._lockdown_loop(secure)
        finally:
            secure.close()

    def _lockdown_loop(self, connection: ssl.SSLSocket) -> None:
        paired = False
        session = False
        while not self._stop.is_set():
            try:
                message = protocol.receive_plist(connection)
            except (protocol.ProtocolError, OSError, ssl.SSLError):
                return
            request = message.get("Request")
            if request == "QueryType":
                protocol.send_plist(connection, {"Type": "com.apple.mobile.lockdown"})
            elif request == "GetValue":
                key = message.get("Key")
                values = {
                    "UniqueDeviceID": self.udid,
                    "ProductVersion": self.product_version,
                    "BuildVersion": self.build_version,
                    "ProductType": self.product_type,
                    "DeviceName": "Simulated iPhone",
                    "HardwareModel": "D63AP",
                    "CPUArchitecture": "arm64e",
                }
                if key is None:
                    protocol.send_plist(connection, {"Value": values})
                elif key in values:
                    protocol.send_plist(connection, {"Key": key, "Value": values[key]})
                else:
                    protocol.send_plist(connection, {"Error": "MissingValue",
                                                     "ErrorDescription": f"no value for {key}"})
            elif request == "Pair":
                # The host certificate must be the one in the record this
                # device was given; anything else is a different host.
                if str(message.get("PairRecordData", b"")).find(b"HostCertificate") >= 0:
                    paired = True
                    protocol.send_plist(connection, {"EscrowBag": b"\x00" * 16})
                else:
                    protocol.send_plist(connection, {"Error": "PairingFailed",
                                                     "ErrorDescription": "no pairing record"})
            elif request == "StartSession":
                expected = hashlib.sha1(self.host_certificate).hexdigest().upper()
                requested = str(message.get("HostID", "")).upper()
                if requested and requested == expected:
                    paired = True
                if not paired:
                    protocol.send_plist(connection, {"Error": "SessionInProgress",
                                                     "ErrorDescription": "pair before starting a session"})
                    continue
                session = True
                protocol.send_plist(connection, {"EnableSessionID": True, "SessionID": "zysim-1"})
            elif request == "StopSession":
                session = False
                protocol.send_plist(connection, {"Result": "Success"})
            elif request == "StartService":
                if not session:
                    protocol.send_plist(connection, {"Error": "InvalidHostID",
                                                     "ErrorDescription": "no session"})
                    continue
                service = message.get("Service")
                ports = {
                    "com.apple.afc": self.afc_port,
                    "com.apple.mobile.installation_proxy": self.installation_port,
                }
                if service not in ports:
                    protocol.send_plist(connection, {"Error": "InvalidService",
                                                     "ErrorDescription": f"unknown service {service}"})
                    continue
                protocol.send_plist(connection, {"Service": service, "Port": ports[service],
                                                 "EnableServiceSSL": True})
            else:
                protocol.send_plist(connection, {"Error": "UnknownRequest",
                                                 "ErrorDescription": f"{request} is not implemented"})

    # MARK: - AFC

    def _serve_afc(self, connection: socket.socket) -> None:
        secure = self._open_tunnel(connection)
        try:
            self._afc_loop(secure)
        finally:
            secure.close()

    def _afc_loop(self, secure: ssl.SSLSocket) -> None:
        while not self._stop.is_set():
            try:
                operation, payload, transaction = protocol.receive_afc(secure)
            except (protocol.ProtocolError, OSError, ssl.SSLError):
                return
            response = self._afc_operation(operation, payload, transaction)
            secure.sendall(response)

    def _afc_operation(self, operation: int, payload: bytes, transaction: int) -> bytes:
        if operation == protocol.AFC_WRITE_FILE:
            path, data = _split_path(payload)
            path = self._normalize(path)
            with self._lock:
                self.files[path] = data
            return protocol.afc_packet(protocol.AFC_STATUS, protocol.afc_status(protocol.AFC_SUCCESS),
                                       transaction)
        if operation == protocol.AFC_MAKE_DIR:
            path = self._normalize(payload.split(b"\x00", 1)[0].decode())
            with self._lock:
                self.files.setdefault(path, b"")
            return protocol.afc_packet(protocol.AFC_STATUS, protocol.afc_status(protocol.AFC_SUCCESS),
                                       transaction)
        if operation == protocol.AFC_GET_FILE_INFO:
            path = self._normalize(payload.split(b"\x00", 1)[0].decode())
            with self._lock:
                exists = path in self.files or any(key.startswith(path + "/") for key in self.files)
                size = len(self.files.get(path, b""))
            if not exists:
                return protocol.afc_packet(
                    protocol.AFC_STATUS,
                    protocol.afc_status(protocol.AFC_OBJECT_NOT_FOUND, f"{path} not found"),
                    transaction)
            values = {"st_size": size, "st_ifmt": "S_IFREG" if size else "S_IFDIR"}
            return protocol.afc_packet(protocol.AFC_STATUS,
                                       protocol.afc_status(protocol.AFC_SUCCESS)
                                       + protocol.afc_file_info(values), transaction)
        if operation == protocol.AFC_REMOVE_PATH:
            path = self._normalize(payload.split(b"\x00", 1)[0].decode())
            with self._lock:
                self.files.pop(path, None)
            return protocol.afc_packet(protocol.AFC_STATUS, protocol.afc_status(protocol.AFC_SUCCESS),
                                       transaction)
        if operation == protocol.AFC_GET_DEVINFO:
            return protocol.afc_packet(
                protocol.AFC_STATUS,
                protocol.afc_status(protocol.AFC_SUCCESS)
                + protocol.afc_file_info({"ModelNumber": "ZYN1", "FSTotalBytes": 64 * 1024 * 1024}),
                transaction)
        return protocol.afc_packet(protocol.AFC_STATUS,
                                   protocol.afc_status(protocol.AFC_HEADER_INVALID,
                                                       f"operation 0x{operation:x} is not implemented"),
                                   transaction)

    def _normalize(self, path: str) -> str:
        path = path.strip()
        if not path.startswith("/"):
            path = "/" + path
        while "//" in path:
            path = path.replace("//", "/")
        return path.rstrip("/") or "/"

    # MARK: - installation_proxy

    def _serve_installation(self, connection: socket.socket) -> None:
        secure = self._open_tunnel(connection)
        try:
            self._installation_loop(secure)
        finally:
            secure.close()

    def _installation_loop(self, secure: ssl.SSLSocket) -> None:
        while not self._stop.is_set():
            try:
                command = protocol.receive_plist(secure)
            except (protocol.ProtocolError, OSError, ssl.SSLError):
                return
            name = command.get("Command")
            if name in ("Install", "Upgrade"):
                self._install(secure, command)
            elif name == "ListApps":
                apps = {}
                for installed in self.installed.values():
                    apps[installed.bundle_id] = {
                        "CFBundleIdentifier": installed.bundle_id,
                        "CFBundleShortVersionString": installed.version,
                        "ApplicationType": "User",
                        "Path": installed.path,
                        "SignerIdentity": "Ad Hoc" if installed.adhoc else "ZynSign",
                    }
                protocol.send_plist(secure, {"Status": "Complete", "Apps": apps})
            elif name == "Uninstall":
                bundle_id = command.get("ApplicationIdentifier")
                with self._lock:
                    self.installed.pop(str(bundle_id), None)
                protocol.send_plist(secure, {"Status": "Complete"})
            else:
                protocol.send_plist(secure, {"Status": "Complete", "Error": "UnknownCommand",
                                             "ErrorDescription": f"{name} is not implemented"})

    def _install(self, connection: ssl.SSLSocket, command: dict) -> None:
        path = self._normalize(str(command.get("PackagePath", "")))
        with self._lock:
            payload = self.files.get(path)
        staged = ["CreatingStagingDirectory", "ExtractingPackage", "InspectingPackage"]
        for index, status in enumerate(staged):
            protocol.send_plist(connection, {"Status": status,
                                             "PercentComplete": int(100 * index / 6)})
        if payload is None:
            protocol.send_plist(connection, {"Status": "Complete", "Error": "APIInternalError",
                                             "ErrorDescription": f"{path} is not on the device"})
            return
        try:
            bundle_id, version, report, entitlements = self._inspect(payload)
        except Exception as error:  # noqa: BLE001 - report the refusal, do not raise
            protocol.send_plist(connection, {"Status": "VerifyingApplication", "PercentComplete": 60})
            protocol.send_plist(connection, {"Status": "Complete", "Error": "ApplicationVerificationFailed",
                                             "ErrorDescription": str(error)})
            return
        protocol.send_plist(connection, {"Status": "VerifyingApplication", "PercentComplete": 60})
        if report.adhoc and not self.accept_adhoc:
            protocol.send_plist(connection, {
                "Status": "Complete", "Error": "ApplicationVerificationFailed",
                "ErrorDescription": "this device does not trust an ad-hoc signature"})
            return
        protocol.send_plist(connection, {"Status": "InstallingApplication", "PercentComplete": 80})
        with self._lock:
            self.installed[bundle_id] = InstalledApp(bundle_id, version, "/private/var/containers/Bundle/Application/"
                                                     + bundle_id + "/Demo.app", report.adhoc, report, entitlements)
        protocol.send_plist(connection, {"Status": "Complete", "PercentComplete": 100})

    def _inspect(self, payload: bytes):
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            entries = {info.filename: archive.read(info)
                       for info in archive.infolist() if not info.is_dir()}
        app = next((path.split("/")[1] for path in entries if path.startswith("Payload/")), None)
        if app is None:
            raise ValueError("the package contains no app bundle")
        info = plistlib.loads(entries[f"Payload/{app}/Info.plist"])
        executable = info.get("CFBundleExecutable")
        bundle_id = info.get("CFBundleIdentifier")
        if not executable or not bundle_id:
            raise ValueError("the bundle declares no identifier or executable")
        report = codesign.verify_image(entries[f"Payload/{app}/{executable}"])
        if not report.valid:
            raise ValueError("the executable's signature does not verify: " + "; ".join(report.problems))
        if report.identifier != bundle_id and not report.identifier.startswith(bundle_id):
            raise ValueError(
                f"the signature is for {report.identifier}, the bundle is {bundle_id}")
        entitlements = {}
        stamp = entries.get(f"Payload/{app}/embedded.mobileprovision")
        if stamp:
            from . import profile as profile_module
            entitlements = profile_module.parse_profile(stamp).entitlements
        return bundle_id, str(info.get("CFBundleShortVersionString", "")), report, entitlements


def _split_path(payload: bytes) -> tuple[str, bytes]:
    index = payload.find(b"\x00")
    if index < 0:
        raise protocol.ProtocolError("an AFC write carries no path")
    return payload[:index].decode(), payload[index + 1:]


def _der(certificate: bytes) -> bytes:
    if certificate.lstrip().startswith(b"-----BEGIN"):
        import base64
        body = b"".join(line for line in certificate.splitlines() if not line.startswith(b"-----"))
        return base64.b64decode(body)
    return certificate


def _pem(der_bytes: bytes) -> bytes:
    import base64
    body = base64.encodebytes(der_bytes).replace(b"\n", b"")
    lines = [body[index:index + 64] for index in range(0, len(body), 64)]
    return b"-----BEGIN CERTIFICATE-----\n" + b"\n".join(lines) + b"\n-----END CERTIFICATE-----\n"
