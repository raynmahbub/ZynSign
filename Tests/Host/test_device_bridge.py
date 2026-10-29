"""The device bridge against a simulated device: pairing, TLS, AFC, install."""

from __future__ import annotations

import plistlib
import tempfile
import unittest
from pathlib import Path

from zynsim import (bundle, codesign, device, fixtures, macho, pairing, profile,
                    simulator)

WORK = Path(tempfile.mkdtemp(prefix="zynsign-device-"))
_CACHE: dict[str, object] = {}


def _shared():
    """Generate the keys once. Every class uses the same identity and device."""
    if not _CACHE:
        identity = fixtures.TestIdentity(WORK / "identity")
        device_identity = pairing.create_device_identity(WORK / "device")
        profile_object = profile.parse_profile(identity.wrapped_profile("com.example.demo"))
        ipa = fixtures.build_ipa()
        _CACHE.update(
            identity=identity,
            profile=profile_object,
            device_identity=device_identity,
            record=pairing.create_pairing_record(device_identity),
            ipa=ipa,
            signed=bundle.sign_ipa(ipa, identity=identity.identity, profile_object=profile_object),
            adhoc=bundle.sign_ipa(ipa),
        )
    return _CACHE


class DeviceTestCase(unittest.TestCase):
    accept_adhoc = False

    @classmethod
    def setUpClass(cls) -> None:
        shared = _shared()
        cls.identity = shared["identity"]
        cls.profile = shared["profile"]
        cls.device_identity = shared["device_identity"]
        cls.record = shared["record"]
        cls.ipa = shared["ipa"]
        cls.signed = shared["signed"]
        cls.adhoc = shared["adhoc"]

    def setUp(self) -> None:
        self.device = self.make_device()
        self.bridge = device.DeviceBridge(self.device.port)
        self.addCleanup(self.bridge.close)
        self.addCleanup(self.device.stop)

    def make_device(self) -> simulator.SimulatedDevice:
        return simulator.SimulatedDevice(
            self.device_identity.device_certificate, self.device_identity.device_key,
            self.device_identity.root_certificate, self.device_identity.host_certificate_der,
            self.device_identity.udid, accept_adhoc=self.accept_adhoc).start()

    def paired_bridge(self):
        self.bridge.connect(self.record)
        self.bridge.start_session()
        return self.bridge


class PairingTests(DeviceTestCase):
    def test_a_record_round_trips_and_keeps_its_host_id(self) -> None:
        parsed = pairing.PairingRecord.parse(self.record.to_plist())
        self.assertEqual(parsed.host_id, self.record.host_id)
        self.assertEqual(len(parsed.host_id), 40)
        self.assertEqual(parsed.udid, self.record.udid)

    def test_the_host_id_is_the_digest_of_the_host_certificate(self) -> None:
        self.assertEqual(self.record.host_id, pairing.host_id(self.record.host_certificate))
        self.assertEqual(self.record.host_id, self.record.host_id.upper())

    def test_a_record_that_disagrees_with_itself_is_refused(self) -> None:
        root = plistlib.loads(self.record.to_plist())
        root["HostID"] = "0" * 40
        with self.assertRaises(pairing.PairingError):
            pairing.PairingRecord.parse(plistlib.dumps(root))

    def test_an_empty_field_is_refused(self) -> None:
        root = plistlib.loads(self.record.to_plist())
        root["RootCertificate"] = b""
        with self.assertRaises(pairing.PairingError):
            pairing.PairingRecord.parse(plistlib.dumps(root))

    def test_bytes_that_are_not_a_plist_are_refused(self) -> None:
        with self.assertRaises(pairing.PairingError):
            pairing.PairingRecord.parse(b"not a pairing record")


class SessionTests(DeviceTestCase):
    def test_a_session_reports_the_device_it_reached(self) -> None:
        info = self.bridge.connect(self.record)
        self.assertEqual(info.product_type, "iPhone15,3")
        self.assertEqual(info.product_version, "17.4")
        self.assertEqual(info.udid, self.device_identity.udid)

    def test_starting_a_session_and_opening_a_service(self) -> None:
        self.paired_bridge()
        connection = self.bridge.service("com.apple.afc")
        self.assertIsNotNone(connection)
        connection.close()

    def test_an_unknown_service_is_refused(self) -> None:
        self.paired_bridge()
        with self.assertRaises(device.DeviceError):
            self.bridge.service("com.apple.not.a.service")

    def test_a_host_without_a_record_is_refused(self) -> None:
        other = device.DeviceBridge(self.device.port)
        with self.assertRaises(device.DeviceError):
            other.connect(None)


