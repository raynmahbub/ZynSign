"""What a device checks about a package, beyond the page hashes.

Four things live here, each of them a real refusal on a phone and each of them
invisible to a signature that only hashes pages:

1. special slot 1 — the bundle's `Info.plist` digest;
2. the `CodeResources` seal, with Apple's v2 rules (nested code by `cdhash`);
3. the certificate chain inside the CMS blob;
4. re-signing — stripping a signature so an already-signed IPA can be redone.
"""

from __future__ import annotations

import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

from zynsim import (bundle, codesign, cms, fixtures, macho, profile,
                    resourceseal)

WORK = Path(tempfile.mkdtemp(prefix="zynsign-integrity-"))


def make_chain(directory: Path) -> tuple[Path, bytes, bytes]:
    """A root, an intermediate, a leaf, and a p12 carrying the intermediate."""
    directory.mkdir(parents=True, exist_ok=True)
    def openssl(*args, stdin: bytes | None = None) -> bytes:
        result = subprocess.run(["openssl", *args], input=stdin, capture_output=True, check=False)
        if result.returncode != 0:
            raise AssertionError(result.stderr.decode())
        return result.stdout

    root_key, root_crt = directory / "root.key", directory / "root.crt"
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(root_key),
            "-out", str(root_crt), "-days", "30", "-subj", "/CN=Test Root",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign")
    intermediate_key, intermediate_csr = directory / "i.key", directory / "i.csr"
    intermediate_crt = directory / "i.crt"
    openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", str(intermediate_key),
            "-out", str(intermediate_csr), "-subj", "/CN=Test Intermediate")
    openssl("x509", "-req", "-in", str(intermediate_csr), "-CA", str(root_crt),
            "-CAkey", str(root_key), "-CAcreateserial", "-days", "30",
            "-out", str(intermediate_crt), "-extfile", "/dev/stdin",
            stdin=b"basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n")
    leaf_key, leaf_csr, leaf_crt = directory / "leaf.key", directory / "leaf.csr", directory / "leaf.crt"
    openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", str(leaf_key),
            "-out", str(leaf_csr), "-subj", "/CN=Test Leaf")
    openssl("x509", "-req", "-in", str(leaf_csr), "-CA", str(intermediate_crt),
            "-CAkey", str(intermediate_key), "-CAcreateserial", "-days", "30",
            "-out", str(leaf_crt), "-extfile", "/dev/stdin",
            stdin=b"keyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n")
    p12 = directory / "chain.p12"
    openssl("pkcs12", "-export", "-inkey", str(leaf_key), "-in", str(leaf_crt),
            "-certfile", str(intermediate_crt), "-out", str(p12), "-passout", "pass:")
    root_der = openssl("x509", "-in", str(root_crt), "-outform", "DER")
    leaf_der = openssl("x509", "-in", str(leaf_crt), "-outform", "DER")
    return p12, root_der, leaf_der


