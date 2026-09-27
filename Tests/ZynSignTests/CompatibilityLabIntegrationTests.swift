import XCTest
@testable import ZynSign

/// The Lab as a whole: that a run completes, covers every area, settles what
/// it can settle, and leaves nothing behind.
///
/// The run composes no application environment, so every check that needs one
/// reports not run rather than failing. That is the behaviour under test as
/// much as the run itself: a Lab that quietly turned "I could not ask" into a
/// pass would be worse than no Lab.
@MainActor
final class CompatibilityLabIntegrationTests: XCTestCase {

    private var scratchRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignTests-LabRun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchRoot { try? FileManager.default.removeItem(at: scratchRoot) }
        try super.tearDownWithError()
    }

    func testARunProducesACheckInEveryReportedCategory() async {
        let lab = CompatibilityLab()
        await lab.run()
        guard let report = lab.report else { return XCTFail("No report was produced") }
        for category in CompatibilityCategory.reported {
            XCTAssertFalse(
                report.checks(in: category).isEmpty,
                "\(category.displayName) produced no checks"
            )
        }
    }

    func testARunHoldsTheChecksTheEnvironmentAllows() async {
        let lab = CompatibilityLab()
        await lab.run()
        guard let report = lab.report else { return XCTFail("No report was produced") }
        for check in report.checks {
            XCTAssertFalse(check.summary.isEmpty, check.id)
            XCTAssertFalse(check.verified.isEmpty, check.id)
            if check.status == .failed {
                XCTAssertNotNil(check.nextStep, "\(check.id) failed and says nothing to do next")
            }
        }
    }

    func testARunLeavesNoFilesInItsScratchDirectory() async {
        let lab = CompatibilityLab()
        await lab.run()
        let labRoot = CompositionRoot.signingWorkspaceRoot()
            .appendingPathComponent("CompatibilityLab", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: labRoot.path),
            "The Lab left its scratch directory behind"
        )
    }

    func testARunSaysWhatItDoesNotClaim() async {
        let lab = CompatibilityLab()
        await lab.run()
        guard let report = lab.report else { return XCTFail("No report was produced") }
        XCTAssertFalse(report.notes.isEmpty)
        XCTAssertTrue(report.notes.contains { $0.contains("Not run") })
        XCTAssertFalse(report.deviceModel.isEmpty)
        XCTAssertEqual(report.releaseStage, ReleaseTrain.current.tag)
    }

    func testARunFillsTheChecklistAndTheVerdict() async {
        let lab = CompatibilityLab()
        await lab.run()
        XCTAssertEqual(lab.checklist.count, QAReleaseChecklist.items.count)
        XCTAssertNotNil(lab.verdict)
    }

    func testARunCanBeExportedAsText() async {
        let lab = CompatibilityLab()
        await lab.run()
        let text = lab.reportText()
        XCTAssertTrue(text.contains("ZynSign Compatibility Lab report"))
        for item in QAReleaseChecklist.items {
            XCTAssertTrue(text.contains(item.title), "The text report omits \(item.title)")
        }
    }

    // MARK: - Suites in isolation

    func testTheCrashResilienceSuiteSettlesEveryCase() async {
        let checks = await CrashResilienceSuite().checks(context: context())
        XCTAssertEqual(checks.count, 4)
        for check in checks {
            XCTAssertTrue(check.status.isSettled, "\(check.id) did not settle: \(check.summary)")
            XCTAssertFalse(check.evidence.isEmpty, check.id)
        }
    }

    func testTheResourceResilienceSuiteRefusesACopyThatCannotFit() async {
        let checks = await ResourceResilienceSuite().checks(context: context())
        let refusal = checks.first { $0.id == "resource.lowStorage.refusal" }
        XCTAssertEqual(refusal?.status, .passed, "A copy that cannot fit must be refused before a byte is written")
    }

    func testTheAccessibilitySuiteHonoursSystemReduceMotion() async {
        let preferences = ZynSignPreferences.shippedDefault
        let context = CompatibilityLabContext(scratchRoot: scratchRoot, preferences: preferences)
        let checks = AccessibilityAuditSuite().checks(context: context)
        let reduceMotion = checks.first { $0.id == "accessibility.reduceMotion" }
        XCTAssertEqual(reduceMotion?.status, .passed)
        // The rows only a human can judge must say so rather than pass.
        for identifier in ["accessibility.voiceOver", "accessibility.contrast"] {
            let check = checks.first { $0.id == identifier }
            XCTAssertEqual(check?.status, .notRun, identifier)
            XCTAssertNotNil(check?.nextStep, identifier)
        }
    }

    func testTheRegressionSuiteExecutesTheInvariantsItCan() async {
        let checks = await RegressionSuite().checks(context: context())
        for check in checks {
            XCTAssertFalse(check.summary.isEmpty, check.id)
            XCTAssertFalse(check.verified.isEmpty, check.id)
        }
        let executable = RegressionCoverageCatalog.executable.map(\.checkID)
        for identifier in executable {
            let check = checks.first { $0.id == identifier }
            XCTAssertEqual(check?.status, .passed, "\(identifier) no longer holds: \(check?.summary ?? "")")
        }
    }

    // MARK: - Support

    private func context() -> CompatibilityLabContext {
        CompatibilityLabContext(scratchRoot: scratchRoot)
    }
}
