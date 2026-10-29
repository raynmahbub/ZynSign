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

    def test_markdown_complete_at_exact_byte_limit(self):
        report = evidence.create_report({}, {}, set())
        complete = evidence.markdown(report)
        result = evidence.markdown(report, byte_limit=len(complete.encode("utf-8")))
        self.assertEqual(result, complete)
        self.assertIn(report["limitations"], result)
        for name in evidence.TARGETS:
            self.assertIn(name, result)
        self.assertNotIn("Markdown report shortened", result)

    def test_markdown_oversize_uses_bounded_json_notice(self):
        report = evidence.create_report({}, {}, set())
        report["limitations"] = "x" * (evidence.MARKDOWN_BYTE_LIMIT + 1)
        result = evidence.markdown(report)
        self.assertLessEqual(len(result.encode("utf-8")), evidence.MARKDOWN_BYTE_LIMIT)
        self.assertEqual(result, evidence.MARKDOWN_FALLBACK)
        self.assertIn("xctest-results.json", result)
        self.assertIn("shortened", result)

    def test_markdown_limit_counts_utf8_bytes_not_characters(self):
        report = evidence.create_report({}, {}, set())
        report["limitations"] = "é" * 300
        complete = evidence.markdown(report)
        limit = len(complete)
        self.assertGreater(len(complete.encode("utf-8")), limit)
        result = evidence.markdown(report, byte_limit=limit)
        self.assertEqual(result, evidence.MARKDOWN_FALLBACK)
        self.assertLessEqual(len(result.encode("utf-8")), limit)

    def test_markdown_limit_too_small_raises(self):
        report = evidence.create_report({}, {}, set())
        fallback_size = len(evidence.MARKDOWN_FALLBACK.encode("utf-8"))
        self.assertEqual(evidence.markdown(report, byte_limit=fallback_size), evidence.MARKDOWN_FALLBACK)
        for limit in (fallback_size - 1, 0, -1):
            with self.subTest(limit=limit), self.assertRaisesRegex(ValueError, "too small"):
                evidence.markdown(report, byte_limit=limit)

    def test_multiple_test_classes_are_not_cross_associated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Mixed.swift").write_text(
                "class FooTests: XCTestCase { func testFoo() {} }\n"
                "class BarTests: XCTestCase { func testBar() {} }\n", encoding="utf-8")
            (root / "Single.swift").write_text(
                "class SoloTests: XCTestCase { func testSolo() {} }", encoding="utf-8")
            allowed = evidence.source_allowlist(root)
        self.assertEqual(allowed, {"SoloTests.testSolo"})
        cases = {"testNodes": [
            {"nodeType": "Test Suite", "name": "FooTests", "children": [
                {"nodeType": "Test Case", "name": "testBar()", "result": "Passed"}]}]}
        self.assertEqual(evidence.test_results(cases, allowed), {})
        self.assertIn("multiple test classes", evidence.create_report(cases, {}, allowed)["limitations"])

    def test_repository_named_targets_remain_allowlisted(self):
        root = Path(evidence.__file__).resolve().parents[2] / "Tests/ZynSignTests"
        self.assertTrue(set(evidence.TARGETS).issubset(evidence.source_allowlist(root)))

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
        self.assertEqual(evidence.test_results(data, {target})[target], "NOT VERIFIED")

    def test_conflicting_case_identities_cannot_report_pass_or_hide_a_duplicate(self):
        allowed = {"FooTests.testPass", "FooTests.testOther", "BarTests.testPass"}
        valid = {"nodeType": "Test Case", "name": "testPass()", "result": "Passed"}
        conflict = {"nodeType": "Test Case", "name": "testOther()", "result": "Passed",
                    "nodeIdentifier": "FooTests/testPass()"}
        data = {"testNodes": [{"nodeType": "Test Suite", "name": "FooTests",
                               "children": [valid, conflict]}]}
        self.assertEqual(evidence.test_results(data, allowed), {
            "FooTests.testPass": "NOT VERIFIED", "FooTests.testOther": "NOT VERIFIED"})
        conflict.update(name="testPass()", nodeIdentifier="BarTests/testPass()")
        self.assertEqual(evidence.test_results(data, allowed), {
            "FooTests.testPass": "NOT VERIFIED", "BarTests.testPass": "NOT VERIFIED"})

    def test_malformed_identifier_cannot_be_hidden_by_valid_duplicate(self):
        allowed = {"FooTests.testPass"}
        for malformed in (None, 7, "", "testPass()", [], {}):
            with self.subTest(identifier=malformed):
                valid = {"nodeType": "Test Case", "name": "testPass()", "result": "Passed"}
                bad = {**valid, "nodeIdentifier": malformed}
                data = {"testNodes": [{"nodeType": "Test Suite", "name": "FooTests",
                                       "children": [valid, bad]}]}
                self.assertEqual(evidence.test_results(data, allowed),
                                 {"FooTests.testPass": "NOT VERIFIED"})
                data["testNodes"][0]["children"] = [bad]
                self.assertEqual(evidence.test_results(data, allowed),
                                 {"FooTests.testPass": "NOT VERIFIED"})

    def test_malformed_case_children_are_not_verified(self):
        data = tree(("testPass", "Passed"))
        data["testNodes"][0]["children"][0]["children"] = "unknown schema"
        self.assertEqual(evidence.test_results(data, {"FooTests.testPass"}),
                         {"FooTests.testPass": "NOT VERIFIED"})

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
