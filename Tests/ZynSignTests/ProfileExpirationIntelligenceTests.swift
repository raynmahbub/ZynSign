import XCTest
@testable import ZynSign

/// Expiration intelligence: the three states, the 30-day threshold, the
/// day counts, and the countdown wording the manager's badges show.
final class ProfileExpirationIntelligenceTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func assessment(expiringIn days: Int) -> ProfileExpirationAssessment {
        ProfileExpirationAssessment(
            expirationDate: referenceDate.addingTimeInterval(Double(days) * 86400),
            referenceDate: referenceDate
        )
    }

    func testHealthyBeyondThreshold() {
        let assessment = assessment(expiringIn: 31)
        XCTAssertEqual(assessment.state, .healthy)
        XCTAssertEqual(assessment.daysRemaining, 31)
        XCTAssertEqual(assessment.countdownText, "31 days left")
    }

    func testExpiringSoonAtThreshold() {
        let assessment = assessment(expiringIn: 30)
        XCTAssertEqual(assessment.state, .expiringSoon)
        XCTAssertEqual(assessment.daysRemaining, 30)
        XCTAssertEqual(assessment.countdownText, "30 days left")
    }

    func testExpiredAtOrPastExpiration() {
        let atExpiration = ProfileExpirationAssessment(
            expirationDate: referenceDate,
            referenceDate: referenceDate
        )
        XCTAssertEqual(atExpiration.state, .expired)

        let past = assessment(expiringIn: -12)
        XCTAssertEqual(past.state, .expired)
        XCTAssertEqual(past.daysRemaining, -12)
        XCTAssertEqual(past.countdownText, "Expired 12 days ago")
    }

    func testExpiredTodayWording() {
        let justPast = ProfileExpirationAssessment(
            expirationDate: referenceDate.addingTimeInterval(-3600),
            referenceDate: referenceDate
        )
        XCTAssertEqual(justPast.state, .expired)
        XCTAssertEqual(justPast.daysRemaining, 0)
        XCTAssertEqual(justPast.countdownText, "Expired today")
    }

    func testSummaryAssessmentAgreesWithSummaryHelpers() {
        let summary = makeSummary(expirationDate: referenceDate.addingTimeInterval(10 * 86400))
        let assessment = summary.expirationAssessment(referenceDate: referenceDate)
        XCTAssertEqual(assessment.state, .expiringSoon)
        XCTAssertFalse(summary.isExpired(referenceDate: referenceDate))
        XCTAssertEqual(
            assessment.daysRemaining,
            summary.daysUntilExpiration(referenceDate: referenceDate)
        )
    }

    func testExpiredSummaryAssessmentMatchesIsExpired() {
        let summary = makeSummary(expirationDate: referenceDate.addingTimeInterval(-3 * 86400))
        XCTAssertTrue(summary.isExpired(referenceDate: referenceDate))
        XCTAssertEqual(
            summary.expirationAssessment(referenceDate: referenceDate).state,
            .expired
        )
    }

    func testEveryStateHasADistinctDisplayNameAndSymbol() {
        let names = ProfileExpirationState.allCases.map(\.displayName)
        let symbols = ProfileExpirationState.allCases.map(\.systemImage)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(Set(symbols).count, symbols.count)
    }

    private func makeSummary(expirationDate: Date) -> ProvisioningProfileSummary {
        ProvisioningProfileSummary(
            name: "Synthetic",
            teamIdentifier: "TEAM123456",
            bundleIdentifierPatterns: ["com.example.synthetic"],
            expirationDate: expirationDate,
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "sample.mobileprovision",
            importedAt: referenceDate
        )
    }
}
