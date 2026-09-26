import XCTest
@testable import ZynSign

/// Tests for the identity recommendation engine: the scoring signals, the
/// exclusions, and the rule that a recommendation is always a proposal —
/// a value, never an action.
final class IdentityRecommendationTests: XCTestCase {

    private let recommender = IdentityRecommender()
    private let referenceDate = IdentityCenterFixtures.referenceDate
    private let bundleID = "com.example.app"
    private let wildcardPatterns = ["TEAMABC123.com.example.*"]

    private func history(
        fingerprintHex: String,
        bundleIdentifier: String?,
        succeeded: Bool
    ) -> IdentityHistoryFact {
        IdentityHistoryFact(
            certificateFingerprintHex: fingerprintHex,
            bundleIdentifier: bundleIdentifier,
            applicationName: nil,
            teamIdentifier: "TEAMABC123",
            succeeded: succeeded,
            startedAt: referenceDate.addingTimeInterval(-86_400)
        )
    }

    func testPreviousSuccessRanksTheCertificateThatSignedTheApp() {
        let used = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 1)
        )
        let unused = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 2)
        )
        let profile = IdentityCenterFixtures.profileFacts(
            bundleIdentifierPatterns: wildcardPatterns
        )
        let records = [
            history(fingerprintHex: used.fingerprintHex, bundleIdentifier: bundleID, succeeded: true),
        ]

        let recommendation = recommender.recommend(
            bundleIdentifier: bundleID,
            certificates: [unused, used],
            profiles: [profile],
            history: records,
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertEqual(recommendation?.certificateFingerprintHex, used.fingerprintHex)
        XCTAssertTrue(recommendation?.reasons.contains(.previousSuccess) == true)
        XCTAssertEqual(recommendation?.profileID, profile.id)
    }

    func testFailedRunsNeverEarnPreviousSuccess() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 3)
        )
        let profile = IdentityCenterFixtures.profileFacts(
            bundleIdentifierPatterns: wildcardPatterns
        )
        let records = [
            history(fingerprintHex: certificate.fingerprintHex, bundleIdentifier: bundleID, succeeded: false),
        ]

        let recommendation = recommender.recommend(
            bundleIdentifier: bundleID,
            certificates: [certificate],
            profiles: [profile],
            history: records,
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertTrue(recommendation?.reasons.contains(.previousSuccess) == false)
    }

    func testUnusableCertificateIsExcluded() {
        let broken = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 4),
            keyAvailability: .unavailable,
            isUsableForSigning: false
        )
        let healthy = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 5)
        )
        let profile = IdentityCenterFixtures.profileFacts(
            bundleIdentifierPatterns: wildcardPatterns
        )

        let recommendation = recommender.recommend(
            bundleIdentifier: bundleID,
            certificates: [broken, healthy],
            profiles: [profile],
            history: [],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertEqual(recommendation?.certificateFingerprintHex, healthy.fingerprintHex)
    }

    func testNonCoveringProfileIsExcludedAndNoRecommendationWithoutEligibleProfiles() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 6)
        )
        let wrongProfile = IdentityCenterFixtures.profileFacts(
            name: "Wrong App",
            bundleIdentifierPatterns: ["TEAMABC123.com.other.*"]
        )

        let recommendation = recommender.recommend(
            bundleIdentifier: bundleID,
            certificates: [certificate],
            profiles: [wrongProfile],
            history: [],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertNil(recommendation)
    }

    func testExpiredProfileIsExcluded() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 7)
        )
        let expired = IdentityCenterFixtures.profileFacts(
            name: "Expired",
            expiresAt: referenceDate.addingTimeInterval(-86_400),
            bundleIdentifierPatterns: wildcardPatterns
        )

        let recommendation = recommender.recommend(
            bundleIdentifier: bundleID,
            certificates: [certificate],
            profiles: [expired],
            history: [],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertNil(recommendation)
    }

    func testAppStoreProfilesAreNeverRecommended() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 8)
        )
        let appStoreProfile = IdentityCenterFixtures.profileFacts(
            name: "App Store",
            profileType: .appStore,
            bundleIdentifierPatterns: wildcardPatterns
        )

        let recommendation = recommender.recommend(
            bundleIdentifier: bundleID,
            certificates: [certificate],
            profiles: [appStoreProfile],
            history: [],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertNil(recommendation)
    }

    func testTeamMatchBeatsTeamlessProfile() {
        let matching = IdentityCenterFixtures.profileFacts(
            name: "Matching Team",
            teamID: "TEAMABC123",
            bundleIdentifierPatterns: wildcardPatterns
        )
        let teamless = IdentityCenterFixtures.profileFacts(
            name: "Teamless",
            teamID: nil,
            bundleIdentifierPatterns: wildcardPatterns
        )
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 9)
        )

        let recommendation = recommender.recommend(
            bundleIdentifier: bundleID,
            certificates: [certificate],
            profiles: [teamless, matching],
            history: [],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertEqual(recommendation?.profileID, matching.id)
        XCTAssertTrue(recommendation?.reasons.contains(.teamMatch) == true)
    }

    func testDefaultIdentityEarnsTheMark() {
        let defaultCertificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 10),
            isDefault: true
        )
        let other = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 11)
        )
        let profile = IdentityCenterFixtures.profileFacts(
            bundleIdentifierPatterns: wildcardPatterns
        )

        let recommendation = recommender.recommend(
            bundleIdentifier: bundleID,
            certificates: [other, defaultCertificate],
            profiles: [profile],
            history: [],
            defaultFingerprintHex: defaultCertificate.fingerprintHex,
            referenceDate: referenceDate
        )

        // Both are otherwise equal; the default mark decides, and both
        // facts carry it consistently.
        XCTAssertEqual(recommendation?.certificateFingerprintHex, defaultCertificate.fingerprintHex)
        XCTAssertTrue(recommendation?.reasons.contains(.defaultIdentity) == true)
    }

    func testNoApplicationInContextRecommendsOnIdentityQuality() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 12)
        )

        let recommendation = recommender.recommend(
            bundleIdentifier: nil,
            certificates: [certificate],
            profiles: [],
            history: [],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertNotNil(recommendation)
        XCTAssertNil(recommendation?.profileID)
    }

    func testReasonsAreOrderedStrongestFirst() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 13),
            teamID: "TEAMABC123"
        )
        let profile = IdentityCenterFixtures.profileFacts(
            name: "Exact",
            teamID: "TEAMABC123",
            bundleIdentifier: nil,
            bundleIdentifierPatterns: wildcardPatterns
        )
        let records = [
            history(fingerprintHex: certificate.fingerprintHex, bundleIdentifier: bundleID, succeeded: true),
        ]

        let recommendation = recommender.recommend(
            bundleIdentifier: bundleID,
            certificates: [certificate],
            profiles: [profile],
            history: records,
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertEqual(recommendation?.reasons.first, .previousSuccess)
        XCTAssertTrue(recommendation?.reasons.contains(.usableKey) == true)
        XCTAssertTrue(recommendation?.reasons.contains(.profileCompatible) == true)
    }
}
