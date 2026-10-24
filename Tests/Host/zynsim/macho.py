"""Mach-O reading and the two edits code signing makes to a header.

The reader is deliberately small: it walks the load commands, records the
segments and sections, and knows where the load-command area ends. That is
enough to answer the only questions signing asks —

* is there room for another load command, and where does the first file-backed
  byte live (the header-padding boundary)?
* where is ``LC_CODE_SIGNATURE``, and what does it currently point at?
* which ``__LINKEDIT`` segment must grow to cover the signature?

Two mutations are supported, both of which keep every existing file offset
where it was: inserting a load command into header padding, and rewriting the
``__LINKEDIT`` segment's file size. Moving content would invalidate every
offset in the file, and neither zsign nor ``codesign`` needs to.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field

MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM = 0xCEFAEDFE
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

MH_EXECUTE = 0x2
MH_DYLIB = 0x6
MH_BUNDLE = 0x8

LC_SEGMENT = 0x1
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_ID_DYLIB = 0x0D
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023

DYLIB_COMMAND_TYPES = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB)

_CODE_SIGNATURE_COMMAND_SIZE = 16


class MachOError(ValueError):
    """The image cannot be read, or cannot take the edit that was asked for."""


def align(value: int, boundary: int) -> int:
    return (value + boundary - 1) // boundary * boundary


def _cstring(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace")


@dataclass
class Section:
    name: str
    segment: str
    address: int
    size: int
    offset: int


@dataclass
class Segment:
    name: str
    vm_address: int
    vm_size: int
    file_offset: int
    file_size: int
    file_size_field: int  # absolute offset of the uint32/uint64 field
    sections: list[Section] = field(default_factory=list)


@dataclass
class LoadCommand:
    type: int
    offset: int
    size: int


class MachO:
    """A thin Mach-O image, mutable in place through the helpers below."""

    def __init__(self, data: bytes | bytearray):
        self.data = bytearray(data)
        self._parse()

    # MARK: - Reading

    def _parse(self) -> None:
        data = self.data
        if len(data) < 4:
            raise MachOError("the image is shorter than a magic number")
        magic = struct.unpack_from("<I", data, 0)[0]
        if magic in (FAT_MAGIC, FAT_MAGIC_64) or struct.unpack_from(">I", data, 0)[0] in (FAT_MAGIC, FAT_MAGIC_64):
            raise MachOError("universal images are not supported; sign each slice")
        if magic == MH_CIGAM_64 or magic == MH_CIGAM:
            raise MachOError("big-endian images are not supported")
        if magic not in (MH_MAGIC, MH_MAGIC_64):
            raise MachOError(f"not a Mach-O image (magic 0x{magic:08x})")
        self.is_64 = magic == MH_MAGIC_64
        self.header_size = 32 if self.is_64 else 28
        if len(data) < self.header_size:
            raise MachOError("the image is shorter than its header")
        self.cpu_type, self.cpu_subtype, self.filetype, self.command_count, self.command_bytes, self.flags = (
            struct.unpack_from("<iiIIII", data, 4)
        )
        self.commands: list[LoadCommand] = []
        self.segments: list[Segment] = []
        offset = self.header_size
        for _ in range(self.command_count):
            if offset + 8 > len(data):
                raise MachOError("a load command runs past the end of the image")
            command, size = struct.unpack_from("<II", data, offset)
            if size < 8 or offset + size > len(data):
                raise MachOError(f"load command 0x{command:x} has an invalid size")
            self.commands.append(LoadCommand(command, offset, size))
            if command in (LC_SEGMENT, LC_SEGMENT_64) and size >= (72 if self.is_64 else 56):
                self.segments.append(self._segment(offset, size))
            offset += size
        if offset != self.header_size + self.command_bytes:
            raise MachOError("the declared load-command size does not match the commands")
        self.load_commands_end = offset

    def _segment(self, offset: int, size: int) -> Segment:
        data = self.data
        if self.is_64:
            name = _cstring(bytes(data[offset + 8:offset + 24]))
            vm_address, vm_size, file_offset, file_size = struct.unpack_from("<QQQQ", data, offset + 24)
            section_count = struct.unpack_from("<I", data, offset + 64)[0]
            sections_start = offset + 72
            section_size = 80
            size_field = offset + 48
        else:
            name = _cstring(bytes(data[offset + 8:offset + 24]))
            vm_address, vm_size, file_offset, file_size = struct.unpack_from("<IIII", data, offset + 24)
            section_count = struct.unpack_from("<I", data, offset + 48)[0]
            sections_start = offset + 56
            section_size = 68
            size_field = offset + 40
        sections: list[Section] = []
        for index in range(section_count):
            start = sections_start + index * section_size
            if start + section_size > offset + size:
                raise MachOError("a section table runs past its segment command")
            section_name = _cstring(bytes(data[start:start + 16]))
            segment_name = _cstring(bytes(data[start + 16:start + 32]))
            if self.is_64:
                address, length, file_offset_section = struct.unpack_from("<QQI", data, start + 32)
            else:
                address, length, file_offset_section = struct.unpack_from("<III", data, start + 32)
            sections.append(Section(section_name, segment_name, address, length, file_offset_section))
        return Segment(name, vm_address, vm_size, file_offset, file_size, size_field, sections)

    # MARK: - Queries

    def command(self, command_type: int) -> LoadCommand | None:
        for command in self.commands:
            if command.type == command_type:
                return command
        return None

    def segment(self, name: str) -> Segment | None:
        for segment in self.segments:
            if segment.name == name:
                return segment
        return None

    def dylib_paths(self) -> list[str]:
        paths = []
        for command in self.commands:
            if command.type in DYLIB_COMMAND_TYPES:
                name_offset = struct.unpack_from("<I", self.data, command.offset + 8)[0]
                start = command.offset + name_offset
                end = self.data.index(b"\x00", start)
                paths.append(bytes(self.data[start:end]).decode("utf-8", errors="replace"))
        return paths

    def code_signature_command(self) -> tuple[int, int] | None:
        command = self.command(LC_CODE_SIGNATURE)
        if command is None:
            return None
        data_offset, data_size = struct.unpack_from("<II", self.data, command.offset + 8)
        return data_offset, data_size

    def first_file_backed_offset(self) -> int:
        """The lowest file offset any load command content occupies."""
        candidates = []
        for segment in self.segments:
            for section in segment.sections:
                if section.size > 0 and section.offset > 0:
                    candidates.append(section.offset)
        for segment in self.segments:
            if segment.file_offset > 0 and segment.file_size > 0 and segment.name != "__LINKEDIT":
                candidates.append(segment.file_offset)
        if candidates:
            return min(candidates)
        for segment in self.segments:
            if segment.file_offset > 0 and segment.file_size > 0:
                return segment.file_offset
        raise MachOError("the image has no file-backed segment to bound its header")

    def header_padding(self) -> int:
        return self.first_file_backed_offset() - self.load_commands_end

    # MARK: - Mutations

    def set_filetype(self, filetype: int) -> None:
        struct.pack_into("<I", self.data, 12, filetype)
        self.filetype = filetype

    def insert_load_command(self, command: bytes) -> int:
        """Write ``command`` into header padding; return its offset."""
        size = len(command)
        if size < 8 or size % 8:
            raise MachOError("a load command must be at least 8 bytes and a multiple of 8")
        if self.header_padding() < size:
            raise MachOError(
                f"the header has {self.header_padding()} bytes of padding, the command needs {size}")
        start = self.load_commands_end
        self.data[start:start + size] = command
        struct.pack_into("<I", self.data, 16, self.command_count + 1)
        struct.pack_into("<I", self.data, 20, self.command_bytes + size)
        self.command_count += 1
        self.command_bytes += size
        self.load_commands_end += size
        self.commands.append(LoadCommand(struct.unpack_from("<I", command, 0)[0], start, size))
        return start

    def inject_dylib(self, path: str, weak: bool = False) -> int:
        """Add ``LC_LOAD_DYLIB`` (or the weak form) naming ``path``."""
        if self.command(LC_CODE_SIGNATURE) is not None:
            raise MachOError("the image is already signed; inject before signing")
        if not path or "\x00" in path:
            raise MachOError("a dylib install name must be non-empty and contain no NUL")
        encoded = path.encode("utf-8") + b"\x00"
        command_size = align(24 + len(encoded), 8)
        command = bytearray(command_size)
        struct.pack_into("<IIIIII", command, 0,
                         LC_LOAD_WEAK_DYLIB if weak else LC_LOAD_DYLIB,
                         command_size, 24, 2, 0x00010000, 0x00010000)
        command[24:24 + len(encoded)] = encoded
        return self.insert_load_command(bytes(command))

    def plan_code_signature_command(self, data_offset: int, data_size: int) -> None:
        """Point ``LC_CODE_SIGNATURE`` at a region, adding the command if needed."""
        command = self.command(LC_CODE_SIGNATURE)
        if command is not None:
            struct.pack_into("<II", self.data, command.offset + 8, data_offset, data_size)
            return
        if self.header_padding() < _CODE_SIGNATURE_COMMAND_SIZE:
            raise MachOError(
                "the header has no room for LC_CODE_SIGNATURE; the image cannot be signed")
        command = struct.pack("<IIII", LC_CODE_SIGNATURE, _CODE_SIGNATURE_COMMAND_SIZE,
                              data_offset, data_size)
        self.insert_load_command(command)

    def grow_linkedit(self, new_file_length: int) -> None:
        """Make ``__LINKEDIT`` cover up to ``new_file_length``."""
        segment = self.segment("__LINKEDIT")
        if segment is None:
            raise MachOError("the image has no __LINKEDIT segment to extend")
        if new_file_length < segment.file_offset:
            raise MachOError("the new length ends before __LINKEDIT starts")
        file_size = new_file_length - segment.file_offset
        if self.is_64:
            struct.pack_into("<Q", self.data, segment.file_size_field, file_size)
            vm_size_field = segment.file_size_field - 8
            current_vm_size = struct.unpack_from("<Q", self.data, vm_size_field)[0]
            if current_vm_size < file_size:
                struct.pack_into("<Q", self.data, vm_size_field, align(file_size, 0x4000))
            segment.vm_size = max(current_vm_size, align(file_size, 0x4000))
        else:
            struct.pack_into("<I", self.data, segment.file_size_field, file_size)
            vm_size_field = segment.file_size_field - 4
            current_vm_size = struct.unpack_from("<I", self.data, vm_size_field)[0]
            if current_vm_size < file_size:
                struct.pack_into("<I", self.data, vm_size_field, align(file_size, 0x4000))
            segment.vm_size = max(current_vm_size, align(file_size, 0x4000))
        segment.file_size = file_size

    def executable_segment(self) -> tuple[int, int, int]:
        """(file offset, file size, word size) of ``__TEXT`` for exec-seg fields."""
        segment = self.segment("__TEXT")
        if segment is None:
            raise MachOError("the image has no __TEXT segment")
        return segment.file_offset, segment.file_size, self.header_size

    def bytes(self) -> bytes:
        return bytes(self.data)


def parse(data: bytes) -> MachO:
    return MachO(data)


def reject_signed(data: bytes) -> None:
    image = MachO(data)
    if image.code_signature_command() is not None:
        raise MachOError("the image already carries a signature")
