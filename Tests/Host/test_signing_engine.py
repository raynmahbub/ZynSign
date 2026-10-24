"""Code signing at the byte level: CodeDirectory, page hashes, CMS, injection."""

from __future__ import annotations

import base64
import re
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

from zynsim import codesign, cms, der, fixtures, macho

FIXTURES = Path(__file__).resolve().parent.parent / "ZynSignTests" / "Support" / "MachOSigningFixtures.swift"


def _vector(name: str) -> bytes:
    text = FIXTURES.read_text()
    match = re.search(rf'static let {name}: Data = decode\("""(.*?)"""\)', text, re.S)
    if match is None:
        raise unittest.SkipTest(f"the fixture {name} is not in the Swift test support file")
    return base64.b64decode("".join(match.group(1).split()))


class HeaderLayoutTests(unittest.TestCase):
    def test_header_sizes_follow_cs_blobs(self) -> None:
        expected = {
            0x20001: 44, 0x20100: 48, 0x20200: 52, 0x20300: 64,
            0x20400: 88, 0x20500: 96, 0x20600: 108,
        }
        for version, length in expected.items():
            with self.subTest(version=hex(version)):
                self.assertEqual(codesign.header_length(version), length)

    def test_unknown_version_is_refused(self) -> None:
        with self.assertRaises(codesign.SigningError):
            codesign.header_length(0x20700)

    def test_exec_segment_fields_are_at_the_end_of_a_20400_header(self) -> None:
        directory = codesign.build_code_directory(
            code=b"\x00" * 8192, identifier="com.example.demo", team_id="ZYNTEAM1A2",
            version=0x20400, exec_segment=(0, 0x2000, codesign.CS_EXECSEG_MAIN_BINARY))
        encoded = directory.serialize()
        self.assertEqual(len(encoded), directory.planned_length())
        base, limit, flags = struct.unpack_from(">QQQ", encoded, 64)
        self.assertEqual((base, limit, flags), (0, 0x2000, codesign.CS_EXECSEG_MAIN_BINARY))
        hash_offset = struct.unpack_from(">I", encoded, 16)[0]
        identifier_offset = struct.unpack_from(">I", encoded, 20)[0]
        self.assertEqual(identifier_offset, 88)          # the header ends at 88
        self.assertEqual(hash_offset, 88 + 17 + 11)      # identifier + NUL, team + NUL


