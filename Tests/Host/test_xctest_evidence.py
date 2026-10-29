"""Host-side contract for native XCTest evidence.

These tests do not run XCTest and do not need Xcode. They lock the upload
policy in the macOS workflows and the summary formatter build.sh calls after
the suite. A green result here is not a simulator test run.
"""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

from Scripts.ci import xctest_evidence

ROOT = Path(__file__).resolve().parents[2]
BUILD_WORKFLOW = ROOT / ".github" / "workflows" / "01-build.yml"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "03-release.yml"
BUILD_SCRIPT = ROOT / "Scripts" / "ci" / "build.sh"

UPLOAD_STEP = "Upload native XCTest evidence"
PREPARE_STEP = "Keep signing material out of the XCTest evidence"
ARTIFACT_NAME = "xctest-results-${{ github.run_id }}-${{ github.run_attempt }}"


def step_block(text: str, name: str) -> str:
    lines = text.splitlines()
    start = None
    needle = f"- name: {name}"
    for index, line in enumerate(lines):
        if line.strip() == needle:
            start = index
            break
    if start is None:
        raise AssertionError(f"step not found: {name}")
    block = [lines[start]]
    for line in lines[start + 1 :]:
        if line.startswith("      - name:"):
            break
        if line.startswith("  #") or (line and not line.startswith(" ")):
            break
        if line.startswith("  ") and not line.startswith("      ") and line.strip():
            break
        block.append(line)
    return "\n".join(block)


