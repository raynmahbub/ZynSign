"""Guest-container tests: what makes a signed app runnable inside the host.

The container transformation is what makes a guest runnable: the guest is
patched from an executable into a loadable dylib, the loader is linked into
its header, and the whole thing is ad-hoc signed because nothing is being
installed.
"""

from __future__ import annotations

import json
import plistlib
import unittest

from zynsim import bundle, codesign, container, fixtures, macho


class GuestAssessmentTests(unittest.TestCase):
    def test_a_plain_arm64_app_is_runnable(self) -> None:
        assessment = container.assess_guest(fixtures.build_ipa(with_extension=False))
        self.assertTrue(assessment.runnable)
        self.assertEqual(assessment.bundle_id, "com.example.demo")
        self.assertEqual(assessment.version, "1.0")

    def test_fairplay_encrypted_binaries_are_blocked(self) -> None:
        ipa = bundle.IPABundle({
            "Payload/E.app/Info.plist": fixtures.app_info("com.x.e", "E", "E"),
            "Payload/E.app/E": fixtures.build_executable(encrypted=True),
        })
        assessment = container.assess_guest(ipa)
        self.assertFalse(assessment.runnable)
        self.assertEqual(assessment.blocks[0].code, "fairplayEncrypted")

    def test_non_position_independent_binaries_are_blocked(self) -> None:
        ipa = bundle.IPABundle({
            "Payload/E.app/Info.plist": fixtures.app_info("com.x.e", "E", "E"),
            "Payload/E.app/E": fixtures.build_executable(position_independent=False),
        })
        self.assertEqual(container.assess_guest(ipa).blocks[0].code,
                         "notPositionIndependent")

    def test_extensions_block_the_container(self) -> None:
        assessment = container.assess_guest(fixtures.build_ipa(with_extension=True))
        self.assertFalse(assessment.runnable)
        self.assertEqual(assessment.blocks[0].code, "appExtensions")

    def test_a_watch_bundle_blocks_the_container(self) -> None:
        assessment = container.assess_guest(fixtures.build_ipa(with_extension=False,
                                                                with_watch=True))
        self.assertEqual(assessment.blocks[0].code, "watchApp")


class ContainerPreparationTests(unittest.TestCase):
    def prepare(self, **kwargs):
        return container.prepare_container(
            fixtures.build_ipa(with_extension=False),
            loader=fixtures.build_dylib("@rpath/TweakLoader.dylib"), **kwargs)

    def test_guest_becomes_a_loadable_dylib(self) -> None:
        result = self.prepare()
        guest = macho.MachO(result.entries["Applications/com.example.demo/App.app/Demo"])
        self.assertEqual(guest.filetype, macho.MH_DYLIB)
        self.assertIn("@executable_path/Frameworks/TweakLoader.dylib",
                      guest.dylib_paths())

    def test_every_container_binary_is_adhoc_and_verifies(self) -> None:
        result = self.prepare()
        self.assertTrue(result.verified)
        for path in result.signed_binaries:
            relocated = path.replace("Payload/Demo.app",
                                     "Applications/com.example.demo/App.app")
            report = codesign.verify_image(result.entries[relocated])
            self.assertTrue(report.adhoc)
            self.assertTrue(report.valid)

    def test_app_info_plist_describes_the_container(self) -> None:
        result = self.prepare()
        info = plistlib.loads(
            result.entries["Applications/com.example.demo/ZynGuestInfo.plist"])
        self.assertEqual(info["ZynBundleId"], "com.example.demo")
        self.assertEqual(info["ZynGuestPath"], "Applications/com.example.demo/App.app")
        self.assertEqual(info["ZynExecutable"], "Demo")
        self.assertEqual(info["ZynSignature"], "adhoc")
        self.assertEqual(info["ZynContainerVersion"], 1)
        manifest = json.loads(
            result.entries["Applications/com.example.demo/ZynContainer.json"])
        self.assertEqual(manifest["entryPoint"], "main")
        self.assertEqual(manifest["loader"], "TweakLoader.dylib")

    def test_tweaks_are_staged_under_the_container(self) -> None:
        tweak = fixtures.build_dylib("@rpath/MyTweak.dylib", text_size=2048)
        result = self.prepare(tweaks={"MyTweak.dylib": tweak})
        path = "Applications/com.example.demo/Tweaks/MyTweak.dylib"
        self.assertIn(path, result.entries)
        info = plistlib.loads(
            result.entries["Applications/com.example.demo/ZynGuestInfo.plist"])
        self.assertEqual(info["ZynTweaks"], ["MyTweak.dylib"])

    def test_data_container_directories_are_created(self) -> None:
        result = self.prepare()
        for directory in ("Documents", "Library/Preferences", "Library/Caches", "tmp"):
            self.assertIn(
                f"Applications/com.example.demo/Data/{directory}/.keep", result.entries)

    def test_missing_loader_makes_the_launch_plan_blocked(self) -> None:
        result = container.prepare_container(
            fixtures.build_ipa(with_extension=False))
        self.assertTrue(result.launch_plan[0].startswith("BLOCKED"))
        self.assertTrue(any("dlsym" in step for step in result.launch_plan))

    def test_rename_is_applied_before_patching(self) -> None:
        result = container.prepare_container(
            fixtures.build_ipa(with_extension=False),
            loader=fixtures.build_dylib("@rpath/TweakLoader.dylib"),
            rename=bundle.Overrides(bundle_id="com.example.renamed",
                                    display_name="Renamed"))
        self.assertIn("Applications/com.example.renamed/ZynGuestInfo.plist", result.entries)
        info = plistlib.loads(
            result.entries["Applications/com.example.renamed/App.app/Info.plist"])
        self.assertEqual(info["CFBundleIdentifier"], "com.example.renamed")

    def test_blocked_guest_cannot_be_prepared(self) -> None:
        ipa = bundle.IPABundle({
            "Payload/E.app/Info.plist": fixtures.app_info("com.x.e", "E", "E"),
            "Payload/E.app/E": fixtures.build_executable(encrypted=True),
        })
        with self.assertRaises(container.ContainerError):
            container.prepare_container(ipa)


if __name__ == "__main__":
    unittest.main()
