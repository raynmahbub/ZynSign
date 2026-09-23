#!/usr/bin/env python3
"""Independent public-vector checks; not execution of Swift or Apple validation.

Uses Python's standard library and host OpenSSL only. Writes public CMS/content
into an automatically removed temporary directory. No private key is required.
This is a development check, never a product runtime subprocess.
"""
import base64
import hashlib
from pathlib import Path
import re
import struct
import subprocess
import tempfile


def main():
    fixture = (Path(__file__).resolve().parents[1] /
               "ZynSignTests/Support/MachOSigningFixtures.swift").read_text()
    values = {name: base64.b64decode(text) for name, text in re.findall(
        r'static let (\w+): Data = decode\("""(.*?)"""\)', fixture, re.S)}
    source, output = values["unsignedMachO"], values["expectedSignedMachO"]
    magic, cpu, subtype, filetype, count, commands, flags, reserved = struct.unpack_from("<8I", output)
    assert (magic, cpu, subtype, filetype, count, commands) == (0xfeedfacf, 0x100000c, 0, 2, 3, 240)
    cmd, size, offset, reserve = struct.unpack_from("<4I", output, 256)
    assert (cmd, size, offset, reserve) == (0x1d, 16, 4144, 1376)
    assert offset != len(source) and offset + reserve == len(output)
    assert output[len(source):offset] == bytes(offset-len(source))
    assert struct.unpack_from("<Q", output, 232)[0] == len(output)-4096
    allowed = set(range(16, 24)) | set(range(256, 272)) | set(range(232, 240))
    assert all(a == b for i, (a, b) in enumerate(zip(source, output)) if i not in allowed)
    magic, length, count = struct.unpack_from(">3I", output, offset)
    assert (magic, count) == (0xfade0cc0, 2)
    assert struct.unpack_from(">4I", output, offset+12) == (0, 28, 0x10000, 172)
    assert output[offset+length:] == bytes(reserve-length)
    cd = output[offset+28:offset+172]
    assert cd == values["codeDirectory"]
    fields = struct.unpack_from(">9I4B3I", cd)
    assert fields == (0xfade0c02, 144, 0x20200, 0, 80, 52, 0, 2, 4144,
                      32, 2, 0, 12, 0, 0, 71)
    assert cd[52:71] == b"com.example.single\0" and cd[71:80] == b"TESTTEAM\0"
    for page in range(2):
        assert hashlib.sha256(output[page*4096:min((page+1)*4096,offset)]).digest() == cd[80+page*32:112+page*32]
    assert hashlib.sha256(source[:4096]).digest() != cd[80:112], "Header mutation must precede hashing"
    wrapper_magic, wrapper_length = struct.unpack_from(">2I", output, offset+172)
    assert wrapper_magic == 0xfade0b01 and wrapper_length == length-172
    cms = output[offset+180:offset+length]
    assert cms == values["cms"]
    assert cms[-256:] == values["signature"]
    assert values["certificateDER"] in cms
    # Exact two-attribute SET encoding independently constructed from RFC 5652.
    cd_digest = hashlib.sha256(cd).digest()
    attributes = bytes.fromhex(
        "314b301806092a864886f70d010903310b06092a864886f70d010701"
        "302f06092a864886f70d01090431220420") + cd_digest
    assert hashlib.sha256(attributes).digest() == values["signingDigest"]
    assert b"\xa0"+attributes[1:] in cms
    with tempfile.TemporaryDirectory(prefix="zynsign-public-vector-") as temp:
        root = Path(temp)
        (root/"cms.der").write_bytes(cms)
        (root/"cd.bin").write_bytes(cd)
        command = ["openssl", "cms", "-verify", "-binary", "-inform", "DER",
                   "-in", str(root/"cms.der"), "-content", str(root/"cd.bin"),
                   "-noverify", "-out", str(root/"verified.bin")]
        checked = subprocess.run(command, capture_output=True)
        assert checked.returncode == 0, "Independent CMS signature verification failed"
        assert (root/"verified.bin").read_bytes() == cd
        tampered = bytearray(cd); tampered[-1] ^= 1
        (root/"cd.bin").write_bytes(tampered)
        assert subprocess.run(command, capture_output=True).returncode != 0
        (root/"cd.bin").write_bytes(cd)
        damaged = bytearray(cms); damaged[-1] ^= 1
        (root/"cms.der").write_bytes(damaged)
        assert subprocess.run(command, capture_output=True).returncode != 0
        damaged = bytearray(cms)
        attribute_offset = cms.index(b"\xa0"+attributes[1:])
        damaged[attribute_offset+len(attributes)-1] ^= 1
        (root/"cms.der").write_bytes(damaged)
        assert subprocess.run(command, capture_output=True).returncode != 0
    print("PASS: independent Mach-O layout, CodeDirectory fields/page hashes, CMS binding/signature")
    print("PASS: tampered CodeDirectory, signed attributes, and signature rejected by OpenSSL")
    print("Not Swift execution, certificate trust evaluation, or Apple platform acceptance")


if __name__ == "__main__":
    main()