class XCTestSummaryTests(unittest.TestCase):
    def test_failed_bundle_summary_records_toolchain_destination_and_counts(self) -> None:
        summary = {
            "result": "Failed",
            "totalTestCount": 4,
            "passedTests": 2,
            "failedTests": 1,
            "skippedTests": 1,
            "expectedFailures": 0,
            "testFailures": [
                {
                    "testIdentifierString": "ZynSignTests/FooTests/testBar()",
                    "testName": "testBar()",
                    "failureText": "XCTAssertEqual failed: (\"1\") is not equal to (\"2\")",
                }
            ],
            "devicesAndConfigurations": [
                {
                    "device": {
                        "deviceName": "iPhone 16",
                        "platform": "iOS Simulator",
                        "osVersion": "18.5",
                        "deviceId": "should-not-appear",
                    }
                }
            ],
        }
        context = {
            "xcode_version": "Xcode 16.4 Build version 16F6",
            "simulator_destination": "platform=iOS Simulator,name=iPhone 16,OS=latest",
            "run_tests": "1",
        }
        text = xctest_evidence.render_text(
            "Failed",
            xctest_evidence.merge_counts(summary, ""),
            xctest_evidence.failure_names(summary),
            context,
            "build/logs/ZynSignTests.xcresult",
            "xctest-results-99-2",
            14,
            xctest_evidence.bundle_device(summary),
        )
        self.assertIn("Xcode 16.4 Build version 16F6", text)
        self.assertIn("platform=iOS Simulator,name=iPhone 16,OS=latest", text)
        self.assertIn("failedTests=1", text)
        self.assertIn("totalTestCount=4", text)
        self.assertIn("ZynSignTests/FooTests/testBar()", text)
        self.assertNotIn("should-not-appear", text)
        self.assertIn("iPhone 16 iOS Simulator 18.5", text)
        self.assertTrue(text.splitlines()[0].startswith("Failed:"))

    def test_missing_json_falls_back_to_the_xcodebuild_log(self) -> None:
        log = "\n".join(
            [
                "Test Case '-[ZynSignTests.FooTests testBar]' failed (0.001 seconds).",
                "** TEST FAILED **",
                "Executed 3 tests, with 1 failure (0 unexpected) in 0.010 (0.012) seconds",
            ]
        )
        context = {
            "xcode_version": "Xcode 16.4 Build version 16F6",
            "simulator_destination": "platform=iOS Simulator,name=iPhone 16,OS=latest",
            "run_tests": "1",
        }
        result = xctest_evidence.resolve_result({}, log, context)
        counts = xctest_evidence.merge_counts({}, log)
        names = xctest_evidence.failure_names_from_log(log)
        self.assertEqual(result, "Failed")
        self.assertEqual(counts["totalTestCount"], 3)
        self.assertEqual(counts["failedTests"], 1)
        self.assertEqual(names, ["-[ZynSignTests.FooTests testBar]"])

    def test_skipped_run_does_not_claim_a_passing_suite(self) -> None:
        context = {
            "xcode_version": "Xcode 16.4 Build version 16F6",
            "simulator_destination": "skipped (RUN_TESTS=0)",
            "run_tests": "0",
        }
        result = xctest_evidence.resolve_result({}, "", context)
        status, _badge = xctest_evidence.status_badge(result, context)
        self.assertEqual(result, "Skipped")
        self.assertEqual(status, "Skipped")

    def test_markdown_escapes_table_pipes_and_names_the_artifact(self) -> None:
        markdown = xctest_evidence.render_markdown(
            "Passed",
            {"passedTests": 1, "failedTests": 0, "totalTestCount": 1},
            [],
            {
                "xcode_version": "Xcode 16.4 | Build version 16F6",
                "simulator_destination": "platform=iOS Simulator,name=iPhone 16,OS=latest",
                "run_tests": "1",
            },
            "build/logs/ZynSignTests.xcresult",
            "xctest-results-99-1",
            14,
            "",
            "https://github.com/example/ZynSign/actions/runs/99",
        )
        self.assertIn("Xcode 16.4 \\| Build version 16F6", markdown)
        self.assertIn("`xctest-results-99-1`", markdown)
        self.assertIn("14 days", markdown)
        self.assertIn("gh run download <run-id> --name xctest-results-99-1", markdown)

    def test_summarize_command_writes_files_and_drops_unreadable_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "summary.json"
            raw.write_text("not-json", encoding="utf-8")
            output = root / "xctest-summary.txt"
            markdown = root / "xctest-summary.md"
            status = xctest_evidence.main(
                [
                    "summarize",
                    "--json",
                    str(raw),
                    "--output",
                    str(output),
                    "--markdown",
                    str(markdown),
                    "--artifact",
                    "xctest-results-local-0",
                    "--retention-days",
                    "14",
                ]
            )
            self.assertEqual(status, 0)
            self.assertFalse(raw.exists())
            self.assertIn("result=unavailable", output.read_text(encoding="utf-8"))
            self.assertIn("XCTest evidence", markdown.read_text(encoding="utf-8"))


class XCTestEvidencePrepareTests(unittest.TestCase):
    def test_missing_directory_is_not_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / "logs"
            self.assertEqual(xctest_evidence.prepare(missing), 0)
            self.assertEqual(xctest_evidence.main(["prepare", str(missing)]), 0)

    def test_secret_filenames_are_quarantined_without_opening_the_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            logs = Path(temporary) / "logs"
            logs.mkdir()
            (logs / "test.log").write_text("suite log\n", encoding="utf-8")
            (logs / "identity.p12").write_text("not-a-real-key\n", encoding="utf-8")
            (logs / "Notes.PEM").write_text("not-a-real-certificate\n", encoding="utf-8")
            bundle = logs / "ZynSignTests.xcresult"
            bundle.mkdir()
            (bundle / "Info.plist").write_text("bundle\n", encoding="utf-8")
            nested = bundle / "fixture.mobileprovision"
            nested.write_text("synthetic fixture\n", encoding="utf-8")

            self.assertEqual(xctest_evidence.prepare(logs), 0)

            self.assertFalse((logs / "identity.p12").exists())
            self.assertFalse((logs / "Notes.PEM").exists())
            quarantine = Path(temporary) / "xctest-evidence-quarantine"
            self.assertTrue((quarantine / "identity.p12").is_file())
            self.assertTrue((quarantine / "Notes.PEM").is_file())
            self.assertEqual(nested.read_text(encoding="utf-8"), "synthetic fixture\n")
            self.assertTrue((logs / "test.log").is_file())
            self.assertTrue((bundle / "Info.plist").is_file())

            target = logs / "real-key-material"
            target.write_text("do-not-upload\n", encoding="utf-8")
            link = logs / "id_rsa"
            link.symlink_to(target)
            self.assertEqual(xctest_evidence.prepare(logs), 0)
            self.assertFalse(link.exists())
            self.assertTrue(target.is_file())
            self.assertTrue((quarantine / "id_rsa").is_symlink())


