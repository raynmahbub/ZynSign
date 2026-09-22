import XCTest
@testable import ZynSign

final class CertificateDistinguishedNameTests: XCTestCase {

    func testCreatesWithAllFields() {
        let name = CertificateDistinguishedName(
            commonName: "ZynSign Test Valid",
            organization: "ZynSign Test Org",
            organizationalUnit: "Test Unit",
            country: "US",
            rawRepresentation: "CN=ZynSign Test Valid, O=ZynSign Test Org, OU=Test Unit, C=US"
        )
        XCTAssertEqual(name.commonName, "ZynSign Test Valid")
        XCTAssertEqual(name.organization, "ZynSign Test Org")
        XCTAssertEqual(name.organizationalUnit, "Test Unit")
        XCTAssertEqual(name.country, "US")
        XCTAssertEqual(name.rawRepresentation, "CN=ZynSign Test Valid, O=ZynSign Test Org, OU=Test Unit, C=US")
    }

    func testDisplayNamePrefersCommonName() {
        let name = CertificateDistinguishedName(
            commonName: "Example CN",
            organization: "Example Org",
            rawRepresentation: "CN=Example CN, O=Example Org"
        )
        XCTAssertEqual(name.displayName, "Example CN")
    }

    func testDisplayNameFallsBackToOrganization() {
        let name = CertificateDistinguishedName(
            organization: "Example Org",
            rawRepresentation: "O=Example Org"
        )
        XCTAssertEqual(name.displayName, "Example Org")
    }

    func testDisplayNameFallsBackToRawWhenNoCommonNameOrOrg() {
        let name = CertificateDistinguishedName(
            rawRepresentation: "Unusual Structure"
        )
        XCTAssertEqual(name.displayName, "Unusual Structure")
    }

    func testDisplayNameIgnoresEmptyCommonName() {
        let name = CertificateDistinguishedName(
            commonName: "   ",
            organization: "Example Org",
            rawRepresentation: "CN=   , O=Example Org"
        )
        XCTAssertEqual(name.displayName, "Example Org")
    }

    func testEquality() {
        let first = CertificateDistinguishedName(
            commonName: "Test",
            rawRepresentation: "CN=Test"
        )
        let second = CertificateDistinguishedName(
            commonName: "Test",
            rawRepresentation: "CN=Test"
        )
        XCTAssertEqual(first, second)
    }

    func testUnusualStructurePreserved() {
        // Space as CN, as in unusualDER fixture
        let name = CertificateDistinguishedName(
            commonName: " ",
            organization: "ZynSign Test Org",
            rawRepresentation: "CN= , O=ZynSign Test Org"
        )
        XCTAssertEqual(name.rawRepresentation, "CN= , O=ZynSign Test Org")
        XCTAssertEqual(name.commonName, " ")
        // Display name should fall back to organization because CN is blank
        XCTAssertEqual(name.displayName, "ZynSign Test Org")
    }
}
