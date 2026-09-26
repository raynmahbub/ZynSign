import XCTest
@testable import ZynSign

/// Tests for extracting the team a certificate's subject declares: the ten
/// character Team ID and the team name.
final class CertificateTeamIdentityTests: XCTestCase {

    private func name(
        commonName: String? = nil,
        organization: String? = nil,
        organizationalUnits: [String] = []
    ) -> CertificateDistinguishedName {
        var attributes: [CertificateNameAttribute] = []
        if let commonName {
            attributes.append(CertificateNameAttribute(
                objectIdentifier: "2.5.4.3",
                recognition: .commonName,
                value: .text(commonName)
            ))
        }
        if let organization {
            attributes.append(CertificateNameAttribute(
                objectIdentifier: "2.5.4.10",
                recognition: .organization,
                value: .text(organization)
            ))
        }
        for unit in organizationalUnits {
            attributes.append(CertificateNameAttribute(
                objectIdentifier: "2.5.4.11",
                recognition: .organizationalUnit,
                value: .text(unit)
            ))
        }
        return CertificateDistinguishedName(
            commonName: commonName,
            organization: organization,
            organizationalUnit: organizationalUnits.first,
            attributes: attributes,
            rawRepresentation: attributes.map(\.shortLabel).joined(separator: ", ")
        )
    }

    // MARK: - Team ID from the organizational unit

    func testTeamIDReadFromTheOrganizationalUnit() {
        let identity = CertificateTeamIdentity.from(name(
            commonName: "Apple Development: John Smith (ABCDE12345)",
            organization: "John Smith",
            organizationalUnits: ["ABCDE12345"]
        ))
        XCTAssertEqual(identity.teamID, "ABCDE12345")
        XCTAssertEqual(identity.teamName, "John Smith")
    }

    func testTeamIDIsNormalisedToUpperCase() {
        let identity = CertificateTeamIdentity.from(name(
            commonName: "Apple Development: John (abcde12345)",
            organization: "John Smith",
            organizationalUnits: ["abcde12345"]
        ))
        XCTAssertEqual(identity.teamID, "ABCDE12345")
    }

    func testTheFirstOrganizationalUnitThatLooksLikeATeamIDWins() {
        let identity = CertificateTeamIdentity.from(name(
            commonName: "Apple Distribution: Acme (ABCDE12345)",
            organization: "Acme Inc",
            organizationalUnits: ["Not a team", "ABCDE12345", "ZZZ9999999"]
        ))
        XCTAssertEqual(identity.teamID, "ABCDE12345")
    }

    func testOrganizationalUnitsThatAreNotTeamIDsAreIgnored() {
        let identity = CertificateTeamIdentity.from(name(
            commonName: "Apple Distribution: Acme (ABCDE12345)",
            organization: "Acme Inc",
            organizationalUnits: ["Engineering", "Platform"]
        ))
        // "Engineering" and "Platform" are not ten alphanumeric characters,
        // so no OU supplies a team ID; the common name's group does.
        XCTAssertEqual(identity.teamID, "ABCDE12345")
    }

    // MARK: - Team ID from the common name

    func testTeamIDReadFromTheCommonNameWhenNoOrganizationalUnitSuppliesOne() {
        let identity = CertificateTeamIdentity.from(name(
            commonName: "Apple Distribution: Acme (ABCDE12345)",
            organization: "Acme Inc"
        ))
        XCTAssertEqual(identity.teamID, "ABCDE12345")
        XCTAssertEqual(identity.teamName, "Acme Inc")
    }

    func testCommonNameGroupIsOnlyUsedWhenItsShapeIsATeamID() {
        let identity = CertificateTeamIdentity.from(name(
            commonName: "John Smith (beta build)",
            organization: "Smith & Co"
        ))
        XCTAssertNil(identity.teamID)
        XCTAssertEqual(identity.teamName, "Smith & Co")
    }