class InfoPlistSlotTests(unittest.TestCase):
    """Slot 1: the bundle's Info.plist digest, which a device refuses to lose."""

    def signed(self, info_plist: bytes | None):
        return codesign.sign_image(
            fixtures.build_macho(),
            codesign.SigningOptions(identifier="com.example.demo", adhoc=True,
                                    info_plist=info_plist))

    def test_the_slot_is_absent_when_no_info_plist_is_supplied(self) -> None:
        signed, _ = self.signed(None)
        report = codesign.verify_image(signed)
        self.assertFalse(report.has_info_plist_slot)
        self.assertTrue(report.valid)

    def test_the_slot_carries_the_digest_of_the_file_it_was_given(self) -> None:
        info = plistlib.dumps({"CFBundleIdentifier": "com.example.demo"})
        signed, _ = self.signed(info)
        report = codesign.verify_image(signed, info_plist=info)
        self.assertTrue(report.has_info_plist_slot)
        self.assertTrue(report.info_plist_valid)
        self.assertTrue(report.valid, report.problems)

    def test_a_different_info_plist_invalidates_the_signature(self) -> None:
        info = plistlib.dumps({"CFBundleIdentifier": "com.example.demo"})
        signed, _ = self.signed(info)
        report = codesign.verify_image(signed, info_plist=b"<plist>other</plist>")
        self.assertFalse(report.info_plist_valid)
        self.assertFalse(report.valid)
        self.assertIn("special slot 1", " ".join(report.problems))

    def test_without_the_file_the_slot_is_present_but_unproven(self) -> None:
        info = plistlib.dumps({"CFBundleIdentifier": "com.example.demo"})
        signed, _ = self.signed(info)
        report = codesign.verify_image(signed)
        self.assertTrue(report.has_info_plist_slot)
        self.assertIsNone(report.info_plist_valid)
        self.assertTrue(report.valid)

    def test_adding_the_slot_grows_the_directory_by_one_hash(self) -> None:
        # With a requirements blob, slot 2 already forces two reserved slots,
        # so filling slot 1 costs nothing. Without one it adds one hash.
        def sign(info, requirements):
            return codesign.sign_image(
                fixtures.build_macho(),
                codesign.SigningOptions(identifier="com.example.demo", adhoc=True,
                                        info_plist=info, embed_requirements=requirements))[0]
        self.assertEqual(len(sign(None, True)), len(sign(b"<plist/>", True)))
        self.assertEqual(len(sign(b"<plist/>", False)) - len(sign(None, False)), 32)


class ResourceSealTests(unittest.TestCase):
    """The seal Apple's `--deep --strict` applies, written the way it expects."""

    def entries(self) -> dict[str, bytes]:
        return {
            "Payload/Demo.app/Info.plist": b"<plist/>",
            "Payload/Demo.app/Assets.car": b"assets",
            "Payload/Demo.app/en.lproj/Localizable.strings": b'"a" = "b";',
            "Payload/Demo.app/Frameworks/libdemo.dylib": b"BINARY",
            "Payload/Demo.app/PlugIns/W.appex/W": b"BINARY",
            "Payload/Demo.app/PlugIns/W.appex/Info.plist": b"<plist/>",
            "Payload/Demo.app/_CodeSignature/CodeResources": b"seal",
        }

    def seal(self):
        hashes = {
            "Frameworks/libdemo.dylib": resourceseal.cdhash(b"CD-FRAMEWORK"),
            "PlugIns/W.appex": resourceseal.cdhash(b"CD-APPEX"),
        }
        return resourceseal.build(self.entries(), bundle_prefix="Payload/Demo.app",
                                  executable="Payload/Demo.app/Demo", cdhashes=hashes), hashes

    def test_nested_bundles_are_one_cdhash_each(self) -> None:
        seal, _ = self.seal()
        self.assertEqual(seal["files2"]["PlugIns/W.appex"], {"cdhash": seal["files2"]["PlugIns/W.appex"]["cdhash"]})
        self.assertNotIn("PlugIns/W.appex/W", seal["files2"])
        self.assertNotIn("PlugIns/W.appex/Info.plist", seal["files2"])

    def test_plain_resources_are_sha256(self) -> None:
        seal, _ = self.seal()
        self.assertIn("hash2", seal["files2"]["Assets.car"])
        self.assertEqual(len(seal["files2"]["Assets.car"]["hash2"]), 32)

    def test_localised_resources_are_sealed_despite_the_lproj_rule(self) -> None:
        seal, _ = self.seal()
        self.assertIn("en.lproj/Localizable.strings", seal["files2"])

    def test_the_seal_itself_and_info_plist_are_not_per_file_entries(self) -> None:
        seal, _ = self.seal()
        self.assertNotIn("_CodeSignature/CodeResources", seal["files2"])

    def test_both_rule_sets_are_written(self) -> None:
        seal, _ = self.seal()
        self.assertEqual(sorted(seal), ["files", "files2", "rules", "rules2"])
        self.assertIn("^(Frameworks|SharedFrameworks|PlugIns|Plug-ins|XPCServices|Helpers|MacOS|Library/(Automator|Spotlight|LoginItems))/",
                      seal["rules2"])

    def test_verification_accepts_an_untouched_bundle(self) -> None:
        seal, hashes = self.seal()
        self.assertEqual(resourceseal.verify(resourceseal.serialize(seal), self.entries(),
                                             bundle_prefix="Payload/Demo.app",
                                             executable="Payload/Demo.app/Demo",
                                             cdhashes=hashes), [])

    def test_verification_reports_a_changed_resource(self) -> None:
        seal, hashes = self.seal()
        changed = self.entries()
        changed["Payload/Demo.app/Assets.car"] = b"different"
        findings = resourceseal.verify(resourceseal.serialize(seal), changed,
                                       bundle_prefix="Payload/Demo.app",
                                       executable="Payload/Demo.app/Demo", cdhashes=hashes)
        self.assertEqual(len(findings), 1)
        self.assertIn("Assets.car", findings[0])

    def test_verification_reports_a_missing_entry(self) -> None:
        seal, hashes = self.seal()
        changed = self.entries()
        changed["Payload/Demo.app/Extra.txt"] = b"unsealed"
        findings = resourceseal.verify(resourceseal.serialize(seal), changed,
                                       bundle_prefix="Payload/Demo.app",
                                       executable="Payload/Demo.app/Demo", cdhashes=hashes)
        self.assertTrue(any("Extra.txt" in finding for finding in findings))

    def test_a_nested_bundle_root_is_found_by_suffix(self) -> None:
        roots = resourceseal.nested_bundle_roots(
            ["Payload/Demo.app/PlugIns/W.appex/W",
             "Payload/Demo.app/Frameworks/libdemo.dylib",
             "Payload/Demo.app/Assets.car"],
            prefix="Payload/Demo.app/")
        self.assertEqual(roots, ["PlugIns/W.appex"])


class SigningPipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.identity = fixtures.TestIdentity(WORK / "identity")
        cls.profile = profile.parse_profile(cls.identity.wrapped_profile("com.example.demo"))
        cls.ipa = fixtures.build_ipa()

    def sign(self, **kwargs):
        return bundle.sign_ipa(self.ipa, identity=self.identity.identity,
                               profile_object=self.profile, **kwargs)

    def test_every_app_executable_carries_its_own_info_plist_slot(self) -> None:
        outcome = self.sign()
        rebuilt = bundle.IPABundle.from_bytes(outcome.data)
        for directory, _ in rebuilt.app_containers():
            executable = rebuilt.executable_path(directory)
            info = rebuilt.entries[f"{directory}/Info.plist"]
            report = codesign.verify_image(rebuilt.entries[executable], info_plist=info)
            with self.subTest(directory=directory):
                self.assertTrue(report.info_plist_valid, report.problems)

    def test_an_extension_is_sealed_by_the_main_apps_cdhash(self) -> None:
        rebuilt = bundle.IPABundle.from_bytes(self.sign().data)
        seal = plistlib.loads(rebuilt.entries["Payload/Demo.app/_CodeSignature/CodeResources"])
        self.assertIn("PlugIns/DemoWidget.appex", seal["files2"])
        self.assertIn("cdhash", seal["files2"]["PlugIns/DemoWidget.appex"])

    def test_the_seal_covers_the_shipped_files(self) -> None:
        outcome = self.sign()
        self.assertEqual(outcome.seal_problems, [])
        self.assertTrue(outcome.verified)

    def test_a_tampered_resource_breaks_the_seal(self) -> None:
        rebuilt = bundle.IPABundle.from_bytes(self.sign().data)
        rebuilt.entries["Payload/Demo.app/Assets.car"] = b"tampered"
        self.assertTrue(any("Assets.car" in problem for problem in rebuilt.verify_seals()))


