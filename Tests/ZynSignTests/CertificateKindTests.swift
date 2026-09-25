import XCTest
@testable import ZynSign

/// Tests for classifying the kind of code-signing certificate from the
/// prefix its common name declares.
final class CertificateKindTests: XCTestCase {

    // MARK: - Development

    func testCurrentDevelopmentPrefixes() {
        XCTAssertEqual(SigningCertificateKind.classify(commonName: "Apple Development: John (ABCDE12345)"), .development)
        XCTAssertEqual(SigningCertificateKind.classify(commonName: "Xcode Provisioning: Jane (ABCDE12345)"), .development)
    }

    func testLegacyDevelopmentPrefixes() {
        XCTAssertEqual(SigningCertificateKind.classify(commonName: "iPhone Developer: John (ABCDE12345)"), .development)
        XCTAssertEqual(SigningCertificateKind.classify(commonName: "Mac Developer: John (ABCDE12345)"), .development)
    }

    // MARK: - Distribution

    func testCurrentDistributionPrefixes() {
        XCTAssertEqual(SigningCertificateKind.classify(commonName: "Apple Distribution: Acme (ABCDE12345)"), .distribution)
    }

    func testLegacyDistributionPrefixes() {
        XCTAssertEqual(SigningCertificateKind.classify(commonName: "iPhone Distribution: Acme (ABCDE12345)"), .distribution)
        XCTAssertEqual(SigningCertificateKind.classify(commonName: "Mac Distribution: Acme (ABCDE12345)"), .distribution)
    }

    // MARK: - Other

    func testAnUnrecognisedCommonNameIsOther() {
        XCTAssertEqual(SigningCertificateKind.classify(commonName: "ZynSign Test Valid"), .other)
        XCTAssertEqual(SigningCertificateKind.classify(commonName: "Some CA Leaf"), .other)
    }

    func testAnAbsentCommonNameIsOtherNotAnError() {
        XCTAssertEqual(SigningCertificateKind.classify(commonName: nil), .other)
    }

    func testWhitespaceAroundTheNameDoesNotDefeatThePrefix() {
        XCTAssertEqual(SigningCertificateKind.classify(commonName: "  Apple Distribution: Acme  "), .distribution)
    }

    func testPrefixesAreNotInventedInsideTheName() {
        // "Development" appears, but not as a leading prefix.
        XCTAssertEqual(SigningCertificateKind.classify(commonName: "My App (Development)"), .other)
    }

    // MARK: - Subject convenience

    func testClassifyFromSubjectUsesTheCommonName() {
        let subject = CertificateDistinguishedName(
            commonName: "Apple Distribution: Acme (ABCDE12345)",
            organization: "Acme",
            attributes: [],
            rawRepresentation: "CN=Apple Distribution: Acme (ABCDE12345)"
        )
        XCTAssertEqual(SigningCertificateKind.classify(subject: subject), .distribution)
    }

    // MARK: - Display names

    func testDisplayNamesAreStable() {
        XCTAssertEqual(SigningCertificateKind.development.displayName, "Development")
        XCTAssertEqual(SigningCertificateKind.distribution.displayName, "Distribution")
        XCTAssertEqual(SigningCertificateKind.other.displayName, "Other")
    }
}
