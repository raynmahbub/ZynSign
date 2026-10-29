"""Synthetic host tests: these do not execute native XCTest."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from Scripts.ci import xctest_results as evidence


def tree(*cases):
    return {"testNodes": [{"nodeType": "Test Suite", "name": "FooTests", "children": [
        {"nodeType": "Test Case", "name": name + "()", "result": result, "message": "SECRET"}
        for name, result in cases
    ]}]}


class XCTestResultsTests(unittest.TestCase):
    def test_statuses_and_retries(self):
        data = tree(("testPass", "Passed"), ("testFail", "Failed"),
                    ("testSkip", "Skipped"), ("testRetry", "Failed"),
                    ("testRetry", "Passed"), ("testUnknown", "Running"))
        allowed = {f"FooTests.test{x}" for x in ("Pass", "Fail", "Skip", "Retry", "Unknown")}
        self.assertEqual(evidence.test_results(data, allowed), {
            "FooTests.testPass": "PASS", "FooTests.testFail": "FAIL",
            "FooTests.testSkip": "SKIPPED", "FooTests.testRetry": "NOT VERIFIED",
            "FooTests.testUnknown": "NOT VERIFIED",
        })

    def test_named_results_use_exact_identity_and_missing_is_not_verified(self):
        target = evidence.TARGETS[0]
        cls, method = target.split(".")
        data = {"testNodes": [{"nodeType": "Test Suite", "name": cls, "children": [
            {"nodeType": "Test Case", "name": method + "()", "result": "Passed"}]}]}
        report = evidence.create_report(data, {}, {target})
        self.assertEqual(report["named_tests"][target], "PASS")
        self.assertEqual(report["named_tests"][evidence.TARGETS[1]], "NOT VERIFIED")
        data["testNodes"][0]["children"].append(
            {"nodeType": "Test Case", "name": method + "()", "result": "Failed"})
        self.assertEqual(evidence.create_report(data, {}, {target})["named_tests"][target], "NOT VERIFIED")
        self.assertEqual(evidence.create_report(data, {}, set())["named_tests"][target], "NOT VERIFIED")

    def test_all_named_tests_are_reported_from_their_own_cases(self):
        nodes = []
        for target, status in zip(evidence.TARGETS, ("Passed", "Failed", "Skipped")):
            cls, method = target.split(".")
            nodes.append({"nodeType": "Test Suite", "name": cls, "children": [
                {"nodeType": "Test Case", "name": method + "()", "result": status}]})
        report = evidence.create_report({"testNodes": nodes}, {}, set(evidence.TARGETS))
        self.assertEqual(list(report["named_tests"].values()), ["PASS", "FAIL", "SKIPPED"])

    def test_allowlist_and_no_untrusted_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Foo.swift"
            path.write_text("final class FooTests: XCTestCase { func testPass() {} }", encoding="utf-8")
            allowed = evidence.source_allowlist(Path(directory))
        report = evidence.create_report(tree(("testPass", "Passed"), ("testSecret", "Passed"),
                                             ("testPass(secret)", "Passed")), {}, allowed)
        self.assertEqual(report["tests"], {"FooTests.testPass": "PASS"})
        self.assertNotIn("SECRET", json.dumps(report))
        self.assertNotIn("testSecret", json.dumps(report))
        self.assertNotIn("secret", evidence.markdown(report).lower().replace("source", ""))

    def test_node_identifier_and_repetition_handling(self):
        target = evidence.TARGETS[1]
        cls, method = target.split(".")
        case = {"nodeType": "Test Case", "name": method + "()",
                "nodeIdentifier": cls + "/" + method + "()", "result": "Passed"}
        data = {"testNodes": [{"nodeType": "Test Suite", "name": cls, "children": [case]}]}
        self.assertEqual(evidence.test_results(data, {target})[target], "PASS")
        case["children"] = [{"nodeType": "Repetition", "result": "Failed"}]
        self.assertEqual(evidence.test_results(data, {target})[target], "NOT VERIFIED")
        case["nodeIdentifier"] = "OtherTests/" + method + "()"
        self.assertEqual(evidence.test_results(data, {target}), {})

    def test_workflow_upload_and_exit_status_contract(self):
        root = Path(evidence.__file__).resolve().parents[2]
        script = (root / "Scripts/ci/build.sh").read_text()
        workflow = (root / ".github/workflows/01-build.yml").read_text()
        finish = script.split("finish() {", 1)[1].split("\n}", 1)[0]
        self.assertIn("status=$?", finish)
        self.assertIn('xctest_results.py', finish)
        self.assertIn('|| true', finish)
        self.assertIn('exit "${status}"', finish)
        for name in ("xctest-results.json", "xctest-results.md"):
            self.assertIn("build/logs/" + name, workflow)
        self.assertIn("if: always()", workflow)
        self.assertIn("if-no-files-found: warn", workflow)

    def test_counts_require_unambiguous_top_level_numbers(self):
        good = {"passedTests": 2, "failedTests": 1, "skippedTests": 1, "totalTestCount": 4}
        self.assertEqual(evidence.aggregate(good), good)
        for data in ({}, {"nested": good}, {**good, "totalTestCount": 3},
                     {**good, "passedTests": True}, {**good, "expectedFailures": 1}):
            with self.subTest(data=data):
                self.assertIsNone(evidence.aggregate(data))

    def test_invalid_tree_and_unsafe_names_are_omitted(self):
        self.assertEqual(evidence.test_results({"testNodes": "bad"}, {"FooTests.testPass"}), {})
        data = tree(("testPass%0A::error::oops", "Passed"))
        self.assertEqual(evidence.test_results(data, {"FooTests.testPass%0A::error::oops"}), {})

    def test_tool_interface_probed_and_failure_is_unavailable(self):
        with tempfile.TemporaryDirectory() as bundle:
            with patch.object(evidence.subprocess, "run") as run:
                run.return_value = subprocess.CompletedProcess([], 0, "--path --format", "")
                run.side_effect = [run.return_value, subprocess.CompletedProcess([], 0, '{"testNodes": []}', "")]
                self.assertEqual(evidence.xcresult_json(bundle, "tests"), {"testNodes": []})
                self.assertEqual(run.call_args_list[0].args[0][-1], "--help")
                self.assertEqual(run.call_args_list[1].args[0][-2:], ["--format", "json"])
            with patch.object(evidence.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "--path", "")) as run:
                self.assertIsNone(evidence.xcresult_json(bundle, "tests"))
                self.assertEqual(run.call_count, 1)
            with patch.object(evidence.subprocess, "run", side_effect=OSError("missing")):
                self.assertIsNone(evidence.xcresult_json(bundle, "tests"))

    def test_missing_bundle_produces_api_notices_and_report(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, "GITHUB_ACTIONS": "true", "GITHUB_STEP_SUMMARY": str(Path(directory) / "summary")}
            result = subprocess.run(["python3", str(Path(evidence.__file__)), "--bundle", "",
                                     "--output-dir", directory], capture_output=True, text=True, env=env, check=True)
            report = json.loads((Path(directory) / "xctest-results.json").read_text())
            self.assertEqual(list(report["named_tests"].values()), ["NOT VERIFIED"] * 3)
            self.assertIsNone(report["counts"])
            self.assertEqual(result.stdout.count("::notice title=XCTest individual result::"), 3)
            self.assertIn("NOT VERIFIED", (Path(directory) / "summary").read_text())


if __name__ == "__main__":
    unittest.main()
