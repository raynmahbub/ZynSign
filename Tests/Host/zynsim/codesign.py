"""CodeDirectory construction, embedding and independent verification.

Everything here follows ``cs_blobs.h``: the magic numbers, the version-to-
header-size table, the trailing-field order, the special-slot numbering and the
page-hash rule. The numbers that matter:

===================  ================  ==============================
version              header bytes      trailing fields added
===================  ================  ==============================
``0x20001``          44                —
``0x20100``          48                ``scatterOffset``
``0x20200``          52                ``teamOffset``
``0x20300``          64                ``spare3``, ``codeLimit64``
``0x20400``          88                ``execSegBase/Limit/Flags``
``0x20500``          96                ``runtime``, ``preEncryptOffset``
``0x20600``          108               linkage fields
===================  ================  ==============================

A signature is a ``SuperBlob`` (``0xFADE0CC0``) of ``(slot, blob)`` pairs. The
CodeDirectory is slot 0; entitlements sit in special slots 5 (XML) and 7 (DER);
a certificate signature adds a ``BlobWrapper`` (``0xFADE0B01``) holding a
detached CMS ``SignedData`` at slot 0x10000. An ad-hoc signature has no
certificate and carries ``CS_ADHOC`` in the CodeDirectory flags.
"""

from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass, field

from . import cms, der, macho

CSMAGIC_REQUIREMENTS = 0xFADE0C01
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
CSMAGIC_EMBEDDED_DER_ENTITLEMENTS = 0xFADE7172
CSMAGIC_BLOBWRAPPER = 0xFADE0B01

CSSLOT_CODEDIRECTORY = 0
CSSLOT_REQUIREMENTS = 2
CSSLOT_ENTITLEMENTS = 5
CSSLOT_DER_ENTITLEMENTS = 7
CSSLOT_SIGNATURE = 0x10000

CS_ADHOC = 0x00000002
CS_RUNTIME = 0x00010000

CS_EXECSEG_MAIN_BINARY = 0x1

HASH_SHA1 = 1
HASH_SHA256 = 2
HASH_SIZES = {HASH_SHA1: 20, HASH_SHA256: 32}

PAGE_SHIFT_4K = 12

IMMUTABLE = 0
SUPPORTED_VERSIONS = (0x20001, 0x20100, 0x20200, 0x20300, 0x20400, 0x20500, 0x20600)


class SigningError(ValueError):
    """The image cannot be signed as asked, or the signature is malformed."""


def header_length(version: int) -> int:
    """Bytes from the magic to the end of the version's fixed fields."""
    table = {
        0x20001: 44,
        0x20100: 48,
        0x20200: 52,
        0x20300: 64,
        0x20400: 88,
        0x20500: 96,
        0x20600: 108,
    }
    if version not in table:
        raise SigningError(f"CodeDirectory version 0x{version:x} is not one this engine writes")
    return table[version]


def _digest(data: bytes, hash_type: int) -> bytes:
    if hash_type == HASH_SHA1:
        return hashlib.sha1(data).digest()
    if hash_type == HASH_SHA256:
        return hashlib.sha256(data).digest()
    raise SigningError(f"hash type {hash_type} is not supported")


def blob(magic: int, payload: bytes) -> bytes:
    return struct.pack(">II", magic, 8 + len(payload)) + payload


def parse_blob(data: bytes) -> tuple[int, bytes]:
    if len(data) < 8:
        raise SigningError("a signing blob is shorter than its header")
    magic, length = struct.unpack_from(">II", data, 0)
    if length != len(data):
        raise SigningError(f"blob 0x{magic:08x} declares {length} bytes, carries {len(data)}")
    return magic, data[8:]


def requirements_blob(expression: str | None = None) -> bytes:
    """An empty requirement set, or one containing a single expression."""
    if expression is None:
        return blob(CSMAGIC_REQUIREMENTS, struct.pack(">I", 0))
    encoded = expression.encode("utf-8") + b"\x00"
    header = struct.pack(">III", 0xFADE0C00, 12 + len(encoded), 0)
    return blob(CSMAGIC_REQUIREMENTS, struct.pack(">I", 1) + header + encoded)


