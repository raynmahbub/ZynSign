import XCTest
@testable import ZynSign

/// Tests for the Expiration Forecast: the band thresholds, the
/// urgency-first ordering, and the horizon rule.
final class ExpirationForecastTests: XCTestCase {

    private let builder = ExpirationForecastBuilder()
    private let referenceDate = IdentityCenterFixtures.referenceDate

    private func expiringIn(days: Int, from reference: Date) -> Date {
        reference.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    func testBandThresholds() {
        XCTAssertEqual(ExpirationForecastBand.band(forDaysRemaining: -1), .expired)
        XCTAssertEqual(ExpirationForecastBand.band(forDaysRemaining: 0), .critical)
        XCTAssertEqual(ExpirationForecastBand.band(forDaysRemaining: 7), .critical)
        XCTAssertEqual(ExpirationForecastBand.band(forDaysRemaining: 8), .important)
        XCTAssertEqual(ExpirationForecastBand.band(forDaysRemaining: 14), .important)
        XCTAssertEqual(ExpirationForecastBand.band(forDaysRemaining: 15), .warning)
        XCTAssertEqual(ExpirationForecastBand.band(forDaysRemaining: 30), .warning)
        XCTAssertEqual(ExpirationForecastBand.band(forDaysRemaining: 31), .watch)
    }

    func testBandsSortMostUrgentFirst() {
        let soonest = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 1),
            displayName: "Soonest",
            notValidAfter: expiringIn(days: 3, from: referenceDate)
        )
        let later = IdentityCenterFixtures.profileFacts(
            name: "Later",
            expiresAt: expiringIn(days: 20, from: referenceDate)
        )
        let expired = IdentityCenterFixtures.profileFacts(
            name: "Expired",
            expiresAt: expiringIn(days: -5, from: referenceDate)
        )

        let entries = builder.build(
            certificates: [soonest],
            profiles: [later, expired],
            referenceDate: referenceDate
        )

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].band, .expired)
        XCTAssertEqual(entries[0].kind, .profile)
        XCTAssertEqual(entries[1].band, .critical)
        XCTAssertEqual(entries[1].kind, .certificate)
        XCTAssertEqual(entries[2].band, .warning)
    }

    func testHorizonExcludesFarExpirationsButKeepsExpired() {
        let within = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 2),
            displayName: "Within",
            notValidAfter: expiringIn(days: 10, from: referenceDate)
        )
        let beyond = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 3),
            displayName: "Beyond",
            notValidAfter: expiringIn(days: 200, from: referenceDate)
        )
        let expired = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 4),
            displayName: "Expired",
            expiration: CertificateExpirationAssessment.assess(
                notValidBefore: TestClocks.utc(2020, 1, 1),
                notValidAfter: TestClocks.utc(2021, 1, 1),
                at: referenceDate
            )
        )

        let entries = builder.build(
            certificates: [within, beyond, expired],
            profiles: [],
            referenceDate: referenceDate
        )

        XCTAssertEqual(entries.map(\.name), ["Expired", "Within"])
        XCTAssertFalse(entries.contains { $0.name == "Beyond" })
    }

    func testCountdownText() {
        let expired = ExpirationForecastEntry(
            kind: .profile,
            name: "Expired",
            teamID: nil,
            expirationDate: expiringIn(days: -2, from: referenceDate),
            daysRemaining: -2,
            subjectKey: "p1"
        )
        XCTAssertEqual(expired.countdownText, "Expired 2 days ago")

        let today = ExpirationForecastEntry(
            kind: .certificate,
            name: "Today",
            teamID: nil,
            expirationDate: referenceDate,
            daysRemaining: 0,
            subjectKey: "c1"
        )
        XCTAssertEqual(today.countdownText, "Expires today")

        let tomorrow = ExpirationForecastEntry(
            kind: .certificate,
            name: "Tomorrow",
            teamID: nil,
            expirationDate: expiringIn(days: 1, from: referenceDate),
            daysRemaining: 1,
            subjectKey: "c2"
        )
        XCTAssertEqual(tomorrow.countdownText, "1 day left")
    }

    func testEntryIdentifiersDistinguishKinds() {
        let certificate = ExpirationForecastEntry(
            kind: .certificate,
            name: "Same Key",
            teamID: nil,
            expirationDate: referenceDate,
            daysRemaining: 5,
            subjectKey: "shared"
        )
        let profile = ExpirationForecastEntry(
            kind: .profile,
            name: "Same Key",
            teamID: nil,
            expirationDate: referenceDate,
            daysRemaining: 5,
            subjectKey: "shared"
        )
        XCTAssertNotEqual(certificate.id, profile.id)
    }
}
