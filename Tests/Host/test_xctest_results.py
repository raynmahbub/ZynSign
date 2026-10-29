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
        self.assertEqual(evidence.test_results(data, {target}), {target: "NOT VERIFIED"})

    def test_conflicting_names_and_duplicate_suite_are_not_verified(self):
        allowed = {"FooTests.testA", "FooTests.testB", "OtherTests.testA"}
        conflict = {"nodeType": "Test Case", "name": "testB()",
                    "nodeIdentifier": "FooTests/testA()", "result": "Passed"}
        data = {"testNodes": [{"nodeType": "Test Suite", "name": "FooTests", "children": [conflict]}]}
        self.assertEqual(evidence.test_results(data, allowed), {
            "FooTests.testA": "NOT VERIFIED", "FooTests.testB": "NOT VERIFIED"})
        passed = {"nodeType": "Test Case", "name": "testA()",
                  "nodeIdentifier": "FooTests/testA()", "result": "Passed"}
        failed = {**passed, "result": "Failed"}
        data = {"testNodes": [
            {"nodeType": "Test Suite", "name": "FooTests", "children": [passed]},
            {"nodeType": "Test Suite", "name": "OtherTests", "children": [failed]},
        ]}
        self.assertEqual(evidence.test_results(data, allowed), {
            "FooTests.testA": "NOT VERIFIED", "OtherTests.testA": "NOT VERIFIED"})
        # Invalid identifiers must not make an otherwise identifiable case pass.
        passed["nodeIdentifier"] = 5
        self.assertEqual(evidence.test_results(data, allowed)["FooTests.testA"], "NOT VERIFIED")

    def test_unrecognized_suite_and_explicit_invalid_identity_fail_closed(self):
        allowed = {"FooTests.testA"}
        case = {"nodeType": "Test Case", "name": "testA()",
                "nodeIdentifier": "FooTests/testA()", "result": "Passed"}

        def result(suite, item):
            nodes = [{"nodeType": "Test Suite", "name": suite, "children": [item]}]
            return evidence.test_results({"testNodes": nodes}, allowed)

        # A non-*Tests suite still carries identity and must not be discarded.
        self.assertEqual(result("OtherSuite", case), {"FooTests.testA": "NOT VERIFIED"})
        self.assertEqual(result(None, case), {"FooTests.testA": "NOT VERIFIED"})
        for identifier in (None, 7, "bad", "OtherTests/testA()"):
            with self.subTest(identifier=identifier):
                self.assertEqual(result("FooTests", {**case, "nodeIdentifier": identifier}),
                                 {"FooTests.testA": "NOT VERIFIED"})
        self.assertEqual(result("FooTests", {**case, "name": None}),
                         {"FooTests.testA": "NOT VERIFIED"})
        # The supported tree with a matching identifier, and the existing
        # suite/name form with no identifier field, remain usable.
        self.assertEqual(result("FooTests", case), {"FooTests.testA": "PASS"})
        without_id = {key: value for key, value in case.items() if key != "nodeIdentifier"}
        self.assertEqual(result("FooTests", without_id), {"FooTests.testA": "PASS"})
        data = {"testNodes": [
            {"nodeType": "Test Suite", "name": "FooTests", "children": [case]},
            {"nodeType": "Test Suite", "name": "OtherSuite", "children": [{**case, "result": "Failed"}]},
        ]}
        self.assertEqual(evidence.test_results(data, allowed), {"FooTests.testA": "NOT VERIFIED"})

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

    def test_markdown_renders_all_recognized_cases_in_sorted_order(self):
        data = tree(("testZ", "Passed"), ("testA", "Failed"), ("testSkip", "Skipped"),
                    ("testRepeat", "Passed"), ("testRepeat", "Failed"), ("testUnknown", "Running"))
        allowed = {f"FooTests.test{x}" for x in ("Z", "A", "Skip", "Repeat", "Unknown")}
        summary = {"passedTests": 1, "failedTests": 1, "skippedTests": 1, "totalTestCount": 3}
        report = evidence.create_report(data, summary, allowed)
        md = evidence.markdown(report)
        self.assertIn("Aggregate: 1 passed, 1 failed, 1 skipped, 3 total", md)
        self.assertIn("### Recognized per-test results", md)
        self.assertIn("| `FooTests.testA` | FAIL |", md)
        self.assertIn("| `FooTests.testSkip` | SKIPPED |", md)
        self.assertIn("| `FooTests.testZ` | PASS |", md)
        self.assertIn("| `FooTests.testRepeat` | NOT VERIFIED |", md)
        self.assertIn("| `FooTests.testUnknown` | NOT VERIFIED |", md)
        self.assertLess(md.index("`FooTests.testA`"), md.index("`FooTests.testZ`"))
        for target in evidence.TARGETS:
            self.assertIn(f"| `{target}` | NOT VERIFIED |", md)
        self.assertNotIn("Truncated:", md)
        self.assertEqual(md, evidence.markdown(report))

    def test_markdown_truncates_at_byte_limit_without_altering_json(self):
        report = evidence.create_report({}, {}, set())
        report["tests"] = {f"FooTests.testCase{i:04d}": "PASS" for i in range(200)}
        original_json = json.dumps(report, sort_keys=True)
        md = evidence.markdown(report, max_bytes=1400)
        self.assertLessEqual(len(md.encode("utf-8")), 1400)
        self.assertIn("Truncated:", md)
        self.assertIn("xctest-results.json", md)
        self.assertIn("full sanitized report", md)
        self.assertIn("| `FooTests.testCase0000` | PASS |", md)
        self.assertNotIn("`FooTests.testCase0199`", md)
        self.assertEqual(json.dumps(report, sort_keys=True), original_json)
        self.assertEqual(len(report["tests"]), 200)

    def test_markdown_exact_fit_truncation_and_utf8_boundaries(self):
        report = evidence.create_report({}, {}, set())
        report["limitations"] += " Café — 模拟器"
        report["tests"] = {f"FooTests.testCase{i:04d}": "PASS" for i in range(100)}
        full = evidence.markdown(report)
        full_size = len(full.encode("utf-8"))
        self.assertGreater(full_size, len(full))
        self.assertEqual(evidence.markdown(report, max_bytes=full_size), full)
        shortened = evidence.markdown(report, max_bytes=full_size - 1)
        self.assertLessEqual(len(shortened.encode("utf-8")), full_size - 1)
        self.assertIn("Truncated:", shortened)
        # Find the first byte limit that can include the fixed prefix and
        # notice, and verify both sides of that exact boundary.
        low, high = 0, full_size - 1
        while low < high:
            middle = (low + high) // 2
            try:
                evidence.markdown(report, max_bytes=middle)
                high = middle
            except ValueError:
                low = middle + 1
        with self.assertRaises(ValueError):
            evidence.markdown(report, max_bytes=low - 1)
        boundary = evidence.markdown(report, max_bytes=low)
        self.assertLessEqual(len(boundary.encode("utf-8")), low)
        self.assertIn("Truncated:", boundary)
        self.assertIn("xctest-results.json", boundary)

    def test_markdown_rejects_unsafe_names_and_unknown_statuses(self):
        report = evidence.create_report({}, {}, set())
        report["tests"] = {"FooTests.testGood": "invented", "FooTests.testUnsafe|secret": "PASS",
                           "FooTests.testNewline\n::error::secret": "PASS"}
        md = evidence.markdown(report)
        self.assertIn("| `FooTests.testGood` | NOT VERIFIED |", md)
        self.assertNotIn("secret", md.lower())
        self.assertNotIn("invented", md)

    def test_counts_require_unambiguous_top_level_numbers(self):
        good = {"passedTests": 2, "failedTests": 1, "skippedTests": 1, "totalTestCount": 4}
        self.assertEqual(evidence.aggregate(good), good)
        for data in ({}, {"nested": good}, {**good, "totalTestCount": 3},
                     {**good, "passedTests": True}, {**good, "expectedFailures": 1}):
            with self.subTest(data=data):
                self.assertIsNone(evidence.aggregate(data))

    def test_contradictory_aggregate_is_not_verified(self):
        for raw, key in (("Passed", "passedTests"), ("Failed", "failedTests"),
                         ("Skipped", "skippedTests")):
            with self.subTest(status=raw):
                summary = {"passedTests": 0, "failedTests": 0, "skippedTests": 0, "totalTestCount": 0}
                report = evidence.create_report(tree(("testA", raw)), summary, {"FooTests.testA"})
                self.assertIsNone(report["counts"])
                self.assertEqual(report["tests"]["FooTests.testA"], evidence.STATUSES[raw.lower()])
                self.assertIn("inconsistent", report["limitations"])
                self.assertIn("Aggregate: NOT VERIFIED", evidence.markdown(report))
                self.assertEqual(summary[key], 0)  # Input totals are not modified.
        summary = {"passedTests": 2, "failedTests": 1, "skippedTests": 0, "totalTestCount": 3}
        report = evidence.create_report(tree(("testA", "Passed")), summary, {"FooTests.testA"})
        self.assertEqual(report["counts"], summary)  # Partial coverage is allowed.
        repeated = evidence.create_report(tree(("testA", "Passed"), ("testA", "Failed")),
                                          summary, {"FooTests.testA"})
        self.assertEqual(repeated["tests"]["FooTests.testA"], "NOT VERIFIED")
        self.assertEqual(repeated["counts"], summary)

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