class InstallationTests(DeviceTestCase):
    def test_a_signed_package_installs_and_the_device_reports_it(self) -> None:
        self.paired_bridge()
        outcome = self.bridge.install_package(self.signed.data, self.signed.bundle_id, "Demo.ipa")
        self.assertTrue(outcome.installed)
        self.assertEqual(outcome.progress[-1]["Status"], "Complete")
        self.assertGreater(outcome.uploaded_bytes, 0)
        self.assertIn(self.signed.bundle_id, self.device.installed)
        self.assertFalse(self.device.installed[self.signed.bundle_id].adhoc)
        listed = self.bridge.list_apps()
        self.assertIn(self.signed.bundle_id, listed)

    def test_the_device_verifies_the_signature_itself(self) -> None:
        self.paired_bridge()
        self.bridge.install_package(self.signed.data, self.signed.bundle_id, "Demo.ipa")
        report = self.device.installed[self.signed.bundle_id].signature
        self.assertTrue(report.valid)
        self.assertTrue(report.cms_valid)

    def test_a_package_whose_bytes_changed_is_refused(self) -> None:
        rebuilt = bundle.IPABundle.from_bytes(self.signed.data)
        executable = rebuilt.main_executable()
        broken = bytearray(rebuilt.entries[executable])
        broken[0x500] ^= 0x01
        rebuilt.entries[executable] = bytes(broken)
        self.paired_bridge()
        with self.assertRaises(device.DeviceError) as raised:
            self.bridge.install_package(rebuilt.to_bytes(), self.signed.bundle_id, "Broken.ipa")
        self.assertEqual(raised.exception.code, "ApplicationVerificationFailed")

    def test_a_missing_package_path_is_reported(self) -> None:
        self.paired_bridge()
        connection = self.bridge.service("com.apple.mobile.installation_proxy")
        from zynsim import protocol
        protocol.send_plist(connection, {"Command": "Install", "PackagePath": "/PublicStaging/none.ipa"})
        message = protocol.receive_plist(connection)
        while message.get("Status") != "Complete":
            message = protocol.receive_plist(connection)
        self.assertEqual(message.get("Error"), "APIInternalError")
        connection.close()


class AdHocPolicyTests(DeviceTestCase):
    accept_adhoc = False

    def test_a_stock_device_refuses_an_adhoc_signature(self) -> None:
        self.paired_bridge()
        outcome = self.adhoc
        with self.assertRaises(device.DeviceError) as raised:
            self.bridge.install_package(outcome.data, outcome.bundle_id, "AdHoc.ipa")
        self.assertEqual(raised.exception.code, "ApplicationVerificationFailed")
        self.assertNotIn(outcome.bundle_id, self.device.installed)


class PermissiveDeviceTests(DeviceTestCase):
    accept_adhoc = True

    def test_a_device_that_accepts_adhoc_installs_it(self) -> None:
        self.paired_bridge()
        outcome = self.adhoc
        installed = self.bridge.install_package(outcome.data, outcome.bundle_id, "AdHoc.ipa")
        self.assertTrue(installed.installed)
        self.assertTrue(self.device.installed[outcome.bundle_id].adhoc)


class ContainerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.ipa = fixtures.build_ipa(with_extension=False)
        cls.loader = fixtures.build_macho(filetype=macho.MH_DYLIB, install_name="@rpath/TweakLoader.dylib")
        cls.tweak = fixtures.build_macho(filetype=macho.MH_DYLIB)
        cls.prepared = {}

    def prepare(self, tweaks=None):
        from zynsim import container
        key = "tweaks" if tweaks else "plain"
        if key not in self.prepared:
            self.prepared[key] = container.prepare_container(
                self.ipa, loader=self.loader, tweaks=tweaks)
        return self.prepared[key]


    def test_the_guest_is_patched_and_signed(self) -> None:
        result = self.prepare(tweaks={"DemoTweak.dylib": self.tweak})
        self.assertTrue(result.verified)
        guest = macho.MachO(result.entries[f"{result.root}/App.app/Demo"])
        self.assertEqual(guest.filetype, macho.MH_DYLIB)
        self.assertIn("@executable_path/Frameworks/TweakLoader.dylib", guest.dylib_paths())

    def test_the_container_has_data_directories_and_metadata(self) -> None:
        result = self.prepare()
        for directory in ("Documents", "Library/Caches", "Library/Preferences", "tmp"):
            self.assertIn(f"{result.root}/Data/{directory}/.keep", result.entries)
        metadata = plistlib.loads(result.entries[f"{result.root}/ZynGuestInfo.plist"])
        self.assertEqual(metadata["ZynBundleId"], "com.example.demo")
        self.assertEqual(metadata["ZynGuestPath"], f"{result.root}/App.app")
        self.assertEqual(metadata["ZynLoader"], "@executable_path/Frameworks/TweakLoader.dylib")

    def test_tweaks_are_staged_and_signed(self) -> None:
        result = self.prepare(tweaks={"DemoTweak.dylib": self.tweak})
        tweak = result.entries[f"{result.root}/Tweaks/DemoTweak.dylib"]
        self.assertTrue(codesign.verify_image(tweak).valid)

    def test_an_extension_blocks_the_guest(self) -> None:
        from zynsim import container
        assessment = container.assess_guest(fixtures.build_ipa(with_extension=True))
        self.assertFalse(assessment.can_run)
        self.assertEqual(assessment.blocks[0].code, "appExtensions")
        with self.assertRaises(container.ContainerError):
            container.prepare_container(fixtures.build_ipa(with_extension=True))

    def test_the_launch_plan_names_each_runtime_step(self) -> None:
        plan = self.prepare().launch_plan
        self.assertEqual(len(plan), 6)
        self.assertIn("dlopen", plan[0])
        self.assertIn('dlsym(handle, "main")', plan[1])
        self.assertIn("NSHomeDirectory", plan[2])

    def test_a_missing_loader_marks_the_plan_blocked(self) -> None:
        from zynsim import container
        result = container.prepare_container(self.ipa)
        self.assertTrue(result.launch_plan[0].startswith("BLOCKED"))
        self.assertTrue(any("dlsym" in step for step in result.launch_plan))


if __name__ == "__main__":
    unittest.main()
