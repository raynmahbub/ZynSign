from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from Scripts import apply_release_changelog, generate_changelog


class GenerateChangelogTests(unittest.TestCase):
    def test_conventional_commits_are_grouped_into_user_facing_categories(self) -> None:
        groups = generate_changelog.group_commits([
            generate_changelog.Commit("feat(import): accept .tipa (#77)"),
            generate_changelog.Commit("fix(settings): avoid nested navigation (#81)"),
            generate_changelog.Commit("perf(library): reuse bundle index"),
            generate_changelog.Commit("security: keep signing keys non-extractable"),
            generate_changelog.Commit("docs: explain release evidence"),
            generate_changelog.Commit("test(import): cover provider reads"),
        ])

        self.assertIn("###", generate_changelog.build_entry("0.0.2", "2026-10-01", groups))
        self.assertIn("- **import:** accept .tipa ([#77](https://github.com/raynmahbub/ZynSign/pull/77))", groups["Added"])
        self.assertIn("- **settings:** avoid nested navigation ([#81](https://github.com/raynmahbub/ZynSign/pull/81))", groups["Fixed"])
        self.assertIn("Performance", groups)
        self.assertIn("Security", groups)
        self.assertIn("Documentation", groups)
        self.assertIn("Tests", groups)

    def test_breaking_markers_are_separated_from_their_conventional_type(self) -> None:
        groups = generate_changelog.group_commits([
            generate_changelog.Commit(
                "feat(api)!: remove the legacy signing entry point",
                "BREAKING CHANGE: callers must use SignApplicationPipeline.",
            ),
        ])

        self.assertNotIn("Added", groups)
        self.assertIn("- **api:** callers must use SignApplicationPipeline.", groups["Breaking Changes"])

    def test_automation_commits_are_excluded(self) -> None:
        self.assertTrue(generate_changelog.is_automation_commit("docs(changelog): auto v0.0.2-dev.1"))
        self.assertTrue(generate_changelog.is_automation_commit("release: v0.0.2-dev.1"))
        groups = generate_changelog.group_commits(["release: v0.0.2-dev.1"])
        self.assertEqual(groups, {})

    def test_generator_uses_ancestry_and_writes_an_idempotent_notes_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            changelog = root / "CHANGELOG.md"
            releases = root / "docs" / "releases"
            releases.mkdir(parents=True)
            changelog.write_text(
                "# Changelog\n\n## [Unreleased]\n\n## [0.0.1] - 2026-10-01\n\nInitial.\n",
                encoding="utf-8",
            )
            self._git(root, "init", "-q")
            self._git(root, "config", "user.name", "Changelog Test")
            self._git(root, "config", "user.email", "changelog-test@example.invalid")
            self._git(root, "add", "CHANGELOG.md")
            self._git(root, "commit", "-m", "chore: establish baseline")
            self._git(root, "tag", "v0.0.1")
            (root / "src.txt").write_text("tipa policy\n", encoding="utf-8")
            self._git(root, "add", "src.txt")
            self._git(root, "commit", "-m", "feat(import): accept .tipa (#77)")
            self._git(root, "tag", "v0.0.2-dev.1")

            args = [
                "generate_changelog.py",
                "--version", "0.0.2-dev.1",
                "--tag", "v0.0.2-dev.1",
                "--date", "2026-10-01",
            ]
            with (
                mock.patch.object(generate_changelog, "ROOT", root),
                mock.patch.object(generate_changelog, "CHANGELOG", changelog),
                mock.patch.object(generate_changelog, "RELEASES_DIR", releases),
                mock.patch.object(generate_changelog.sys, "argv", args),
            ):
                self.assertEqual(generate_changelog.main(), 0)

            rendered = changelog.read_text(encoding="utf-8")
            notes = releases / "notes-v0.0.2-dev.1.md"
            self.assertIn("## [0.0.2-dev.1] - 2026-10-01 — Auto-generated", rendered)
            self.assertIn("### Added", rendered)
            self.assertIn("accept .tipa", rendered)
            self.assertIn("v0.0.1..v0.0.2-dev.1", rendered)
            self.assertEqual(notes.read_text(encoding="utf-8"), generate_changelog.release_section(rendered, "0.0.2-dev.1") + "\n")

            notes.write_text("Curated release note.\n", encoding="utf-8")
            with mock.patch.object(generate_changelog, "CHANGELOG", changelog), mock.patch.object(
                generate_changelog, "RELEASES_DIR", releases
            ), mock.patch.object(generate_changelog.sys, "argv", args):
                self.assertEqual(generate_changelog.main(), 0)
            self.assertEqual(notes.read_text(encoding="utf-8"), "Curated release note.\n")

    @staticmethod
    def _git(root: Path, *arguments: str) -> None:
        import subprocess

        subprocess.run(["git", *arguments], cwd=root, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


class ApplyReleaseChangelogTests(unittest.TestCase):
    def test_applies_release_after_unreleased_without_dropping_newer_work(self) -> None:
        current = (
            "# Changelog\n\n"
            "## [Unreleased]\n\n"
            "### Added\n\n- A later main-branch change.\n\n"
            "## [0.0.1] - 2026-10-01\n\n- Existing release.\n"
        )
        generated = (
            "# Changelog\n\n"
            "## [0.0.2-dev.1] - 2026-10-01 — Auto-generated\n\n"
            "### Fixed\n\n- Provider-backed certificate import.\n\n"
        )

        updated, changed = apply_release_changelog.apply_entry(current, generated, "0.0.2-dev.1")

        self.assertTrue(changed)
        self.assertIn("- A later main-branch change.", updated)
        self.assertIn("## [0.0.2-dev.1]", updated)
        self.assertLess(updated.index("## [Unreleased]"), updated.index("## [0.0.2-dev.1]"))
        repeated, changed_again = apply_release_changelog.apply_entry(updated, generated, "0.0.2-dev.1")
        self.assertFalse(changed_again)
        self.assertEqual(repeated, updated)


if __name__ == "__main__":
    unittest.main()
