import XCTest
@testable import ZynSign

/// Tests for the expiration intelligence that classifies a certificate's
/// remaining validity: healthy, expiring soon, expired, and not yet valid.
final class CertificateExpirationTests: XCTestCase {

    /// The end of the valid fixture's period: 2027-09-22 18:14:30Z.
    private var notValidAfter: Date { TestClocks.utc(2027, 9, 22, hour: 18, minute: 14, second: 30) }

    /// The start of the valid fixture's period: 2026-09-22 18:14:30Z.
    private var notValidBefore: Date { TestClocks.utc(2026, 9, 22, hour: 18, minute: 14, second: 30) }

    private func assess(at date: Date, threshold: Int = 30) -> CertificateExpirationAssessment {
        CertificateExpirationAssessment.assess(
            notValidBefore: notValidBefore,
            notValidAfter: notValidAfter,
            at: date,
            warningThresholdDays: threshold
        )
    }

    func testHealthyWellInsideThePeriod() {
        let assessment = assess(at: TestClocks.utc(2026, 10, 1))
        XCTAssertEqual(assessment.status, .healthy)
        XCTAssertEqual(assessment.remainingDays, 356)
        XCTAssertTrue(assessment.isUsableAtEvaluationDate)
    }

    func testExpiringSoonAtTheThresholdBoundary() {
        // Exactly 30 days left: the threshold is inclusive.
        let assessment = assess(at: TestClocks.utc(2027, 8, 23, hour: 18, minute: 14, second: 30))
        XCTAssertEqual(assessment.status, .expiringSoon)
        XCTAssertEqual(assessment.remainingDays, 30)
        XCTAssertTrue(assessment.isUsableAtEvaluationDate)
    }

    func testHealthyJustPastTheThreshold() {
        let assessment = assess(at: TestClocks.utc(2027, 8, 22, hour: 18, minute: 14, second: 30))
        XCTAssertEqual(assessment.status, .healthy)
        XCTAssertEqual(assessment.remainingDays, 31)
    }

    func testCustomThresholdMovesTheBoundary() {
        // With a one-day threshold, 30 days left is still healthy.
        let assessment = assess(at: TestClocks.utc(2027, 8, 23, hour: 18, minute: 14, second: 30), threshold: 1)
        XCTAssertEqual(assessment.status, .healthy)
        XCTAssertEqual(assessment.remainingDays, 30)
    }

    func testFinalInstantOfValidityIsStillUsableWithZeroDaysRemaining() {
        let assessment = assess(at: notValidAfter)
        XCTAssertEqual(assessment.status, .expiringSoon)
        XCTAssertEqual(assessment.remainingDays, 0)
        XCTAssertTrue(assessment.isUsableAtEvaluationDate)
    }

    func testOneSecondPastExpiryIsExpiredWithZeroDaysAgo() {
        let assessment = assess(at: notValidAfter.addingTimeInterval(1))
        XCTAssertEqual(assessment.status, .expired)
        XCTAssertEqual(assessment.remainingDays, 0)
        XCTAssertFalse(assessment.isUsableAtEvaluationDate)
    }

    func testExpiredWholeDaysAgoCountCompleteDays() {
        let assessment = assess(at: notValidAfter.addingTimeInterval(2 * 86_400 + 60))
        XCTAssertEqual(assessment.status, .expired)
        XCTAssertEqual(assessment.remainingDays, -2)
    }

    func testNotYetValidBeforeTheStart() {
        let assessment = assess(at: notValidBefore.addingTimeInterval(-1))
        XCTAssertEqual(assessment.status, .notYetValid)
        XCTAssertNil(assessment.remainingDays)
        XCTAssertFalse(assessment.isUsableAtEvaluationDate)
    }

    func testFirstInstantOfValidityIsUsable() {
        let assessment = assess(at: notValidBefore)
        XCTAssertEqual(assessment.status, .healthy)
        XCTAssertEqual(assessment.remainingDays, 365)
    }

    func testFractionalDayTruncatesTowardZero() {
        // 29 days and 23 hours left is 29 days: the partial day is not a day.
        let assessment = assess(at: notValidAfter.addingTimeInterval(-(29 * 86_400 + 86_340)))
        XCTAssertEqual(assessment.status, .expiringSoon)
        XCTAssertEqual(assessment.remainingDays, 29)
    }

    func testMetadataAndClockConvenienceProduceTheSameAssessment() throws {
        let metadata = try AppleCertificateParser()
            .parseCertificate(derData: CertificateFixtures.validDER)
        let clock = FixedEvaluationClock(instant: TestClocks.utc(2026, 10, 1))
        let viaMetadata = CertificateExpirationAssessment.assess(certificate: metadata, clock: clock)
        let viaInterval = CertificateExpirationAssessment.assess(
            notValidBefore: metadata.notValidBefore,
            notValidAfter: metadata.notValidAfter,
            at: clock.now()
        )
        XCTAssertEqual(viaMetadata, viaInterval)
        XCTAssertEqual(viaMetadata.status, .healthy)
    }

    func testStatusDisplayNamesAreStable() {
        XCTAssertEqual(CertificateExpirationStatus.healthy.displayName, "Healthy")
        XCTAssertEqual(CertificateExpirationStatus.expiringSoon.displayName, "Expiring Soon")
        XCTAssertEqual(CertificateExpirationStatus.expired.displayName, "Expired")
        XCTAssertEqual(CertificateExpirationStatus.notYetValid.displayName, "Not Yet Valid")
    }
}
