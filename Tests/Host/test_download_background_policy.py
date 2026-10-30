"""Static guard against reviving the unsupported silent-audio download trick.

This does not replace an iOS lifecycle test or prove background-transfer support.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ZynSign"


class DownloadBackgroundPolicyTests(unittest.TestCase):
    def test_legacy_preference_is_not_used_to_control_downloads(self):
        references = []
        for path in SOURCE.rglob("*.swift"):
            if "keepDownloadsAliveInBackground" in path.read_text(encoding="utf-8"):
                references.append(path.relative_to(ROOT).as_posix())
        self.assertEqual(references, ["ZynSign/Application/UserPreferences.swift"])

    def test_silent_audio_download_controller_is_not_composed(self):
        for path in SOURCE.rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("AVAudioBackgroundDownloadKeepAlive", text, str(path))
            self.assertNotIn("BackgroundDownloadKeepAliveControlling", text, str(path))


if __name__ == "__main__":
    unittest.main()