class NestedSealTests(unittest.TestCase):
    """A nested bundle is sealed by its container *and* seals itself.

    Two independent bindings, and a package that has only one of them is
    accepted by a naive checker and refused by a strict verifier: the
    container names the bundle by `cdhash`, and the bundle's own executable
    binds its own `CodeResources` through special slot 3.
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.identity = fixtures.TestIdentity(WORK / "nested")
        cls.profile = profile.parse_profile(cls.identity.wrapped_profile("com.example.demo"))
        cls.outcome = bundle.sign_ipa(fixtures.build_ipa(),
                                      identity=cls.identity.identity,
                                      profile_object=cls.profile)
        cls.rebuilt = bundle.IPABundle.from_bytes(cls.outcome.data)

    def nested_containers(self) -> list[str]:
        return [directory for directory, _ in self.rebuilt.app_containers()
                if directory != self.rebuilt.main_app()]

    def test_every_nested_bundle_carries_its_own_seal(self) -> None:
        containers = self.nested_containers()
        self.assertTrue(containers)
        for directory in containers:
            with self.subTest(directory=directory):
                self.assertIn(f"{directory}/_CodeSignature/CodeResources",
                              self.rebuilt.entries)

    def test_each_nested_executable_binds_its_own_seal_in_slot_three(self) -> None:
        for directory in self.nested_containers():
            seal = self.rebuilt.entries[f"{directory}/_CodeSignature/CodeResources"]
            report = codesign.verify_image(
                self.rebuilt.entries[self.rebuilt.executable_path(directory)],
                info_plist=self.rebuilt.entries[f"{directory}/Info.plist"],
                resource_seal=seal)
            with self.subTest(directory=directory):
                self.assertTrue(report.has_resource_seal_slot, report.problems)
                self.assertTrue(report.resource_seal_valid, report.problems)
                self.assertTrue(report.valid, report.problems)

    def test_a_nested_bundle_does_not_bind_the_main_apps_seal(self) -> None:
        main_seal = self.rebuilt.entries[
            f"{self.rebuilt.main_app()}/_CodeSignature/CodeResources"]
        directory = self.nested_containers()[0]
        report = codesign.verify_image(
            self.rebuilt.entries[self.rebuilt.executable_path(directory)],
            resource_seal=main_seal)
        self.assertFalse(report.resource_seal_valid)

    def test_a_nested_seal_lists_only_its_own_contents(self) -> None:
        directory = self.nested_containers()[0]
        seal = plistlib.loads(self.rebuilt.entries[
            f"{directory}/_CodeSignature/CodeResources"])
        for key in seal["files2"]:
            with self.subTest(key=key):
                self.assertFalse(key.startswith("Payload/"),
                                 "a nested seal must use its own relative paths")
        self.assertNotIn(self.rebuilt.executable_path(directory).split("/")[-1],
                         seal["files2"])

    def test_the_container_seal_names_the_bundle_by_cdhash(self) -> None:
        main_seal = plistlib.loads(self.rebuilt.entries[
            f"{self.rebuilt.main_app()}/_CodeSignature/CodeResources"])
        for directory in self.nested_containers():
            relative = directory.split(f"{self.rebuilt.main_app()}/", 1)[1]
            with self.subTest(container=relative):
                self.assertIn(relative, main_seal["files2"])
                self.assertIn("cdhash", main_seal["files2"][relative])

    def test_the_nested_binding_survives_a_resign(self) -> None:
        again = bundle.sign_ipa(self.outcome.data, identity=self.identity.identity,
                                profile_object=self.profile, resign=True)
        self.assertTrue(again.verified, again.seal_problems)
        rebuilt = bundle.IPABundle.from_bytes(again.data)
        directory = self.nested_containers()[0]
        seal = rebuilt.entries[f"{directory}/_CodeSignature/CodeResources"]
        report = codesign.verify_image(
            rebuilt.entries[rebuilt.executable_path(directory)], resource_seal=seal)
        self.assertTrue(report.resource_seal_valid, report.problems)

    def test_a_tampered_nested_seal_is_caught(self) -> None:
        directory = self.nested_containers()[0]
        seal = bytearray(self.rebuilt.entries[f"{directory}/_CodeSignature/CodeResources"])
        seal[10] ^= 0xFF
        report = codesign.verify_image(
            self.rebuilt.entries[self.rebuilt.executable_path(directory)],
            resource_seal=bytes(seal))
        self.assertFalse(report.resource_seal_valid)
        self.assertFalse(report.valid)


class ReSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.identity = fixtures.TestIdentity(WORK / "resign")
        cls.profile = profile.parse_profile(cls.identity.wrapped_profile("com.example.demo"))
        cls.base = fixtures.build_ipa()
        cls.signed = bundle.sign_ipa(cls.base, identity=cls.identity.identity,
                                     profile_object=cls.profile)

    def test_stripping_a_signature_restores_the_unsigned_bytes(self) -> None:
        image = fixtures.build_macho()
        signed, _ = codesign.sign_image(
            image, codesign.SigningOptions(identifier="com.example.demo", adhoc=True))
        self.assertEqual(macho.strip_signature(signed), image)

    def test_an_already_signed_package_is_refused_without_resign(self) -> None:
        with self.assertRaises(bundle.BundleError) as raised:
            bundle.sign_ipa(self.signed.data, identity=self.identity.identity,
                            profile_object=self.profile)
        self.assertIn("resign", str(raised.exception))

    def test_resigning_produces_a_valid_package(self) -> None:
        again = bundle.sign_ipa(self.signed.data, identity=self.identity.identity,
                                profile_object=self.profile, resign=True)
        self.assertTrue(again.verified, again.seal_problems)
        self.assertEqual(len(again.binaries), 3)

    def test_resigning_with_a_new_identity_replaces_the_signer(self) -> None:
        other = fixtures.TestIdentity(WORK / "second")
        other_profile = profile.parse_profile(other.wrapped_profile("com.example.demo"))
        again = bundle.sign_ipa(self.signed.data, identity=other.identity,
                                profile_object=other_profile, resign=True)
        self.assertTrue(again.verified)
        rebuilt = bundle.IPABundle.from_bytes(again.data)
        report = codesign.verify_image(rebuilt.entries[rebuilt.main_executable()])
        self.assertTrue(report.cms_valid)

    def test_resigning_drops_the_old_seal_and_provisioning_profile(self) -> None:
        again = bundle.sign_ipa(self.signed.data, identity=self.identity.identity,
                                profile_object=self.profile, resign=True)
        rebuilt = bundle.IPABundle.from_bytes(again.data)
        seals = [path for path in rebuilt.entries if path.endswith("_CodeSignature/CodeResources")]
        self.assertEqual(len(seals), len(rebuilt.app_containers()))


class CertificateChainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.directory = WORK / "chain"
        cls.p12, cls.root_der, cls.leaf_der = make_chain(cls.directory)
        cls.imported = profile.identity_from_p12(cls.p12)

    def test_the_import_keeps_the_intermediate(self) -> None:
        self.assertEqual(len(self.imported.intermediates), 1)
        self.assertNotEqual(self.imported.intermediates[0], self.leaf_der)

    def test_a_three_level_chain_verifies_against_the_root(self) -> None:
        signed, _ = codesign.sign_image(
            fixtures.build_macho(),
            codesign.SigningOptions(identifier="com.example.chain", identity=self.imported.signer()))
        offset, size = macho.MachO(signed).code_signature_command()
        blobs = codesign.read_superblob(signed[offset:offset + size])
        self.assertTrue(cms.verify(blobs[codesign.CSSLOT_SIGNATURE][8:], blobs[0],
                                   trust_anchor=self.root_der))

    def test_dropping_the_intermediate_breaks_the_chain(self) -> None:
        signed, _ = codesign.sign_image(
            fixtures.build_macho(),
            codesign.SigningOptions(identifier="com.example.chain", identity=self.imported.signer()))
        offset, size = macho.MachO(signed).code_signature_command()
        blobs = codesign.read_superblob(signed[offset:offset + size])
        leaf_only = cms.CertificateIdentity(self.imported.certificate_der, self.imported.key_path)
        self.assertFalse(cms.verify(cms.build(blobs[0], leaf_only), blobs[0],
                                    trust_anchor=self.root_der))

    def test_the_wrong_anchor_refuses(self) -> None:
        signed, _ = codesign.sign_image(
            fixtures.build_macho(),
            codesign.SigningOptions(identifier="com.example.chain", identity=self.imported.signer()))
        offset, size = macho.MachO(signed).code_signature_command()
        blobs = codesign.read_superblob(signed[offset:offset + size])
        stranger = fixtures.TestIdentity(WORK / "stranger").certificate_der
        self.assertFalse(cms.verify(blobs[codesign.CSSLOT_SIGNATURE][8:], blobs[0],
                                    trust_anchor=stranger))


if __name__ == "__main__":
    unittest.main()