    func testCommonNameGroupOfTheWrongShapeIsNotATeamID() {
        XCTAssertFalse(CertificateTeamIdentity.isValidTeamID("ABCDE1234"))
        XCTAssertFalse(CertificateTeamIdentity.isValidTeamID("ABCDE123456"))
        XCTAssertFalse(CertificateTeamIdentity.isValidTeamID("ABCDE-2345"))
        XCTAssertFalse(CertificateTeamIdentity.isValidTeamID(""))
        XCTAssertTrue(CertificateTeamIdentity.isValidTeamID("ABCDE12345"))
        XCTAssertTrue(CertificateTeamIdentity.isValidTeamID("0123456789"))
    }

    // MARK: - Team name

    func testTeamNameFallsBackToTheCommonNameWithoutTheTeamIDGroup() {
        let identity = CertificateTeamIdentity.from(name(
            commonName: "Apple Development: Jane Doe (ABCDE12345)"
        ))
        XCTAssertEqual(identity.teamID, "ABCDE12345")
        XCTAssertEqual(identity.teamName, "Apple Development: Jane Doe")
    }

    func testABareCommonNameIsNotATeamName() {
        // A common name without an organization and without a (TEAMID)
        // group declares no team: the identity shows its certificate name,
        // not an invented team.
        let identity = CertificateTeamIdentity.from(name(commonName: "Jane Doe"))
        XCTAssertNil(identity.teamID)
        XCTAssertNil(identity.teamName)
    }

    func testOrganizationWinsOverTheCommonNameForTheTeamName() {
        let identity = CertificateTeamIdentity.from(name(
            commonName: "Apple Development: Jane Doe (ABCDE12345)",
            organization: "Doe Studios"
        ))
        XCTAssertEqual(identity.teamName, "Doe Studios")
    }

    // MARK: - No team information

    func testACertificateWithNoTeamInformationDeclaresNone() {
        let identity = CertificateTeamIdentity.from(name(commonName: "Some CA Leaf"))
        XCTAssertNil(identity.teamID)
        XCTAssertEqual(identity.teamName, "Some CA Leaf")
        XCTAssertFalse(identity.hasTeamInformation)
    }

    func testAnEmptyCommonNameDeclaresNothing() {
        let identity = CertificateTeamIdentity.from(name(commonName: "   "))
        XCTAssertNil(identity.teamID)
        XCTAssertNil(identity.teamName)
    }

    func testAnUndecodedAttributeIsIgnoredRatherThanCrashing() {
        let subject = CertificateDistinguishedName(
            commonName: "Apple Development: Jane (ABCDE12345)",
            organization: "Jane",
            organizationalUnit: nil,
            attributes: [
                CertificateNameAttribute(
                    objectIdentifier: "2.5.4.11",
                    recognition: .organizationalUnit,
                    value: .undecodedHexadecimal("414243")
                ),
                CertificateNameAttribute(
                    objectIdentifier: "2.5.4.3",
                    recognition: .commonName,
                    value: .text("Apple Development: Jane (ABCDE12345)")
                )
            ],
            rawRepresentation: "OU=414243, CN=Apple Development: Jane (ABCDE12345)"
        )
        let identity = CertificateTeamIdentity.from(subject)
        XCTAssertEqual(identity.teamID, "ABCDE12345")
        XCTAssertEqual(identity.teamName, "Jane")
    }

    // MARK: - The real fixtures

    func testTheMultiAttributeFixtureDeclaresANonAppleTeamShape() throws {
        let metadata = try AppleCertificateParser()
            .parseCertificate(derData: CertificateFixtures.multiAttributeDER)
        let identity = CertificateTeamIdentity.from(metadata.subject)
        // The fixture's OUs ("Test Unit", "Second Unit") are not team IDs,
        // so the team ID is absent; the organization is the team name.
        XCTAssertNil(identity.teamID)
        XCTAssertEqual(identity.teamName, "ZynSign Test Org")
    }

    func testTheValidFixtureDeclaresNoTeam() throws {
        let metadata = try AppleCertificateParser()
            .parseCertificate(derData: CertificateFixtures.validDER)
        let identity = CertificateTeamIdentity.from(metadata.subject)
        // The valid fixture's subject is a bare common name: no
        // organization, no (TEAMID) group, so no team is declared.
        XCTAssertNil(identity.teamID)
        XCTAssertNil(identity.teamName)
        XCTAssertFalse(identity.hasTeamInformation)
    }
}
