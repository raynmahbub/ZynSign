import XCTest
@testable import ZynSign

/// Tests for the Identity Health engine: the checks each subject earns,
/// how warnings and blockers fold into the overall status, the
/// not-applicable rules, and the spoken summaries.
final class IdentityHealthCenterTests: XCTestCase {

    private let engine = IdentityHealthEngine()

    // MARK: - Certificates

    func testHealthyCertificateWithLinkedProfilePassesEveryConclusiveCheck() {
        let profile = IdentityCenterFixtures.profileFacts(
            name: "Matching Profile",
            teamID: "TEAMABC123",
            certificateFingerprints: [IdentityCenterFixtures.fingerprintHex(seed: 0xA1)]
        )
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 0xA1)
        )
        let report = engine.assessCertificate(
            certificate,
            linkedProfiles: [profile],
            compatibleAppCounts: [profile.id: 2],
            referenceDate: IdentityCenterFixtures.referenceDate
        )

        XCTAssertEqual(report.status, .healthy)
        XCTAssertEqual(report.checks.filter { $0.outcome == .pass }.count, report.checks.count)
        XCTAssertEqual(
            report.checks.map(\.kind),
            [.certificateValid, .keyAvailable, .expiration, .teamMatch, .profileValid, .bundleCompatible]
        )
        XCTAssertTrue(report.spokenSummary.contains("Healthy"))
    }

    func testExpiredCertificateIsBlocked() {
        let expired = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 0xB1),
            expiration: CertificateExpirationAssessment.assess(
                notValidBefore: TestClocks.utc(2020, 1, 1),
                notValidAfter: TestClocks.utc(2021, 1, 1),
                at: IdentityCenterFixtures.referenceDate
            ),
            keyAvailability: .available,
            isUsableForSigning: false
        )

        let report = engine.assessCertificate(
            expired,
            linkedProfiles: [],
            compatibleAppCounts: [:],
            referenceDate: IdentityCenterFixtures.referenceDate
        )

        XCTAssertEqual(report.status, .blocked)
        XCTAssertEqual(report.checks.first { $0.kind == .certificateValid }?.outcome, .blocked)
        XCTAssertEqual(report.checks.first { $0.kind == .expiration }?.outcome, .blocked)
    }

    func testUnavailableKeyBlocksAndUnknownKeyWarns() {
        let unavailable = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 0xC1),
            keyAvailability: .unavailable,
            isUsableForSigning: false
        )
        let blocked = engine.assessCertificate(
            unavailable,
            linkedProfiles: [],
            compatibleAppCounts: [:],
            referenceDate: IdentityCenterFixtures.referenceDate
        )
        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertEqual(blocked.checks.first { $0.kind == .keyAvailable }?.outcome, .blocked)

        let unknown = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 0xC2),
            keyAvailability: .unknown,
            isUsableForSigning: false
        )
        let warned = engine.assessCertificate(
            unknown,
            linkedProfiles: [],
            compatibleAppCounts: [:],
            referenceDate: IdentityCenterFixtures.referenceDate
        )
        XCTAssertEqual(warned.status, .warning)
        XCTAssertEqual(warned.checks.first { $0.kind == .keyAvailable }?.outcome, .warning)
    }

    func testExpiringCertificateWarnsOnlyOnExpiration() {
        let expiring = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 0xD1),
            expiration: CertificateExpirationAssessment.assess(
                notValidBefore: TestClocks.utc(2026, 1, 1),
                notValidAfter: TestClocks.utc(2026, 10, 20),
                at: IdentityCenterFixtures.referenceDate
            )
        )

        let report = engine.assessCertificate(
            expiring,
            linkedProfiles: [],
            compatibleAppCounts: [:],
            referenceDate: IdentityCenterFixtures.referenceDate
        )

        XCTAssertEqual(report.status, .warning)
        XCTAssertEqual(report.checks.first { $0.kind == .certificateValid }?.outcome, .pass)
        XCTAssertEqual(report.checks.first { $0.kind == .expiration }?.outcome, .warning)
    }

    func testTeamMismatchBlocksAndMissingProfileWarns() {
        let mismatchedProfile = IdentityCenterFixtures.profileFacts(
            name: "Other Team Profile",
            teamID: "TEAMXYZ789"
        )
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 0xE1),
            teamID: "TEAMABC123"
        )

        let report = engine.assessCertificate(
            certificate,
            linkedProfiles: [mismatchedProfile],
            compatibleAppCounts: [mismatchedProfile.id: 0],
            referenceDate: IdentityCenterFixtures.referenceDate
        )

        XCTAssertEqual(report.checks.first { $0.kind == .teamMatch }?.outcome, .blocked)
        XCTAssertEqual(report.checks.first { $0.kind == .bundleCompatible }?.outcome, .warning)
        XCTAssertEqual(report.status, .blocked)
    }

    func testNoLinkedProfilesWarnsAndReportsTeamAsNotApplicable() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 0xF1)
        )

        let report = engine.assessCertificate(
            certificate,
            linkedProfiles: [],
            compatibleAppCounts: [:],
            referenceDate: IdentityCenterFixtures.referenceDate
        )

        XCTAssertEqual(report.checks.first { $0.kind == .profileValid }?.outcome, .warning)
        XCTAssertEqual(report.checks.first { $0.kind == .teamMatch }?.outcome, .notApplicable)
        XCTAssertEqual(report.status, .warning)
    }

    func testNotYetValidCertificateHasNoRemainingDays() {
        let future = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 0xF2),
            expiration: CertificateExpirationAssessment.assess(
                notValidBefore: TestClocks.utc(2027, 1, 1),
                notValidAfter: TestClocks.utc(2028, 1, 1),
                at: IdentityCenterFixtures.referenceDate
            )
        )
        XCTAssertNil(future.expiration.remainingDays)

        let report = engine.assessCertificate(
            future,
            linkedProfiles: [],
            compatibleAppCounts: [:],
            referenceDate: IdentityCenterFixtures.referenceDate
        )
        XCTAssertEqual(report.status, .blocked)
    }

    // MARK: - Profiles

    func testHealthyProfilePasses() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 0xA1)
        )
        let profile = IdentityCenterFixtures.profileFacts(
            name: "Good Profile",
            teamID: "TEAMABC123",
            certificateFingerprints: [IdentityCenterFixtures.fingerprintHex(seed: 0xA1)]
        )

        let report = engine.assessProfile(
            profile,
            certificates: [certificate],
            compatibleAppCount: 3,
            referenceDate: IdentityCenterFixtures.referenceDate
        )

        XCTAssertEqual(report.status, .healthy)
        XCTAssertEqual(report.checks.first { $0.kind == .bundleCompatible }?.outcome, .pass)
        XCTAssertEqual(report.checks.first { $0.kind == .certificateValid }?.outcome, .pass)
    }

    func testExpiredProfileIsBlocked() {
        let profile = IdentityCenterFixtures.profileFacts(
            name: "Old Profile",
            expiresAt: TestClocks.utc(2026, 9, 1)
        )

        let report = engine.assessProfile(
            profile,
            certificates: [],
            compatibleAppCount: 1,
            referenceDate: IdentityCenterFixtures.referenceDate
        )

        XCTAssertEqual(report.status, .blocked)
        XCTAssertEqual(report.checks.first { $0.kind == .profileValid }?.outcome, .blocked)
        XCTAssertEqual(report.checks.first { $0.kind == .expiration }?.outcome, .blocked)
    }

    func testOrphanedProfileCertificatesBlock() {
        let profile = IdentityCenterFixtures.profileFacts(
            name: "Orphan",
            certificateFingerprints: [IdentityCenterFixtures.fingerprintHex(seed: 0xEE)]
        )

        let report = engine.assessProfile(
            profile,
            certificates: [],
            compatibleAppCount: 0,
            referenceDate: IdentityCenterFixtures.referenceDate
        )

        XCTAssertEqual(report.checks.first { $0.kind == .certificateValid }?.outcome, .blocked)
        XCTAssertEqual(report.checks.first { $0.kind == .bundleCompatible }?.outcome, .warning)
        XCTAssertEqual(report.status, .blocked)
    }

    func testProfileWithNoDeclaredTeamReportsTeamCheckAsNotApplicable() {
        let profile = IdentityCenterFixtures.profileFacts(name: "No Team", teamID: nil, teamName: nil)

        let report = engine.assessProfile(
            profile,
            certificates: [],
            compatibleAppCount: nil,
            referenceDate: IdentityCenterFixtures.referenceDate
        )

        XCTAssertEqual(report.checks.first { $0.kind == .teamMatch }?.outcome, .notApplicable)
        XCTAssertEqual(report.checks.first { $0.kind == .bundleCompatible }?.outcome, .notApplicable)
    }

    // MARK: - Folding

    func testOverallStatusFoldsToTheWorstConclusiveCheck() {
        XCTAssertEqual(
            IdentityHealthStatus.combine(.healthy, .warning),
            .warning
        )
        XCTAssertEqual(
            IdentityHealthStatus.combine(.warning, .blocked),
            .blocked
        )
        XCTAssertEqual(
            IdentityHealthStatus.combine(.healthy, .healthy),
            .healthy
        )
    }

    func testSpokenSummaryCountsFindings() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 0xA1),
            keyAvailability: .unavailable,
            isUsableForSigning: false
        )
        let report = IdentityHealthEngine().assessCertificate(
            certificate,
            linkedProfiles: [],
            compatibleAppCounts: [:],
            referenceDate: IdentityCenterFixtures.referenceDate
        )
        XCTAssertTrue(report.spokenSummary.contains("blocked"))
    }
}
