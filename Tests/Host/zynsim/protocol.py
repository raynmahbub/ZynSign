"""Wire formats for the four layers between a host and a device's installer.

None of these are Apple frameworks: they are the published framing, written
out so the app can speak them over whatever transport it has.

============  ===================================================================
usbmux        16-byte little-endian header (``length``, ``version``, ``message``,
              ``tag``) followed by an XML property list. ``Connect`` asks the
              daemon to open a tunnel to a device port.
lockdownd     4-byte **big-endian** length followed by an XML property list, on
              port 62078, after a TLS handshake that both sides pin to the
              pairing record.
AFC           40-byte little-endian header: ``CFA6LPAA``, total length, this
              packet's length, packet number, operation — then the payload.
installation  lockdownd's framing again, on the port ``StartService`` returns,
proxy         carrying a command and a stream of progress dictionaries.
============  ===================================================================
"""

from __future__ import annotations

import plistlib
import socket
import struct

USBMUX_HEADER = struct.Struct("<IIII")
USBMUX_RESULT = 1
USBMUX_CONNECT = 2
USBMUX_PLIST = 8

LOCKDOWN_PORT = 62078
AFC_HEADER = struct.Struct("<8sQQQQ")
AFC_MAGIC = b"CFA6LPAA"

# AFC operations, in the order libimobiledevice's `afc.h` numbers them.
AFC_STATUS = 0x01
AFC_DATA = 0x02
AFC_READ_DIR = 0x03
AFC_GET_FILE_INFO = 0x04
AFC_GET_DEVINFO = 0x05
AFC_WRITE_FILE = 0x06
AFC_READ_FILE = 0x07
AFC_REMOVE_PATH = 0x08
AFC_MAKE_DIR = 0x09
AFC_GET_FILE_HASH = 0x0A
AFC_SET_FILE_HASH = 0x0B
AFC_MAKE_LINK = 0x0C
AFC_SET_FILE_TIME = 0x0D
AFC_RENAME_PATH = 0x0E
AFC_TRUNCATE = 0x0F
AFC_ADD_HASH = 0x10
AFC_GET_BLOCK_SIZE = 0x11
AFC_SET_BLOCK_SIZE = 0x12

AFC_SUCCESS = 0
AFC_HEADER_INVALID = 3
AFC_OBJECT_NOT_FOUND = 8
AFC_OBJECT_IS_DIR = 9
AFC_PERM_DENIED = 10
AFC_OBJECT_EXISTS = 16

MAXIMUM_FRAME = 16 * 1024 * 1024


class ProtocolError(Exception):
    """A frame did not arrive, or did not parse."""


def _read_exactly(sock, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        chunk = sock.recv(count - len(chunks))
        if not chunk:
            raise ProtocolError(f"the peer closed with {count - len(chunks)} bytes outstanding")
        chunks.extend(chunk)
    return bytes(chunks)


def send_usbmux(sock, message: int, tag: int, payload: bytes) -> None:
    total = USBMUX_HEADER.size + len(payload)
    if total > MAXIMUM_FRAME:
        raise ProtocolError("the usbmux frame is larger than the protocol allows")
    sock.sendall(USBMUX_HEADER.pack(total, 1, message, tag) + payload)


def receive_usbmux(sock) -> tuple[int, int, bytes]:
    header = _read_exactly(sock, USBMUX_HEADER.size)
    length, version, message, tag = USBMUX_HEADER.unpack(header)
    if length < USBMUX_HEADER.size or length > MAXIMUM_FRAME:
        raise ProtocolError(f"usbmux frame length {length} is out of range")
    if version not in (0, 1, 2):
        raise ProtocolError(f"usbmux version {version} is not one this client speaks")
    return message, tag, _read_exactly(sock, length - USBMUX_HEADER.size)


def connect_message(port: int, device_id: int = 0, label: str = "ZynSign") -> bytes:
    return plistlib.dumps({
        "MessageType": "Connect",
        "ClientVersionString": "zynsign-1",
        "ProgName": label,
        "DeviceID": device_id,
        # usbmuxd expects the port in network byte order inside the plist.
        "PortNumber": struct.unpack(">H", struct.pack("<H", port))[0],
    })


def send_plist(sock, payload: dict) -> None:
    data = plistlib.dumps(payload)
    if len(data) > MAXIMUM_FRAME:
        raise ProtocolError("the property list is larger than a lockdownd frame")
    sock.sendall(struct.pack(">I", len(data)) + data)


def receive_plist(sock) -> dict:
    length = struct.unpack(">I", _read_exactly(sock, 4))[0]
    if length > MAXIMUM_FRAME:
        raise ProtocolError(f"lockdownd frame length {length} is out of range")
    payload = _read_exactly(sock, length)
    try:
        message = plistlib.loads(payload)
    except Exception as error:  # noqa: BLE001 - plistlib raises several types
        raise ProtocolError(f"the lockdownd payload is not a property list: {error}") from error
    if not isinstance(message, dict):
        raise ProtocolError("the lockdownd payload is not a dictionary")
    return message


def afc_packet(operation: int, payload: bytes, transaction: int = 1) -> bytes:
    total = AFC_HEADER.size + len(payload)
    return AFC_HEADER.pack(AFC_MAGIC, total, total, transaction, operation) + payload


def receive_afc(sock) -> tuple[int, bytes, int]:
    header = _read_exactly(sock, AFC_HEADER.size)
    magic, total, this, transaction, operation = AFC_HEADER.unpack(header)
    if magic != AFC_MAGIC:
        raise ProtocolError(f"AFC magic {magic!r} is not CFA6LPAA")
    if this < AFC_HEADER.size or this > MAXIMUM_FRAME or total < this:
        raise ProtocolError("the AFC header declares an impossible packet length")
    return operation, _read_exactly(sock, this - AFC_HEADER.size), transaction


def afc_status(status: int, message: str = "") -> bytes:
    """A STATUS payload: a little-endian error code, then a NUL-terminated text."""
    return struct.pack("<Q", status) + message.encode("utf-8") + b"\x00"


def parse_afc_status(payload: bytes) -> tuple[int, str]:
    if len(payload) < 8:
        raise ProtocolError("an AFC STATUS payload is shorter than its code")
    code = struct.unpack_from("<Q", payload, 0)[0]
    text = payload[8:].split(b"\x00", 1)[0].decode("utf-8", errors="replace")
    return code, text


def afc_file_info(values: dict) -> bytes:
    """GET_FILE_INFO payload: ``key\\0value\\0`` pairs, as AFC writes them."""
    chunks = []
    for key in sorted(values):
        chunks.append(key.encode() + b"\x00" + str(values[key]).encode() + b"\x00")
    return b"".join(chunks)


def parse_afc_file_info(payload: bytes) -> dict:
    parts = payload.split(b"\x00")
    result = {}
    for index in range(0, len(parts) - 1, 2):
        if not parts[index]:
            continue
        result[parts[index].decode("utf-8", errors="replace")] = parts[index + 1].decode(
            "utf-8", errors="replace")
    return result