def entitlements_blob(xml: bytes | None) -> bytes | None:
    return None if xml is None else blob(CSMAGIC_EMBEDDED_ENTITLEMENTS, xml)


def der_entitlements_blob(payload: bytes | None) -> bytes | None:
    return None if payload is None else blob(CSMAGIC_EMBEDDED_DER_ENTITLEMENTS, payload)


@dataclass
class CodeDirectory:
    """Every field of the structure, in the order the format writes them."""

    identifier: str
    team_id: str | None
    code_limit: int
    code_hashes: list[bytes]
    flags: int = 0
    version: int = 0x20400
    hash_type: int = HASH_SHA256
    page_size: int = PAGE_SHIFT_4K
    special_hashes: dict[int, bytes] = field(default_factory=dict)
    exec_segment: tuple[int, int, int] | None = None
    runtime: int = 0
    pre_encrypt_offset: int = 0
    linkage: tuple[int, int, int, int, int] | None = None

    @property
    def hash_size(self) -> int:
        return HASH_SIZES[self.hash_type]

    @property
    def special_slot_count(self) -> int:
        return max(self.special_hashes) if self.special_hashes else 0

    def _special_bytes(self) -> bytes:
        count = self.special_slot_count
        chunks = []
        for slot in range(count, 0, -1):
            digest = self.special_hashes.get(slot)
            chunks.append(digest if digest is not None else b"\x00" * self.hash_size)
        return b"".join(chunks)

    def serialize(self) -> bytes:
        size = header_length(self.version)
        identifier = self.identifier.encode("utf-8") + b"\x00"
        team = (self.team_id.encode("utf-8") + b"\x00") if self.team_id else b""
        special = self._special_bytes()
        hashes = b"".join(self.code_hashes)
        header_size = size
        identifier_offset = header_size
        team_offset = (identifier_offset + len(identifier)) if self.team_id else 0
        hash_offset = header_size + len(identifier) + len(team) + len(special)
        total = hash_offset + len(hashes)

        parts = [
            struct.pack(">IIIIIIIII", CSMAGIC_CODEDIRECTORY, total, self.version, self.flags,
                        hash_offset, identifier_offset, self.special_slot_count,
                        len(self.code_hashes), self.code_limit & 0xFFFFFFFF),
            struct.pack(">BBBB", self.hash_size, self.hash_type, IMMUTABLE,
                        self.page_size if self.page_size else 0),
            struct.pack(">I", 0),
        ]
        if self.version >= 0x20100:
            parts.append(struct.pack(">I", 0))
        if self.version >= 0x20200:
            parts.append(struct.pack(">I", team_offset))
        if self.version >= 0x20300:
            code_limit_64 = self.code_limit if self.code_limit > 0xFFFFFFFF else 0
            parts.append(struct.pack(">IQ", 0, code_limit_64))
        if self.version >= 0x20400:
            base, limit, flags = self.exec_segment or (0, 0, 0)
            parts.append(struct.pack(">QQQ", base, limit, flags))
        if self.version >= 0x20500:
            parts.append(struct.pack(">II", self.runtime, self.pre_encrypt_offset))
        if self.version >= 0x20600:
            hash_type, app_type, app_subtype, offset, length = self.linkage or (0, 0, 0, 0, 0)
            parts.append(struct.pack(">BBHII", hash_type, app_type, app_subtype, offset, length))
        parts.append(identifier)
        parts.append(team)
        parts.append(special)
        parts.append(hashes)
        encoded = b"".join(parts)
        if len(encoded) != total:
            raise SigningError(f"CodeDirectory planned {total} bytes, encoded {len(encoded)}")
        return encoded

    def planned_length(self) -> int:
        """The serialized length, without hashing anything for real."""
        hash_size = self.hash_size
        special = self.special_slot_count * hash_size
        identifier = len(self.identifier.encode("utf-8")) + 1
        team = (len(self.team_id.encode("utf-8")) + 1) if self.team_id else 0
        return header_length(self.version) + identifier + team + special + len(self.code_hashes) * hash_size