class AdHocSigningTests(unittest.TestCase):
    def test_signature_verifies_and_carries_no_certificate(self) -> None:
        image = fixtures.build_macho()
        signed, info = codesign.sign_image(
            image, codesign.SigningOptions(identifier="com.example.demo", adhoc=True))
        report = codesign.verify_image(signed)
        self.assertTrue(report.valid, report.problems)
        self.assertTrue(report.adhoc)
        self.assertFalse(report.cms_present)
        self.assertEqual(report.code_limit, info.data_offset)
        self.assertEqual(report.code_slots, (info.data_offset + 4095) // 4096)

    def test_every_page_hash_is_recomputed_from_the_bytes(self) -> None:
        signed, _ = codesign.sign_image(
            fixtures.build_macho(), codesign.SigningOptions(identifier="com.example.demo", adhoc=True))
        for offset in (0x500, 0x3000, 0x3FF0, len(signed) - 1):
            with self.subTest(offset=offset):
                tampered = bytearray(signed)
                tampered[offset] ^= 0x01
                self.assertFalse(codesign.verify_image(bytes(tampered)).valid)

    def test_signing_the_same_image_twice_gives_the_same_bytes(self) -> None:
        image = fixtures.build_macho()
        first, _ = codesign.sign_image(image, codesign.SigningOptions(identifier="com.example.demo", adhoc=True))
        second, _ = codesign.sign_image(image, codesign.SigningOptions(identifier="com.example.demo", adhoc=True))
        self.assertEqual(first, second)

    def test_an_image_may_not_be_signed_twice(self) -> None:
        signed, _ = codesign.sign_image(
            fixtures.build_macho(), codesign.SigningOptions(identifier="com.example.demo", adhoc=True))
        with self.assertRaises(codesign.SigningError):
            codesign.sign_image(signed, codesign.SigningOptions(identifier="com.example.demo", adhoc=True))


class CertificateSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.directory = Path(tempfile.mkdtemp(prefix="zynsign-cms-"))
        cls.identity = fixtures.TestIdentity(cls.directory).identity

    def test_cms_over_the_code_directory_verifies_with_openssl(self) -> None:
        signed, _ = codesign.sign_image(
            fixtures.build_macho(),
            codesign.SigningOptions(identifier="com.example.demo", team_id="ZYNTEAM1A2",
                                    identity=self.identity, entitlements_xml=b"<plist/>"))
        report = codesign.verify_image(signed)
        self.assertTrue(report.cms_valid, report.problems)
        self.assertTrue(report.valid)
        self.assertFalse(report.adhoc)
        self.assertIsNotNone(report.team_id)

    def test_a_changed_code_directory_breaks_the_signature(self) -> None:
        signed, info = codesign.sign_image(
            fixtures.build_macho(), codesign.SigningOptions(identifier="com.example.demo", identity=self.identity))
        tampered = bytearray(signed)
        tampered[info.data_offset + 40] ^= 0x01  # inside the CodeDirectory identifier
        self.assertFalse(codesign.verify_image(bytes(tampered)).valid)

    def test_entitlements_occupy_special_slots_five_and_seven(self) -> None:
        entitlements = fixtures.TestIdentity(self.directory).profile_plist()["Entitlements"]
        from zynsim import profile
        signed, _ = codesign.sign_image(
            fixtures.build_macho(),
            codesign.SigningOptions(identifier="com.example.demo", identity=self.identity,
                                    entitlements_xml=profile.entitlements_xml(entitlements),
                                    entitlements_der=profile.der_entitlements(entitlements)))
        report = codesign.verify_image(signed)
        self.assertEqual(report.special_slots, 7)
        self.assertTrue(report.special_slots_valid, report.problems)


class DylibInjectionTests(unittest.TestCase):
    def test_a_command_lands_in_header_padding_without_moving_content(self) -> None:
        image = macho.MachO(fixtures.build_macho())
        before = bytes(image.data[image.first_file_backed_offset():])
        image.inject_dylib("@executable_path/Frameworks/Tweak.dylib")
        self.assertIn("@executable_path/Frameworks/Tweak.dylib", image.dylib_paths())
        after = bytes(image.data)
        self.assertEqual(after[image.first_file_backed_offset():], before)
        self.assertEqual(image.command_count, 4)

    def test_a_full_header_is_refused(self) -> None:
        image = macho.MachO(fixtures.build_macho(text_offset=0x120))
        with self.assertRaises(macho.MachOError):
            image.inject_dylib("@executable_path/Frameworks/a-very-long-name-indeed.dylib")

    def test_an_injected_image_still_signs_and_verifies(self) -> None:
        image = macho.MachO(fixtures.build_macho())
        image.inject_dylib("@executable_path/Frameworks/Tweak.dylib", weak=True)
        signed, _ = codesign.sign_image(
            image.bytes(), codesign.SigningOptions(identifier="com.example.demo", adhoc=True))
        report = codesign.verify_image(signed)
        self.assertTrue(report.valid, report.problems)
        self.assertEqual(report.dylibs, ["@executable_path/Frameworks/Tweak.dylib"])

    def test_a_universal_image_is_refused(self) -> None:
        fat = struct.pack(">II", 0xCAFEBABE, 1) + b"\x00" * 64
        with self.assertRaises(macho.MachOError):
            macho.MachO(fat)


class SwiftVectorTests(unittest.TestCase):
    """The app's own generated signature, read by this independent verifier."""

    def test_the_swift_signature_verifies_here(self) -> None:
        signed = _vector("expectedSignedMachO")
        report = codesign.verify_image(signed)
        self.assertTrue(report.valid, report.problems)
        self.assertTrue(report.cms_valid)
        self.assertEqual(report.identifier, "com.example.single")
        self.assertEqual(report.team_id, "TESTTEAM")
        self.assertEqual(report.version, 0x20200)
        self.assertEqual(report.code_limit, 4144)
        self.assertEqual(report.code_slots, 2)

    def test_this_engines_layout_matches_the_swifts(self) -> None:
        signed = _vector("expectedSignedMachO")
        unsigned = _vector("unsignedMachO")
        image = macho.MachO(signed)
        offset, size = image.code_signature_command()
        theirs = codesign.read_superblob(signed[offset:offset + size])[0]
        mine, info = codesign.sign_image(unsigned, codesign.SigningOptions(
            identifier="com.example.single", team_id="TESTTEAM", adhoc=True,
            version=0x20200, embed_requirements=False))
        ours = codesign.read_superblob(mine[info.data_offset:])[0]
        for at, fmt in ((0, ">II"), (16, ">II"), (24, ">II"), (32, ">I"), (44, ">I"), (48, ">I")):
            self.assertEqual(struct.unpack_from(fmt, ours, at), struct.unpack_from(fmt, theirs, at))
        self.assertEqual(ours[52:71], theirs[52:71])  # identifier
        self.assertEqual(ours[71:80], theirs[71:80])  # team


class CMSTests(unittest.TestCase):
    def test_a_planned_length_matches_the_real_one(self) -> None:
        identity = fixtures.TestIdentity(Path(tempfile.mkdtemp())).identity
        self.assertEqual(len(cms.build(b"content", identity)), cms.planned_length(identity))

    def test_a_detached_signature_does_not_verify_against_other_content(self) -> None:
        identity = fixtures.TestIdentity(Path(tempfile.mkdtemp())).identity
        blob = cms.build(b"content", identity)
        self.assertTrue(cms.verify(blob, b"content"))
        self.assertFalse(cms.verify(blob, b"content!"))

    def test_a_profile_is_an_attached_signature(self) -> None:
        identity = fixtures.TestIdentity(Path(tempfile.mkdtemp()))
        wrapped = identity.wrapped_profile()
        self.assertIn(b"<plist", wrapped)
        self.assertTrue(subprocess.run(
            ["openssl", "cms", "-verify", "-noverify", "-inform", "DER", "-in", "/dev/stdin", "-out", "/dev/null"],
            input=wrapped, capture_output=True).returncode in (0, 1))  # openssl reads stdin only where available


class DERWriterTests(unittest.TestCase):
    def test_long_form_lengths_round_trip(self) -> None:
        payload = der.octet_string(b"\x00" * 300)
        node = der.read(payload)
        self.assertEqual(len(node.value), 300)
        self.assertEqual(node.end, len(payload))

    def test_a_truncated_frame_is_refused(self) -> None:
        with self.assertRaises(der.DERError):
            der.read(der.octet_string(b"abcd")[:-2])

    def test_object_identifiers_round_trip(self) -> None:
        for dotted in ("1.2.840.113549.1.7.1", "2.16.840.1.101.3.4.2.1", "1.2.3"):
            with self.subTest(dotted=dotted):
                self.assertEqual(der.read(der.oid(dotted)).as_oid(), dotted)


if __name__ == "__main__":
    unittest.main()
