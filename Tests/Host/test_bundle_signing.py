"""Signing a whole package: overrides, removals, nested order, the seal."""

from __future__ import annotations

import plistlib
import tempfile
import unittest
from pathlib import Path

from zynsim import bundle, codesign, fixtures, profile

WORK = Path(tempfile.mkdtemp(prefix="zynsign-bundle-"))


class BundleSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.identity = fixtures.TestIdentity(WORK / "identity")
        cls.profile = profile.parse_profile(cls.identity.wrapped_profile("com.example.demo"))
        cls.wildcard = profile.parse_profile(cls.identity.wrapped_profile("com.example.*"))
        cls.ipa = fixtures.build_ipa()

    def signed(self, overrides=None, identity=None, profile_object=None):
        return bundle.sign_ipa(self.ipa, identity=identity or self.identity.identity,
                               profile_object=profile_object or self.profile, overrides=overrides)

    def test_every_nested_binary_is_signed_and_verifies(self) -> None:
        outcome = self.signed()
        self.assertTrue(outcome.verified, [r.problems for r in outcome.verification])
        self.assertEqual(len(outcome.binaries), 3)  # widget, framework, main
        self.assertTrue(all(report.cms_valid for report in outcome.verification))

    def test_nested_code_is_signed_before_its_container(self) -> None:
        outcome = self.signed()
        paths = [binary.path for binary in outcome.binaries]
        self.assertLess(paths.index("Payload/Demo.app/PlugIns/DemoWidget.appex/DemoWidget"),
                        paths.index("Payload/Demo.app/Demo"))

    def test_overrides_land_in_the_plist(self) -> None:
        outcome = self.signed(bundle.Overrides(
            bundle_id="com.example.renamed", display_name="Renamed", name="Renamed",
            short_version="2.5", version="42", minimum_os="15.0"), profile_object=self.wildcard)
        info = plistlib.loads(bundle.IPABundle.from_bytes(outcome.data)
                              .entries["Payload/Demo.app/Info.plist"])
        self.assertEqual(info["CFBundleIdentifier"], "com.example.renamed")
        self.assertEqual(info["CFBundleDisplayName"], "Renamed")
        self.assertEqual(info["CFBundleShortVersionString"], "2.5")
        self.assertEqual(info["CFBundleVersion"], "42")
        self.assertEqual(info["MinimumOSVersion"], "15.0")

    def test_a_renamed_app_carries_its_extensions_with_it(self) -> None:
        outcome = self.signed(bundle.Overrides(bundle_id="com.example.renamed"),
                              profile_object=self.wildcard)
        rebuilt = bundle.IPABundle.from_bytes(outcome.data)
        info = plistlib.loads(rebuilt.entries["Payload/Demo.app/PlugIns/DemoWidget.appex/Info.plist"])
        self.assertEqual(info["CFBundleIdentifier"], "com.example.renamed.widget")
        self.assertTrue(outcome.verified)

    def test_removing_extensions_leaves_an_app_that_still_verifies(self) -> None:
        outcome = self.signed(bundle.Overrides(remove_extensions=True))
        rebuilt = bundle.IPABundle.from_bytes(outcome.data)
        self.assertFalse(any("DemoWidget" in path for path in rebuilt.entries))
        self.assertNotIn("PlugIns", plistlib.loads(rebuilt.entries["Payload/Demo.app/Info.plist"]))
        self.assertTrue(outcome.verified)

    def test_url_schemes_follow_the_switch(self) -> None:
        outcome = self.signed(bundle.Overrides(remove_url_schemes=True))
        info = plistlib.loads(bundle.IPABundle.from_bytes(outcome.data).entries["Payload/Demo.app/Info.plist"])
        self.assertNotIn("CFBundleURLTypes", info)

    def test_a_resource_seal_is_written_for_each_bundle(self) -> None:
        outcome = self.signed()
        rebuilt = bundle.IPABundle.from_bytes(outcome.data)
        for directory in ("Payload/Demo.app", "Payload/Demo.app/PlugIns/DemoWidget.appex"):
            with self.subTest(directory=directory):
                seal = plistlib.loads(rebuilt.entries[f"{directory}/_CodeSignature/CodeResources"])
                self.assertEqual(sorted(seal), ["files", "files2", "rules", "rules2"])
        # Only the main bundle carries resources; an extension with none has an
        # empty seal, which is different from a missing one.

    def test_the_seal_covers_the_files_that_are_there(self) -> None:
        rebuilt = bundle.IPABundle.from_bytes(self.signed().data)
        seal = plistlib.loads(rebuilt.entries["Payload/Demo.app/_CodeSignature/CodeResources"])
        self.assertIn("Assets.car", seal["files"])
        self.assertEqual(len(seal["files"]["Assets.car"]["hash"]), 20)
        # Version 1 lists the bundle's Info.plist under its own key, even
        # though version 2's rules omit it from the per-file entries.
        self.assertIn("Info.plist", seal["files"])
        # A nested bundle is one cdhash entry, not a list of its files.
        self.assertIn("PlugIns/DemoWidget.appex", seal["files2"])
        self.assertNotIn("PlugIns/DemoWidget.appex/DemoWidget", seal["files2"])

    def test_entitlements_are_repointed_at_the_signed_identifier(self) -> None:
        outcome = self.signed(bundle.Overrides(bundle_id="com.example.renamed"),
                              profile_object=self.wildcard)
        entitlements = outcome.entitlements["Payload/Demo.app/Demo"]
        self.assertEqual(entitlements["application-identifier"], "ZYNTEAM1A2.com.example.renamed")

    def test_the_der_slot_appears_only_at_20400(self) -> None:
        modern = self.signed()
        legacy = bundle.sign_ipa(self.ipa, identity=self.identity.identity,
                                 profile_object=self.profile, version=0x20200)
        self.assertEqual(modern.verification[-1].special_slots, 7)
        self.assertEqual(legacy.verification[-1].special_slots, 5)
        self.assertTrue(legacy.verified)

    def test_injection_targets_the_main_executable(self) -> None:
        outcome = self.signed(bundle.Overrides(
            injected_libraries=[("@executable_path/Frameworks/ZynTweak.dylib", False)]))
        injected = {binary.path: binary.injected for binary in outcome.binaries}
        self.assertEqual(injected["Payload/Demo.app/Demo"],
                         ["@executable_path/Frameworks/ZynTweak.dylib"])
        self.assertEqual(injected["Payload/Demo.app/Frameworks/libdemo.dylib"], [])
        self.assertEqual(injected["Payload/Demo.app/PlugIns/DemoWidget.appex/DemoWidget"], [])

    def test_injecting_into_nested_code_is_opt_in(self) -> None:
        outcome = self.signed(bundle.Overrides(
            injected_libraries=[("@executable_path/Frameworks/ZynTweak.dylib", False)],
            inject_into_nested=True))
        injected = {binary.path: binary.injected for binary in outcome.binaries}
        self.assertTrue(all(injected.values()), injected)
        self.assertTrue(outcome.verified)

    def test_an_unsigned_package_is_signed_ad_hoc_without_a_certificate(self) -> None:
        outcome = bundle.sign_ipa(self.ipa)
        self.assertTrue(outcome.verified)
        self.assertTrue(all(report.adhoc for report in outcome.verification))
        self.assertFalse(any(report.cms_present for report in outcome.verification))

    def test_a_second_signing_pass_is_refused(self) -> None:
        outcome = self.signed()
        with self.assertRaises(bundle.BundleError):
            bundle.sign_ipa(outcome.data, identity=self.identity.identity, profile_object=self.profile)

    def test_a_package_without_an_app_bundle_is_refused(self) -> None:
        with self.assertRaises(bundle.BundleError):
            bundle.IPABundle.from_bytes(fixtures.write_ipa({"Payload/notes.txt": b"hi"}))


class ProfileAuthorisationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.identity = fixtures.TestIdentity(WORK / "authorisation")
        cls.profile = profile.parse_profile(cls.identity.wrapped_profile("com.example.demo"))

    def test_a_profile_for_another_bundle_is_refused(self) -> None:
        with self.assertRaises(bundle.BundleError) as raised:
            bundle.sign_ipa(fixtures.build_ipa(bundle_id="com.other.app"),
                            identity=self.identity.identity, profile_object=self.profile)
        self.assertIn("not com.other.app", str(raised.exception))

    def test_an_expired_profile_is_refused(self) -> None:
        from dataclasses import replace
        from datetime import datetime, timedelta, timezone
        expired = replace(self.profile, expiration=datetime.now(timezone.utc) - timedelta(days=1))
        with self.assertRaises(bundle.BundleError) as raised:
            bundle.sign_ipa(fixtures.build_ipa(), identity=self.identity.identity,
                            profile_object=expired)
        self.assertIn("expired", str(raised.exception))


class ProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.identity = fixtures.TestIdentity(WORK / "profile")
        cls.profile = profile.parse_profile(cls.identity.wrapped_profile("com.example.demo"))

    def test_the_profile_names_the_team_and_the_application(self) -> None:
        self.assertEqual(self.profile.team_id, "ZYNTEAM1A2")
        self.assertEqual(self.profile.app_id, "ZYNTEAM1A2.com.example.demo")
        self.assertFalse(self.profile.is_wildcard)
        self.assertFalse(self.profile.is_expired)

    def test_matching_is_exact_for_a_concrete_profile(self) -> None:
        self.assertTrue(self.profile.matches("com.example.demo"))
        self.assertFalse(self.profile.matches("com.example.demo.widget"))
        self.assertFalse(self.profile.matches("com.example.other"))

    def test_a_wildcard_profile_matches_a_prefix(self) -> None:
        wildcard = profile.ProvisioningProfile(
            name="wild", app_id="ZYNTEAM1A2.*", team_id="ZYNTEAM1A2",
            entitlements={"application-identifier": "ZYNTEAM1A2.*"},
            expiration=None, provisioned_devices=[], platforms=["iOS"], uuid="", is_wildcard=True)
        self.assertTrue(wildcard.matches("com.anything.at.all"))
        self.assertEqual(wildcard.entitlements_for("com.example.demo")["application-identifier"],
                         "ZYNTEAM1A2.com.example.demo")

    def test_a_nested_entitlement_drops_the_push_environment(self) -> None:
        nested = self.profile.entitlements_for("com.example.demo.widget", nested=True)
        self.assertNotIn("aps-environment", nested)
        self.assertEqual(nested["application-identifier"], "ZYNTEAM1A2.com.example.demo.widget")

    def test_der_entitlements_are_deterministic_and_canonical(self) -> None:
        first = profile.der_entitlements({"b": True, "a": "x"})
        second = profile.der_entitlements({"a": "x", "b": True})
        self.assertEqual(first, second)
        self.assertEqual(first[0], 0x31)  # a SET

    def test_a_pkcs12_archive_round_trips(self) -> None:
        imported = profile.identity_from_p12(self.identity.p12_path)
        self.assertEqual(imported.certificate_der, self.identity.certificate_der)

    def test_a_wrong_passphrase_is_refused(self) -> None:
        with self.assertRaises(profile.ProfileError):
            profile.identity_from_p12(self.identity.p12_path, "not-the-passphrase")


if __name__ == "__main__":
    unittest.main()