def build_code_directory(
    *,
    code: bytes,
    identifier: str,
    team_id: str | None = None,
    entitlements: bytes | None = None,
    der_entitlements: bytes | None = None,
    requirements: bytes | None = None,
    flags: int = 0,
    version: int = 0x20400,
    hash_type: int = HASH_SHA256,
    page_size: int = PAGE_SHIFT_4K,
    exec_segment: tuple[int, int, int] | None = None,
) -> CodeDirectory:
    if not identifier:
        raise SigningError("a CodeDirectory needs an identifier")
    if hash_type not in HASH_SIZES:
        raise SigningError(f"hash type {hash_type} is not supported")
    if version < 0x20400 and der_entitlements is not None:
        raise SigningError("the DER entitlements slot needs CodeDirectory 0x20400 or later")
    hash_size = HASH_SIZES[hash_type]
    page_bytes = 1 << page_size
    code_hashes = [_digest(code[offset:offset + page_bytes], hash_type)
                   for offset in range(0, len(code), page_bytes)]
    special: dict[int, bytes] = {}
    for slot, payload in ((CSSLOT_REQUIREMENTS, requirements),
                          (CSSLOT_ENTITLEMENTS, entitlements),
                          (CSSLOT_DER_ENTITLEMENTS, der_entitlements)):
        if payload is not None:
            digest = _digest(payload, hash_type)
            special[slot] = digest[:hash_size]
    return CodeDirectory(
        identifier=identifier,
        team_id=team_id,
        code_limit=len(code),
        code_hashes=code_hashes,
        flags=flags,
        version=version,
        hash_type=hash_type,
        page_size=page_size,
        special_hashes=special,
        exec_segment=exec_segment,
    )


def superblob(entries: list[tuple[int, bytes]]) -> bytes:
    """Embed blobs at slots, building the index before the contents."""
    entries = sorted(entries, key=lambda item: item[0])
    header = 12 + 8 * len(entries)
    offset = header
    index = b""
    content = b""
    for slot, payload in entries:
        index += struct.pack(">II", slot, offset)
        content += payload
        offset += len(payload)
    return struct.pack(">III", CSMAGIC_EMBEDDED_SIGNATURE, header + len(content), len(entries)) + index + content


