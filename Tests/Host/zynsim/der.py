"""Minimal DER reader and writer for the structures code signing needs.

Only what a signature touches: the primitives inside a certificate, the CMS
``SignedData`` a detached signature is built from, and the typed values DER
entitlements map to. Nothing here parses a general X.509 tree — the host suite
reads certificates, it does not validate them.

The writer emits definite-length DER: short form below 128 bytes, long form
otherwise, with the minimum number of length octets. Every encoder appends to
an existing ``bytearray`` so callers can build nested structures without
temporary buffers.
"""

from __future__ import annotations

# Universal tags used below.
INTEGER = 0x02
BIT_STRING = 0x03
OCTET_STRING = 0x04
NULL = 0x05
OBJECT_IDENTIFIER = 0x06
UTF8_STRING = 0x0C
SEQUENCE = 0x30
SET = 0x31
BOOLEAN = 0x01
# Context-specific constructed tag n is 0xA0 | n; context-specific primitive
# tag n is 0x80 | n.
CONTEXT_0 = 0xA0
CONTEXT_3 = 0xA3


class DERError(ValueError):
    """A frame is not DER, or is not the DER this reader expected."""


def encode_length(length: int) -> bytes:
    if length < 0:
        raise DERError("negative length")
    if length < 0x80:
        return bytes([length])
    encoded = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(encoded)]) + encoded


def tlv(tag: int, value: bytes) -> bytes:
    return bytes([tag]) + encode_length(len(value)) + value


def sequence(*parts: bytes) -> bytes:
    return tlv(SEQUENCE, b"".join(parts))


def set_of(*parts: bytes) -> bytes:
    return tlv(SET, b"".join(parts))


def integer(value: int) -> bytes:
    if value < 0:
        raise DERError("negative integer")
    if value == 0:
        return tlv(INTEGER, b"\x00")
    body = value.to_bytes((value.bit_length() + 7) // 8, "big")
    if body[0] & 0x80:
        body = b"\x00" + body
    return tlv(INTEGER, body)


def boolean(value: bool) -> bytes:
    return tlv(BOOLEAN, b"\xff" if value else b"\x00")


def octet_string(value: bytes) -> bytes:
    return tlv(OCTET_STRING, value)


def utf8_string(value: str) -> bytes:
    return tlv(UTF8_STRING, value.encode("utf-8"))


def null() -> bytes:
    return tlv(NULL, b"")


def oid(dotted: str) -> bytes:
    """Encode a dotted object identifier."""
    parts = [int(part) for part in dotted.split(".")]
    if len(parts) < 2:
        raise DERError(f"not an object identifier: {dotted}")
    body = bytearray([40 * parts[0] + parts[1]])
    for part in parts[2:]:
        chunk = bytearray([part & 0x7F])
        part >>= 7
        while part:
            chunk.insert(0, 0x80 | (part & 0x7F))
            part >>= 7
        body.extend(chunk)
    return tlv(OBJECT_IDENTIFIER, bytes(body))


class Node:
    """One parsed TLV: its tag, its value bytes, and where it ended."""

    __slots__ = ("tag", "value", "start", "header_end", "end")

    def __init__(self, tag: int, value: memoryview, start: int, header_end: int, end: int):
        self.tag = tag
        self.value = value
        self.start = start
        self.header_end = header_end
        self.end = end

    @property
    def constructed(self) -> bool:
        return bool(self.tag & 0x20)

    @property
    def raw(self) -> bytes:
        return bytes(self.value)

    def children(self) -> list["Node"]:
        if not self.constructed:
            raise DERError(f"tag 0x{self.tag:02x} is primitive")
        result: list[Node] = []
        offset = 0
        data = bytes(self.value)
        while offset < len(data):
            node = read(data, offset)
            result.append(node)
            offset = node.end
        return result

    def child(self, index: int) -> "Node":
        children = self.children()
        if index >= len(children):
            raise DERError(f"tag 0x{self.tag:02x} has {len(children)} children, wanted #{index}")
        return children[index]

    def as_integer(self) -> int:
        if self.tag != INTEGER:
            raise DERError(f"tag 0x{self.tag:02x} is not an INTEGER")
        return int.from_bytes(self.raw, "big", signed=False)

    def as_oid(self) -> str:
        if self.tag != OBJECT_IDENTIFIER:
            raise DERError(f"tag 0x{self.tag:02x} is not an OBJECT IDENTIFIER")
        body = self.raw
        first = body[0]
        parts = [first // 40, first % 40]
        value = 0
        for byte in body[1:]:
            value = (value << 7) | (byte & 0x7F)
            if not byte & 0x80:
                parts.append(value)
                value = 0
        return ".".join(str(part) for part in parts)

    def as_string(self) -> str:
        return self.raw.decode("utf-8")

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"Node(tag=0x{self.tag:02x}, length={len(self.value)})"


def read(data: bytes, offset: int = 0) -> Node:
    if offset + 2 > len(data):
        raise DERError("truncated tag or length")
    tag = data[offset]
    length_byte = data[offset + 1]
    header = 2
    if length_byte & 0x80:
        count = length_byte & 0x7F
        if count == 0 or count > 4:
            raise DERError("unsupported length encoding")
        if offset + 2 + count > len(data):
            raise DERError("truncated long-form length")
        length = int.from_bytes(data[offset + 2:offset + 2 + count], "big")
        header += count
    else:
        length = length_byte
    start = offset + header
    end = start + length
    if end > len(data):
        raise DERError(f"declared length {length} runs past the buffer")
    return Node(tag, memoryview(data)[start:end], offset, start, end)


def read_all(data: bytes) -> list[Node]:
    nodes: list[Node] = []
    offset = 0
    while offset < len(data):
        node = read(data, offset)
        nodes.append(node)
        offset = node.end
    return nodes
