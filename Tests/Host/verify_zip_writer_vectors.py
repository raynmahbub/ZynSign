#!/usr/bin/env python3
"""Independent checks of the deterministic ZIP writer's golden vectors.

Reads the base64 vectors committed in Tests/ZynSignTests/ZipArchiveWriterTests.swift
and verifies them with Python's standard library only: field-by-field
structure checks with struct, CRC-32 with zlib, and a full parse with
zipfile. This is a development check, never a product runtime subprocess.
"""
import base64
from pathlib import Path
import re
import struct
import sys
import tempfile
import zipfile
import zlib


def load_vectors():
    text = (Path(__file__).resolve().parents[1] /
            "ZynSignTests/ZipArchiveWriterTests.swift").read_text()
    inline = re.findall(r'try golden\("([A-Za-z0-9+/=]+)"\)', text)
    assert len(inline) == 2, f"expected 2 inline vectors, found {len(inline)}"
    mixed = re.search(r'private let mixedGoldenBase64 = "([A-Za-z0-9+/=]+)"', text)
    assert mixed, "mixed golden vector not found"
    return {
        "empty": base64.b64decode(inline[0]),
        "single": base64.b64decode(inline[1]),
        "mixed": base64.b64decode(mixed.group(1)),
    }


def check_empty(data):
    assert len(data) == 22, f"empty vector is {len(data)} bytes, expected 22"
    sig, disk, start, count_disk, count, size, offset, comment = struct.unpack("<IHHHHIIH", data)
    assert sig == 0x06054B50, f"bad end-of-central-directory signature {sig:#x}"
    assert (disk, start, count_disk, count, size, offset, comment) == (0, 0, 0, 0, 0, 0, 0)


def parse_entries(data):
    """Returns (locals, centrals, end) with raw field tuples."""
    locals_, centrals = [], []
    pos = 0
    while True:
        (sig,) = struct.unpack_from("<I", data, pos)
        if sig == 0x06054B50:
            end = struct.unpack_from("<IHHHHIIH", data, pos)
            assert pos + 22 == len(data), "trailing bytes after end record"
            return locals_, centrals, end
        if sig == 0x04034B50:
            (_s, ver, flags, method, time, date, crc, comp, uncomp, nlen, elen) = \
                struct.unpack_from("<IHHHHHIIIHH", data, pos)
            name = data[pos + 30:pos + 30 + nlen]
            content = data[pos + 30 + nlen + elen:pos + 30 + nlen + elen + comp]
            assert len(content) == comp, "truncated local content"
            locals_.append((ver, flags, method, time, date, crc, comp, uncomp, name, content))
            pos += 30 + nlen + elen + comp
        elif sig == 0x02014B50:
            fields = struct.unpack_from("<IHHHHHHIIIHHHHHII", data, pos)
            (_s, madeby, ver, flags, method, time, date, crc, comp, uncomp,
             nlen, elen, clen, _d1, _d2, attrs, offset) = fields
            name = data[pos + 46:pos + 46 + nlen]
            centrals.append((madeby, ver, flags, method, time, date, crc, comp,
                             uncomp, name, attrs, offset, elen, clen))
            pos += 46 + nlen + elen + clen
        else:
            raise AssertionError(f"unexpected signature {sig:#x} at offset {pos}")


def check_fixed_fields(entries, kind="local"):
    for entry in entries:
        if kind == "local":
            ver, flags, method, time, date = entry[0], entry[1], entry[2], entry[3], entry[4]
            assert (ver, flags, method, time, date) == (20, 0x0800, 0, 0, 0x21), \
                f"local fixed fields diverge: {(ver, flags, method, time, date)}"
        else:
            madeby, ver, flags, method, time, date = entry[0:6]
            assert (madeby, ver, flags, method, time, date) == (0x032D, 20, 0x0800, 0, 0, 0x21), \
                "central fixed fields diverge"
            assert entry[12] == 0 and entry[13] == 0, "central extra/comment must be empty"


