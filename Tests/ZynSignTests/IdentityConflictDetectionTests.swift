import XCTest
@testable import ZynSign

/// Tests for Smart Conflict Detection: each of the six rules, the
/// blocked-first ordering, and the identifiers' stability.
final class IdentityConflictDetectionTests: XCTestCase {

    private let detector = IdentityConflictDetector()
    private let referenceDate = IdentityCenterFixtures.referenceDate

    func testDuplicateCertificatesByTeamAndName() {
        let first = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 1),
            displayName: "Apple Development: Same Name"
        )
        let second = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 2),
            displayName: "Apple Development: Same Name"
        )
        let distinct = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 3),
            displayName: "Apple Development: Different"
        )

        let conflicts = detector.detect(
            certificates: [first, second, distinct],
            profiles: [],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        let duplicates = conflicts.filter { $0.kind == .duplicateCertificates }
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates[0].severity, .warning)
        XCTAssertEqual(
            Set(duplicates[0].certificateFingerprints),
            Set([first.fingerprintHex, second.fingerprintHex])
        )
    }

    func testMultipleMatchingCertificatesOnlyWithoutADefault() {
        let first = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 4)
        )
        let second = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 5)
        )

        let withoutDefault = detector.detect(
            certificates: [first, second],
            profiles: [],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )
        XCTAssertTrue(withoutDefault.contains { $0.kind == .multipleMatchingCertificates })

        let withDefault = detector.detect(
            certificates: [first, second],
            profiles: [],
            defaultFingerprintHex: first.fingerprintHex,
            referenceDate: referenceDate
        )
        XCTAssertFalse(withDefault.contains { $0.kind == .multipleMatchingCertificates })
    }

    func testTeamMismatchBetweenProfileAndEmbeddedCertificate() {
        let mismatched = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 6),
            teamID: "TEAMXYZ789"
        )
        let profile = IdentityCenterFixtures.profileFacts(
            name: "Alpha Profile",
            teamID: "TEAMABC123",
            certificateFingerprints: [mismatched.fingerprintHex]
        )

        let conflicts = detector.detect(
            certificates: [mismatched],
            profiles: [profile],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        let mismatches = conflicts.filter { $0.kind == .teamMismatch }
        XCTAssertEqual(mismatches.count, 1)
        XCTAssertEqual(mismatches[0].severity, .blocked)
        XCTAssertEqual(mismatches[0].profileIDs, [profile.id])
    }

    func testMissingProfileForTeamWithUsableCertificate() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 7),
            teamID: "TEAMABC123"
        )
        let otherTeamProfile = IdentityCenterFixtures.profileFacts(
            name: "Other Team",
            teamID: "TEAMXYZ789"
        )

        let conflicts = detector.detect(
            certificates: [certificate],
            profiles: [otherTeamProfile],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        let missing = conflicts.filter { $0.kind == .missingProfile }
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing[0].teamID, "TEAMABC123")
    }

    func testMissingProfileIsNotReportedWhenAnyProfileCoversTheTeam() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 8),
            teamID: "TEAMABC123"
        )
        let profile = IdentityCenterFixtures.profileFacts(name: "Covering", teamID: "TEAMABC123")

        let conflicts = detector.detect(
            certificates: [certificate],
            profiles: [profile],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertFalse(conflicts.contains { $0.kind == .missingProfile })
    }

    func testExpiredProfileIsReportedAsBlocking() {
        let expired = IdentityCenterFixtures.profileFacts(
            name: "Expired Profile",
            teamID: "TEAMABC123",
            expiresAt: TestClocks.utc(2026, 9, 15)
        )

        let conflicts = detector.detect(
            certificates: [],
            profiles: [expired],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].kind, .expiredProfile)
        XCTAssertEqual(conflicts[0].severity, .blocked)
        XCTAssertTrue(conflicts[0].message.contains("Expired Profile"))
    }

    func testOrphanedProfileWhenNoEmbeddedCertificateIsLocal() {
        let profile = IdentityCenterFixtures.profileFacts(
            name: "Orphaned Profile",
            certificateFingerprints: [
                IdentityCenterFixtures.fingerprintHex(seed: 0xEE),
                IdentityCenterFixtures.fingerprintHex(seed: 0xEF),
            ]
        )

        let conflicts = detector.detect(
            certificates: [],
            profiles: [profile],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        let orphaned = conflicts.filter { $0.kind == .orphanedProfile }
        XCTAssertEqual(orphaned.count, 1)
        XCTAssertEqual(orphaned[0].severity, .warning)

        // One embedded certificate present locally: no longer orphaned.
        let local = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 0xEE)
        )
        let withLocal = detector.detect(
            certificates: [local],
            profiles: [profile],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )
        XCTAssertFalse(withLocal.contains { $0.kind == .orphanedProfile })
    }

    func testBlockedConflictsSortAheadOfWarnings() {
        let mismatched = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 9),
            teamID: "TEAMXYZ789"
        )
        let expiredProfile = IdentityCenterFixtures.profileFacts(
            name: "Expired",
            teamID: "TEAMABC123",
            expiresAt: TestClocks.utc(2026, 9, 15)
        )
        let mismatchProfile = IdentityCenterFixtures.profileFacts(
            name: "Mismatch",
            teamID: "TEAMABC123",
            certificateFingerprints: [mismatched.fingerprintHex]
        )
        let duplicate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 10),
            teamID: "TEAMABC123"
        )

        let conflicts = detector.detect(
            certificates: [mismatched, duplicate],
            profiles: [expiredProfile, mismatchProfile],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertTrue(conflicts.contains { $0.severity == .blocked })
        XCTAssertTrue(conflicts.contains { $0.severity == .warning })
        guard let firstWarning = conflicts.firstIndex(where: { $0.severity == .warning }),
              let lastBlocked = conflicts.lastIndex(where: { $0.severity == .blocked }) else {
            return XCTFail("Expected both severities")
        }
        XCTAssertLessThan(lastBlocked, firstWarning)
    }

    func testConflictIdentifiersAreStableAcrossScans() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 11)
        )
        let profile = IdentityCenterFixtures.profileFacts(
            name: "Expired",
            expiresAt: TestClocks.utc(2026, 9, 15)
        )

        let first = detector.detect(
            certificates: [certificate],
            profiles: [profile],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )
        let second = detector.detect(
            certificates: [certificate],
            profiles: [profile],
            defaultFingerprintHex: nil,
            referenceDate: referenceDate
        )

        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }
}
