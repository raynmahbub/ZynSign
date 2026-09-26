import XCTest
@testable import ZynSign

/// Tests for the Developer Team grouper: the Team Workspace's ordering
/// rule, case-insensitive Team ID grouping, the ungrouped bucket, and
/// member counting.
final class DeveloperTeamTests: XCTestCase {

    private let grouper = DeveloperTeamGrouper()

    func testGroupsCertificatesAndProfilesByTeamID() {
        let alphaCertificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 1),
            teamID: "TEAMABC123"
        )
        let betaCertificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 2),
            teamID: "TEAMXYZ789"
        )
        let alphaProfile = IdentityCenterFixtures.profileFacts(
            name: "Alpha Profile",
            teamID: "TEAMABC123"
        )

        let teams = grouper.group(
            certificates: [alphaCertificate, betaCertificate],
            profiles: [alphaProfile]
        )

        XCTAssertEqual(teams.count, 2)
        XCTAssertEqual(teams[0].teamID, "TEAMABC123")
        XCTAssertEqual(teams[0].certificateFingerprints, [alphaCertificate.fingerprintHex])
        XCTAssertEqual(teams[0].profileIDs, [alphaProfile.id])
        XCTAssertEqual(teams[1].teamID, "TEAMXYZ789")
        XCTAssertTrue(teams[1].profileIDs.isEmpty)
    }

    func testGroupingIsCaseInsensitiveButPreservesFirstSpelling() {
        let lower = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 3),
            teamID: "teamabc123"
        )
        let upper = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 4),
            teamID: "TEAMABC123"
        )

        let teams = grouper.group(certificates: [lower, upper], profiles: [])

        XCTAssertEqual(teams.count, 1)
        // The first spelling seen is preserved for display.
        XCTAssertEqual(teams[0].teamID, "teamabc123")
        XCTAssertEqual(teams[0].certificateFingerprints.count, 2)
    }

    func testUngroupedMembersLandInOneBucketSortedLast() {
        let named = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 5),
            displayName: "Zeta Certificate",
            teamID: "TEAMABC123"
        )
        let strayCertificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 6),
            displayName: "Stray Certificate",
            teamID: nil
        )
        let strayProfile = IdentityCenterFixtures.profileFacts(
            name: "Stray Profile",
            teamID: nil
        )

        let teams = grouper.group(
            certificates: [strayCertificate, named],
            profiles: [strayProfile]
        )

        XCTAssertEqual(teams.count, 2)
        XCTAssertTrue(teams[0].teamID == "TEAMABC123")
        XCTAssertTrue(teams.last!.isUngrouped)
        XCTAssertEqual(teams.last!.certificateFingerprints, [strayCertificate.fingerprintHex])
        XCTAssertEqual(teams.last!.profileIDs, [strayProfile.id])
        XCTAssertEqual(teams.last!.displayName, "Ungrouped")
    }

    func testTeamNamePrefersTheFirstDeclaredName() {
        let certificate = IdentityCenterFixtures.certificateFacts(
            fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 7),
            teamID: "TEAMABC123",
            teamName: "Certificate Name"
        )
        let profile = IdentityCenterFixtures.profileFacts(
            name: "Profile",
            teamID: "TEAMABC123",
            teamName: "Profile Name"
        )

        let teams = grouper.group(certificates: [certificate], profiles: [profile])

        XCTAssertEqual(teams.count, 1)
        XCTAssertEqual(teams[0].teamName, "Certificate Name")
        XCTAssertEqual(teams[0].displayName, "Certificate Name")
    }

    func testMemberCountSumsCertificatesAndProfiles() {
        let team = DeveloperTeam(
            teamID: "TEAMABC123",
            teamName: nil,
            certificateFingerprints: ["a", "b"],
            profileIDs: [ProvisioningProfileIdentifier(), ProvisioningProfileIdentifier(), ProvisioningProfileIdentifier()]
        )
        XCTAssertEqual(team.memberCount, 5)
    }

    func testTeamIDsAreStableAndDisplayNamesFallBack() {
        let team = DeveloperTeam(
            teamID: "TEAMABC123",
            teamName: nil,
            certificateFingerprints: [],
            profileIDs: []
        )
        XCTAssertEqual(team.id, "TEAMABC123")
        XCTAssertEqual(team.displayName, "TEAMABC123")

        let ungrouped = DeveloperTeam(
            teamID: nil,
            teamName: nil,
            certificateFingerprints: [],
            profileIDs: []
        )
        XCTAssertEqual(ungrouped.id, DeveloperTeam.ungroupedIdentifier)
        XCTAssertEqual(ungrouped.displayName, "Ungrouped")
        XCTAssertTrue(ungrouped.isUngrouped)
    }
}