def read_superblob(data: bytes) -> dict[int, bytes]:
    if len(data) < 12:
        raise SigningError("the embedded signature is shorter than a SuperBlob header")
    magic, length, count = struct.unpack_from(">III", data, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        raise SigningError(f"not a SuperBlob (magic 0x{magic:08x})")
    if length > len(data):
        raise SigningError("the SuperBlob declares more bytes than its region holds")
    if length < len(data) and any(data[length:]):
        raise SigningError("the bytes after the SuperBlob are not zero padding")
    if 12 + 8 * count > len(data):
        raise SigningError("the SuperBlob index runs past the blob")
    blobs: dict[int, bytes] = {}
    for index in range(count):
        slot, offset = struct.unpack_from(">II", data, 12 + 8 * index)
        if offset >= len(data):
            raise SigningError("a SuperBlob entry points outside the blob")
        _, payload_length = struct.unpack_from(">II", data, offset)
        blobs[slot] = data[offset:offset + payload_length]
    return blobs


@dataclass
class SigningOptions:
    identifier: str
    team_id: str | None = None
    entitlements_xml: bytes | None = None
    entitlements_der: bytes | None = None
    requirements: bytes | None = None
    embed_requirements: bool = True
    identity: cms.CertificateIdentity | None = None
    intermediates: list[bytes] | None = None
    adhoc: bool = False
    hardened_runtime: bool = False
    version: int = 0x20400
    hash_type: int = HASH_SHA256
    exec_segment_flags: int = 0


@dataclass
class SignatureInfo:
    code_directory: CodeDirectory
    data_offset: int
    data_size: int
    blobs: list[int]

    @property
    def adhoc(self) -> bool:
        return bool(self.code_directory.flags & CS_ADHOC)


def sign_image(data: bytes, options: SigningOptions) -> tuple[bytes, SignatureInfo]:
    """Sign a thin Mach-O image and return the new bytes and what went in.

    The order matters. ``LC_CODE_SIGNATURE`` must exist and point at the region
    *before* any page is hashed, because the load commands are inside the hashed
    region. The signature's length therefore has to be known before its content:
    every field is sized from the key, the identifier and the blob headers, and
    the real hashes are filled in afterwards at the same offsets.
    """
    if not options.identifier:
        raise SigningError("a signature needs an identifier")
    image = macho.MachO(bytes(data))
    if image.code_signature_command() is not None:
        raise SigningError("the image already carries a signature")
    if options.adhoc and options.identity is not None:
        raise SigningError("an ad-hoc signature has no certificate")
    if not options.adhoc and options.identity is None:
        raise SigningError("a certificate signature needs a signing identity")

    requirements = options.requirements
    if requirements is None and options.embed_requirements:
        requirements = requirements_blob()
    entitlements = entitlements_blob(options.entitlements_xml)
    der_entitlements = der_entitlements_blob(options.entitlements_der)

    flags = CS_ADHOC if options.adhoc else 0
    if options.hardened_runtime:
        flags |= CS_RUNTIME

    text_offset, text_size, _ = image.executable_segment()

    def plan(code_limit: int) -> CodeDirectory:
        return build_code_directory(
            code=b"\x00" * code_limit,
            identifier=options.identifier,
            team_id=options.team_id,
            entitlements=entitlements,
            der_entitlements=der_entitlements,
            requirements=requirements,
            flags=flags,
            version=options.version,
            hash_type=options.hash_type,
            exec_segment=(text_offset, text_size, options.exec_segment_flags),
        )

    # 1. Size the CodeDirectory from a code-length-only plan: every field that
    #    affects its length is already known, and the placeholder hashes have
    #    the final width.
    signature_offset = macho.align(len(image.data), 16)
    placeholder = plan(signature_offset)
    code_directory_size = placeholder.planned_length()
    cms_size = 0
    if not options.adhoc:
        cms_size = 8 + cms.planned_length(options.identity, options.intermediates)
    # Slot 2 carries the requirements blob, which is also hashed into special
    # slot 2 — the two must agree or the signature is self-inconsistent.
    planned_blobs = [(CSSLOT_CODEDIRECTORY, code_directory_size)]
    if requirements is not None:
        planned_blobs.append((CSSLOT_REQUIREMENTS, len(requirements)))
    if entitlements is not None:
        planned_blobs.append((CSSLOT_ENTITLEMENTS, len(entitlements)))
    if der_entitlements is not None:
        planned_blobs.append((CSSLOT_DER_ENTITLEMENTS, len(der_entitlements)))
    if not options.adhoc:
        planned_blobs.append((CSSLOT_SIGNATURE, cms_size))
    # Each value is a complete blob: the CodeDirectory includes its own 8-byte
    # header, and ``cms_size`` already includes the BlobWrapper header.
    superblob_size = 12 + 8 * len(planned_blobs) + sum(size for _, size in planned_blobs)
    file_length = signature_offset + superblob_size

    # 2. Point the load command at that region and grow __LINKEDIT, before any
    #    byte is hashed.
    image.plan_code_signature_command(signature_offset, superblob_size)
    image.grow_linkedit(file_length)
    prefix = bytearray(image.bytes())
    if len(prefix) < signature_offset:
        prefix.extend(b"\x00" * (signature_offset - len(prefix)))

    # 3. Hash what the load commands now say, and build the real directory.
    directory = build_code_directory(
        code=bytes(prefix),
        identifier=options.identifier,
        team_id=options.team_id,
        entitlements=entitlements,
        der_entitlements=der_entitlements,
        requirements=requirements,
        flags=flags,
        version=options.version,
        hash_type=options.hash_type,
        exec_segment=(text_offset, text_size, options.exec_segment_flags),
    )
    directory_bytes = directory.serialize()
    if len(directory_bytes) != code_directory_size:
        raise SigningError("the planned and actual CodeDirectory lengths disagree")

    entries: list[tuple[int, bytes]] = [(CSSLOT_CODEDIRECTORY, directory_bytes)]
    if requirements is not None:
        entries.append((CSSLOT_REQUIREMENTS, requirements))
    if entitlements is not None:
        entries.append((CSSLOT_ENTITLEMENTS, entitlements))
    if der_entitlements is not None:
        entries.append((CSSLOT_DER_ENTITLEMENTS, der_entitlements))
    if not options.adhoc:
        wrapper = blob(CSMAGIC_BLOBWRAPPER,
                       cms.build(directory_bytes, options.identity, options.intermediates))
        if len(wrapper) != cms_size:
            raise SigningError("the planned and actual CMS lengths disagree")
        entries.append((CSSLOT_SIGNATURE, wrapper))
    embedded = superblob(entries)
    if len(embedded) != superblob_size:
        raise SigningError("the planned and actual SuperBlob lengths disagree")

    signed = bytes(prefix) + embedded
    info = SignatureInfo(directory, signature_offset, len(embedded), [slot for slot, _ in entries])
    return signed, info


# MARK: - Verification


@dataclass
class VerificationReport:
    valid: bool
    page_hashes_valid: bool
    special_slots_valid: bool
    cms_present: bool
    cms_valid: bool
    adhoc: bool
    version: int
    identifier: str
    team_id: str | None
    code_limit: int
    code_slots: int
    special_slots: int
    hash_type: int
    flags: int
    dylibs: list[str]
    executable_block: tuple[int, int, int] | None
    problems: list[str] = field(default_factory=list)


def verify_image(data: bytes) -> VerificationReport:
    """Re-derive every digest from the bytes and compare with the signature.

    A malformed signature is a rejection, not an exception: a verifier that
    raises on hostile input hands the caller a decision it must not have to
    make. Structural problems surface as ``valid == False`` with a ``problems``
    entry that says what was wrong.
    """
    try:
        return _verify_image(data)
    except (SigningError, macho.MachOError) as error:
        return VerificationReport(
            valid=False, page_hashes_valid=False, special_slots_valid=False,
            cms_present=False, cms_valid=False, adhoc=False, version=0,
            identifier="", team_id=None, code_limit=0, code_slots=0, special_slots=0,
            hash_type=0, flags=0, dylibs=[], executable_block=None,
            problems=[str(error)],
        )


def _verify_image(data: bytes) -> VerificationReport:
    image = macho.MachO(bytes(data))
    command = image.code_signature_command()
    if command is None:
        raise SigningError("the image carries no signature")
    data_offset, data_size = command
    if data_size == 0:
        raise SigningError("LC_CODE_SIGNATURE points at an empty region")
    if data_offset + data_size > len(data):
        raise SigningError("the signature region runs past the image")
    blobs = read_superblob(bytes(data[data_offset:data_offset + data_size]))
    if CSSLOT_CODEDIRECTORY not in blobs:
        raise SigningError("the SuperBlob has no CodeDirectory")
    directory_bytes = blobs[CSSLOT_CODEDIRECTORY]
    magic, _ = parse_blob(directory_bytes)
    if magic != CSMAGIC_CODEDIRECTORY:
        raise SigningError(f"slot 0 is not a CodeDirectory (magic 0x{magic:08x})")
    if len(directory_bytes) < 44:
        raise SigningError("the CodeDirectory is shorter than its fixed header")
    # Every offset below is from the start of the blob, not from its payload:
    # magic and length occupy the first eight bytes.
    blob_bytes = directory_bytes
    (_, _, version, flags, hash_offset, identifier_offset, special_count, code_count,
     code_limit) = struct.unpack_from(">IIIIIIIII", blob_bytes, 0)
    hash_size = blob_bytes[36]
    hash_type = blob_bytes[37]
    page_shift = blob_bytes[39]
    if hash_type not in HASH_SIZES:
        raise SigningError(f"hash type {hash_type} is not supported")
    if hash_size != HASH_SIZES[hash_type]:
        raise SigningError("the CodeDirectory's hash size does not match its hash type")
    try:
        identifier = blob_bytes[identifier_offset:blob_bytes.index(b"\x00", identifier_offset)].decode("utf-8")
    except ValueError as error:
        raise SigningError("the identifier is not NUL-terminated") from error
    team_id = None
    if version >= 0x20200:
        team_offset = struct.unpack_from(">I", blob_bytes, 48)[0]
        if team_offset:
            team_id = blob_bytes[team_offset:blob_bytes.index(b"\x00", team_offset)].decode("utf-8")
    exec_block = None
    if version >= 0x20400:
        base, limit, exec_flags = struct.unpack_from(">QQQ", blob_bytes, 64)
        exec_block = (base, limit, exec_flags)

    problems: list[str] = []
    page_size = 1 << page_shift if page_shift else 0
    if page_shift == 0:
        raise SigningError("page size 0 is not a layout this verifier reads")
    code_limit_value = code_limit
    if version >= 0x20300:
        limit64 = struct.unpack_from(">Q", blob_bytes, 56)[0]
        if limit64:
            code_limit_value = limit64
    expected_slots = (code_limit_value + page_size - 1) // page_size
    if expected_slots != code_count:
        problems.append(f"the CodeDirectory covers {code_count} pages, the code limit needs {expected_slots}")
    if hash_offset + code_count * hash_size > len(blob_bytes):
        raise SigningError("the code hashes run past the CodeDirectory")

    def digest(chunk: bytes) -> bytes:
        return _digest(chunk, hash_type)[:hash_size]

    page_hashes_valid = True
    for index in range(code_count):
        start = index * page_size
        end = min(start + page_size, code_limit_value)
        stored = blob_bytes[hash_offset + index * hash_size:hash_offset + (index + 1) * hash_size]
        if stored != digest(bytes(data[start:end])):
            page_hashes_valid = False
            problems.append(f"page {index} does not match its recorded hash")
            break

    special_slots_valid = True
    special_base = hash_offset
    slot_payloads = {
        CSSLOT_REQUIREMENTS: blobs.get(CSSLOT_REQUIREMENTS),
        CSSLOT_ENTITLEMENTS: blobs.get(CSSLOT_ENTITLEMENTS),
        CSSLOT_DER_ENTITLEMENTS: blobs.get(CSSLOT_DER_ENTITLEMENTS),
    }
    for slot in range(1, special_count + 1):
        recorded = blob_bytes[special_base - slot * hash_size:special_base - (slot - 1) * hash_size]
        payload = slot_payloads.get(slot)
        if payload is None:
            if recorded != b"\x00" * hash_size:
                special_slots_valid = False
                problems.append(f"reserved special slot {slot} is not zero")
            continue
        if recorded != digest(payload):
            special_slots_valid = False
            problems.append(f"special slot {slot} does not match its blob")

    cms_present = CSSLOT_SIGNATURE in blobs
    cms_valid = False
    if cms_present:
        wrapper_magic, wrapper_body = parse_blob(blobs[CSSLOT_SIGNATURE])
        if wrapper_magic != CSMAGIC_BLOBWRAPPER:
            problems.append(f"slot 0x10000 is not a BlobWrapper (magic 0x{wrapper_magic:08x})")
        else:
            cms_valid = cms.verify(wrapper_body, directory_bytes)
            if not cms_valid:
                problems.append("the CMS signature does not verify over the CodeDirectory")
    if not cms_present and not flags & CS_ADHOC:
        problems.append("the image has neither a CMS signature nor CS_ADHOC")

    valid = page_hashes_valid and special_slots_valid and (cms_valid or bool(flags & CS_ADHOC))
    return VerificationReport(
        valid=valid,
        page_hashes_valid=page_hashes_valid,
        special_slots_valid=special_slots_valid,
        cms_present=cms_present,
        cms_valid=cms_valid,
        adhoc=bool(flags & CS_ADHOC),
        version=version,
        identifier=identifier,
        team_id=team_id,
        code_limit=code_limit_value,
        code_slots=code_count,
        special_slots=special_count,
        hash_type=hash_type,
        flags=flags,
        dylibs=image.dylib_paths(),
        executable_block=exec_block,
        problems=problems,
    )
