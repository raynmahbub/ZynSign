import XCTest
@testable import ZynSign

/// Tests for the analytics policy: off-device measurement is disabled on
/// every path, the guarantees are typed and complete, and the local journal
/// preference reads and defaults honestly.
final class AnalyticsPolicyTests: XCTestCase {

    // MARK: - Measurement

    func testMeasurementIsDisabledOnEveryPath() {
        XCTAssertFalse(AnalyticsPolicy.isEnabled)
        XCTAssertEqual(AnalyticsPolicy.eventCount, 0)
        XCTAssertNil(AnalyticsPolicy.endpoint)
    }

    func testSummaryStatesNothingIsTransmitted() {
        XCTAssertTrue(AnalyticsPolicy.summary.contains("disabled"))
        XCTAssertTrue(AnalyticsPolicy.summary.contains("never transmitted"))
    }

    func testGuaranteesAreCompleteAndTyped() {
        let guarantees = AnalyticsPolicy.guarantees
        XCTAssertEqual(guarantees.count, 6)
        XCTAssertTrue(guarantees.contains(.noAnalyticsKit))
        XCTAssertTrue(guarantees.contains(.noTelemetryTransmission))
        XCTAssertTrue(guarantees.contains(.noCrashReporterSDK))
        XCTAssertTrue(guarantees.contains(.noOutboundEndpoint))
        XCTAssertTrue(guarantees.contains(.noIdentifierCollection))
        XCTAssertTrue(guarantees.contains(.localJournalOnly))
        for guarantee in guarantees {
            XCTAssertFalse(guarantee.message.isEmpty)
        }
    }

    func testEveryGuaranteeDeniesSomethingConcrete() {
        for guarantee in AnalyticsPolicy.guarantees {
            let denies =
                guarantee.message.contains("No ")
                || guarantee.message.contains("not ")
                || guarantee.message.contains("never ")
            XCTAssertTrue(denies, "Guarantee text must deny something concrete: \(guarantee.message)")
        }
    }

    // MARK: - Journal preference

    func testJournalDefaultsToEnabledWhenUnset() {
        UserDefaults.standard.removeObject(forKey: AnalyticsPolicy.journalDefaultsKey)
        XCTAssertTrue(AnalyticsPolicy.isJournalEnabled)
    }

    func testJournalPreferenceWinsOverTheDefault() {
        let original = UserDefaults.standard.object(forKey: AnalyticsPolicy.journalDefaultsKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: AnalyticsPolicy.journalDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AnalyticsPolicy.journalDefaultsKey)
            }
        }
        UserDefaults.standard.set(false, forKey: AnalyticsPolicy.journalDefaultsKey)
        XCTAssertFalse(AnalyticsPolicy.isJournalEnabled)
        UserDefaults.standard.set(true, forKey: AnalyticsPolicy.journalDefaultsKey)
        XCTAssertTrue(AnalyticsPolicy.isJournalEnabled)
    }

    func testPolicyConstantsAreSane() {
        XCTAssertFalse(AnalyticsPolicy.journalDefaultsKey.isEmpty)
        XCTAssertGreaterThanOrEqual(AnalyticsPolicy.journalCapacity, 100)
    }

    // MARK: - Assessment

    func testAssessmentReflectsPolicyAndPreference() {
        UserDefaults.standard.removeObject(forKey: AnalyticsPolicy.journalDefaultsKey)
        let assessment = AnalyticsPolicy.assess()
        XCTAssertFalse(assessment.isEnabled)
        XCTAssertEqual(assessment.eventCount, 0)
        XCTAssertTrue(assessment.journalEnabled)
        XCTAssertEqual(assessment.guarantees, AnalyticsPolicy.guarantees)
        XCTAssertEqual(assessment.summary, AnalyticsPolicy.summary)
    }

    func testAssessmentIsEquatable() {
        UserDefaults.standard.removeObject(forKey: AnalyticsPolicy.journalDefaultsKey)
        XCTAssertEqual(AnalyticsPolicy.assess(), AnalyticsPolicy.assess())
    }
}