def check_single(data):
    assert len(data) == 110, f"single vector is {len(data)} bytes, expected 110"
    locals_, centrals, end = parse_entries(data)
    assert len(locals_) == 1 and len(centrals) == 1
    check_fixed_fields(locals_)
    check_fixed_fields(centrals, kind="central")
    ver, flags, method, time, date, crc, comp, uncomp, name, content = locals_[0]
    assert name == b"a.txt", f"unexpected name {name!r}"
    assert content == b"AB", f"unexpected content {content!r}"
    assert comp == uncomp == 2
    assert crc == zlib.crc32(b"AB"), "local CRC does not match content"
    madeby, _v, _f, _m, _t, _d, ccrc, ccomp, cuncomp, cname, attrs, offset, _e, _c = centrals[0]
    assert (ccrc, ccomp, cuncomp, cname, offset) == (crc, 2, 2, b"a.txt", 0)
    assert attrs == 0o100644 << 16, f"central mode {attrs:#x} is not a plain file"
    _s, _d, _st, count_disk, count, size, coffset, _c = end
    assert (count_disk, count) == (1, 1)
    assert coffset == 30 + 5 + 2, f"central offset {coffset} does not follow the local entry"
    assert size == 46 + 5, f"central size {size} does not match one record"


def check_mixed(data):
    assert len(data) == 595, f"mixed vector is {len(data)} bytes, expected 595"
    locals_, centrals, end = parse_entries(data)
    assert len(locals_) == 5 and len(centrals) == 5
    check_fixed_fields(locals_)
    check_fixed_fields(centrals, kind="central")
    expected = [
        (b"Payload/", b"", 0o40755),
        (b"Payload/App.app/", b"", 0o40755),
        (b"Payload/App.app/App", bytes([1, 2, 3, 4]), 0o100755),
        (b"Payload/App.app/Info.plist", b"<plist/>", 0o100644),
        (b"Payload/App.app/Link", b"App", 0o120777),
    ]
    names = [entry[8] for entry in locals_]
    assert names == [name for name, _, _ in expected], f"entry order diverges: {names!r}"
    assert names == sorted(names), "entries are not in ascending byte order"
    assert [entry[9] for entry in centrals] == names, "central names diverge from local names"
    offset = 0
    for local, central, (name, content, mode) in zip(locals_, centrals, expected):
        _v, _f, _m, _t, _d, crc, comp, uncomp, _n, body = local
        assert body == content, f"content diverges for {name!r}"
        assert comp == uncomp == len(content)
        assert crc == zlib.crc32(content), f"CRC diverges for {name!r}"
        assert central[6:10] == (crc, comp, uncomp, name), f"central fields diverge for {name!r}"
        assert central[10] == mode << 16, f"mode diverges for {name!r}"
        assert central[11] == offset, f"local offset diverges for {name!r}"
        offset += 30 + len(name) + len(content)
    _s, _d, _st, count_disk, count, size, coffset, _c = end
    assert (count_disk, count) == (5, 5)
    assert coffset == offset, "central directory does not follow the local entries"
    assert size == sum(46 + len(name) for name, _, _ in expected)


def check_zipfile(name, data):
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as tmp:
        tmp.write(data)
        path = tmp.name
    try:
        with zipfile.ZipFile(path) as archive:
            assert archive.testzip() is None, f"{name}: zipfile reports a corrupt member"
            for info in archive.infolist():
                assert info.compress_type == zipfile.ZIP_STORED, f"{name}: {info.filename} is not stored"
    finally:
        Path(path).unlink()


def main():
    vectors = load_vectors()
    check_empty(vectors["empty"])
    check_single(vectors["single"])
    check_mixed(vectors["mixed"])
    for name, data in vectors.items():
        check_zipfile(name, data)
    summary = ", ".join(name + " (" + str(len(data)) + " bytes)" for name, data in vectors.items())
    print("zip writer vectors OK: " + summary)


if __name__ == "__main__":
    sys.exit(main())
