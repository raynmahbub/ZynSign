import XCTest
@testable import ZynSign

/// The report, the checklist and the release verdict: that a run's outcome is
/// reduced to a decision honestly.
final class CompatibilityLabReportTests: XCTestCase {

    // MARK: - Rollup

    func testACategoryRollsUpToItsWorstOutcome() {
        let report = Self.report(checks: [
            Self.check(id: "a", status: .passed),
            Self.check(id: "b", status: .warning),
            Self.check(id: "c", status: .passed)
        ])
        XCTAssertEqual(report.status(of: .signingPipeline), .warning)
    }

    func testACheckThatDidNotRunOutranksAPass() {
        // An unrun check is an open question, not a result: the rollup must
        // not let nine passes hide one check that never executed.
        let report = Self.report(checks: [
            Self.check(id: "a", status: .passed),
            Self.check(id: "b", status: .notRun)
        ])
        XCTAssertEqual(report.status(of: .signingPipeline), .notRun)
        XCTAssertFalse(report.isComplete)
    }

    func testACategoryWithNoChecksIsNotRun() {
        let report = Self.report(checks: [])
        XCTAssertEqual(report.status(of: .storeBrowser), .notRun)
    }

    func testTheDashboardKeepsItsSixRows() {
        let report = Self.report(checks: [Self.check(id: "a", status: .passed)])
        XCTAssertEqual(report.dashboardSummaries.count, CompatibilityCategory.dashboard.count)
        XCTAssertEqual(CompatibilityCategory.dashboard.count, 6)
        XCTAssertEqual(
            Set(report.categorySummaries.map(\.category)),
            Set(CompatibilityCategory.reported)
        )
    }

    // MARK: - Encoding

    func testAReportSurvivesItsOwnJSON() throws {
        let report = Self.report(checks: [Self.check(id: "a", status: .passed, summary: "ok")])
        let data = try report.jsonData()
        let decoded = try CompatibilityLabReport.decode(from: data)
        XCTAssertEqual(decoded, report)
        XCTAssertTrue(decoded.isReadableByThisBuild)
    }

    func testTheJSONIsDeterministic() throws {
        let report = Self.report(checks: [Self.check(id: "a", status: .passed)])
        XCTAssertEqual(try report.jsonData(), try report.jsonData())
    }

    // MARK: - Overlay

    func testAnOverlayFillsOnlyACheckThatDidNotRun() {
        let context = CompatibilityLabContext(
            scratchRoot: FileManager.default.temporaryDirectory,
            overlay: CompatibilityLabOverlay(source: "CI run 42", statuses: ["a": .passed, "b": .failed])
        )
        let unrun = context.applyingOverlay(to: Self.check(id: "a", status: .notRun))
        XCTAssertEqual(unrun.status, .passed)
        XCTAssertTrue(unrun.evidence.contains { $0.contains("CI run 42") })

        let measured = context.applyingOverlay(to: Self.check(id: "b", status: .passed))
        XCTAssertEqual(measured.status, .passed, "An overlay must never overturn a measurement")
    }

    // MARK: - Checklist

    func testAChecklistItemIsSettledByItsWorstCheck() {
        let report = Self.report(checks: [
            Self.check(id: "signing.scenario.simpleApplication", status: .passed),
            Self.check(id: "signing.scenario.largePackage", status: .failed)
        ])
        let results = QAReleaseChecklistEvaluator.items(report: report)
        let signing = results.first { $0.item.id == "signing" }
        XCTAssertEqual(signing?.status, .failed)
        XCTAssertNotNil(signing?.nextStep)
    }

    func testAChecklistItemWithNoChecksIsNotRun() {
        let report = Self.report(checks: [])
        let results = QAReleaseChecklistEvaluator.items(report: report)
        for result in results {
            XCTAssertEqual(result.status, .notRun, result.item.id)
            XCTAssertNotNil(result.nextStep, result.item.id)
        }
    }

    func testEveryChecklistItemNamesTheChecksThatSettleIt() {
        // An item whose identifiers match nothing would silently be a pass
        // forever; the evaluator reports it as not run instead.
        let report = Self.report(checks: Self.checksForEveryItem())
        let results = QAReleaseChecklistEvaluator.items(report: report)
        for result in results {
            XCTAssertFalse(
                result.evidence.isEmpty,
                "\(result.item.id) has no evidence: its check identifiers match nothing"
            )
        }
        XCTAssertEqual(results.count, QAReleaseChecklist.items.count)
    }

    // MARK: - Readiness

    func testACriticalFailureBlocksTheCandidate() {
        let report = Self.report(checks: [
            Self.check(id: "signing.scenario.simpleApplication", status: .failed, blocker: .critical)
        ])
        XCTAssertEqual(ReleaseReadinessEvaluator.verdict(for: report).readiness, .blocked)
    }

    func testAnUnrunCheckLeavesTheCandidateIncomplete() {
        let report = Self.report(checks: [
            Self.check(id: "accessibility.voiceOver", status: .notRun)
        ])
        let verdict = ReleaseReadinessEvaluator.verdict(for: report)
        XCTAssertEqual(verdict.readiness, .incomplete)
        XCTAssertEqual(verdict.unrunChecks.count, 1)
    }

    func testEveryCheckSettledAsAPassIsReady() {
        let report = Self.report(checks: Self.checksForEveryItem())
        XCTAssertEqual(ReleaseReadinessEvaluator.verdict(for: report).readiness, .ready)
    }

    // MARK: - Blocker policy

    func testOnlyACriticalBlocksTheCandidate() {
        XCTAssertTrue(ReleaseBlockerSeverity.critical.blocksReleaseCandidate)
        XCTAssertFalse(ReleaseBlockerSeverity.high.blocksReleaseCandidate)
        XCTAssertTrue(ReleaseBlockerSeverity.high.blocksNextCandidate)
        XCTAssertFalse(ReleaseBlockerSeverity.medium.blocksNextCandidate)
    }

    func testEveryTrackedLimitationNamesADisposition() {
        for record in ReleaseBlockerRecord.registry {
            XCTAssertFalse(record.disposition.isEmpty, record.id)
            XCTAssertFalse(record.title.isEmpty, record.id)
        }
        XCTAssertEqual(
            Set(ReleaseBlockerRecord.registry.map(\.id)).count,
            ReleaseBlockerRecord.registry.count
        )
    }

    // MARK: - Support

    private static func report(checks: [CompatibilityCheck]) -> CompatibilityLabReport {
        CompatibilityLabReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            releaseStage: "v1.0.0-rc1",
            marketingVersion: "1.0.0",
            buildVersion: "5",
            osVersion: "18.1",
            deviceModel: "not recorded",
            deviceClass: "Standard phone",
            checks: checks
        )
    }

    private static func check(
        id: String,
        status: CompatibilityStatus,
        category: CompatibilityCategory = .signingPipeline,
        summary: String = "summary",
        blocker: ReleaseBlockerSeverity? = nil
    ) -> CompatibilityCheck {
        CompatibilityCheck(
            id: id,
            category: category,
            title: id,
            status: status,
            summary: summary,
            verified: "verified",
            nextStep: status == .passed ? nil : "next",
            blocker: blocker
        )
    }

    /// One passing check per checklist item, so the readiness evaluation has
    /// something to settle for every line.
    private static func checksForEveryItem() -> [CompatibilityCheck] {
        QAReleaseChecklist.items.flatMap { item in
            item.checkIDs.map { reference in
                let identifier = reference.hasSuffix(".")
                    ? reference + "one"
                    : reference
                return check(id: identifier, status: .passed)
            }
        }
    }
}