class XCTestEvidenceWorkflowTests(unittest.TestCase):
    def test_build_and_release_upload_on_always_with_a_run_identity(self) -> None:
        for path in (BUILD_WORKFLOW, RELEASE_WORKFLOW):
            text = path.read_text(encoding="utf-8")
            with self.subTest(path=path.name):
                self.assertNotIn("build-test-logs", text)
                self.assertNotIn("release-build-logs", text)
                upload = step_block(text, UPLOAD_STEP)
                prepare = step_block(text, PREPARE_STEP)
                self.assertIn("if: always()", upload)
                self.assertNotIn("if: failure()", upload)
                self.assertIn("if: always()", prepare)
                self.assertIn(ARTIFACT_NAME, upload)
                self.assertIn("github.run_id", upload)
                self.assertIn("github.run_attempt", upload)
                self.assertIn("retention-days: 14", upload)
                self.assertIn("if-no-files-found: warn", upload)
                self.assertIn("include-hidden-files: false", upload)
                self.assertIn(
                    "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
                    upload,
                )
                for required in (
                    "build/logs/*.log",
                    "build/logs/xctest-context.txt",
                    "build/logs/xctest-summary.txt",
                    "build/logs/xctest-summary.json",
                    "build/logs/xctest-summary.md",
                    "build/logs/ZynSignTests.xcresult",
                ):
                    self.assertIn(required, upload)
                self.assertNotIn("DerivedData", upload)
                self.assertNotIn("build/private", upload)
                self.assertNotIn("path: build/logs/\n", upload)
                self.assertNotIn("path: build/\n", upload)
                for suffix in xctest_evidence.FORBIDDEN_SUFFIXES:
                    self.assertIn(f"!build/logs/**/*{suffix}", upload)
                for name in xctest_evidence.FORBIDDEN_NAMES:
                    self.assertIn(f"!build/logs/**/{name}", upload)

    def test_build_sh_preserves_the_full_xctest_invocation(self) -> None:
        text = BUILD_SCRIPT.read_text(encoding="utf-8")
        test_block = text.split("xcodebuild test \\", 1)[1].split("\n\n", 1)[0]
        self.assertIn('-project "${PROJECT}"', test_block)
        self.assertIn('-scheme "${SCHEME}"', test_block)
        self.assertIn(
            '-destination "platform=iOS Simulator,name=${SIMULATOR},OS=latest"',
            test_block,
        )
        self.assertIn('-derivedDataPath "${DERIVED_DATA}"', test_block)
        self.assertIn('-resultBundlePath "${RESULT_BUNDLE}"', test_block)
        self.assertNotIn("-quiet", test_block)
        self.assertNotIn("-only-testing", test_block)
        self.assertIn("trap finish EXIT", text)
        self.assertIn("xctest_evidence.py", text)
        self.assertIn("--retention-days 14", text)
        self.assertIn("xctest-results-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}", text)
        parsed = subprocess.run(
            ["bash", "-n", str(BUILD_SCRIPT)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(parsed.returncode, 0, parsed.stderr)

    def test_release_verdict_names_the_new_artifact(self) -> None:
        text = (ROOT / "Scripts" / "ci" / "release_verdict.sh").read_text(encoding="utf-8")
        self.assertNotIn("release-build-logs", text)
        self.assertIn("xctest-results-", text)
