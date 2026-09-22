import XCTest
@testable import ZynSign

final class SignatureAlgorithmTests: XCTestCase {

    func testFromIdentifierRSA() {
        XCTAssertEqual(SignatureAlgorithm.from(identifier: "sha256WithRSAEncryption"), .sha256WithRSAEncryption)
        XCTAssertEqual(SignatureAlgorithm.from(identifier: "SHA256WITHRSAENCRYPTION"), .sha256WithRSAEncryption)
        XCTAssertEqual(SignatureAlgorithm.from(identifier: "1.2.840.113549.1.1.11"), .sha256WithRSAEncryption)
    }

    func testFromIdentifierECDSA() {
        XCTAssertEqual(SignatureAlgorithm.from(identifier: "ecdsa-with-SHA256"), .ecdsaWithSHA256)
        XCTAssertEqual(SignatureAlgorithm.from(identifier: "1.2.840.10045.4.3.2"), .ecdsaWithSHA256)
    }

    func testUnknownPreserved() {
        let unknown = SignatureAlgorithm.from(identifier: "1.2.3.4.5")
        if case .unknown(let id) = unknown {
            XCTAssertEqual(id, "1.2.3.4.5")
        } else {
            XCTFail("Expected unknown")
        }
    }

    func testSHA1Detection() {
        XCTAssertTrue(SignatureAlgorithm.sha1WithRSAEncryption.usesSHA1)
        XCTAssertTrue(SignatureAlgorithm.ecdsaWithSHA1.usesSHA1)
        XCTAssertFalse(SignatureAlgorithm.sha256WithRSAEncryption.usesSHA1)
        XCTAssertFalse(SignatureAlgorithm.ecdsaWithSHA256.usesSHA1)
    }

    func testRecognition() {
        XCTAssertTrue(SignatureAlgorithm.sha256WithRSAEncryption.isRecognised)
        XCTAssertFalse(SignatureAlgorithm.unknown("X").isRecognised)
    }

    func testDisplayName() {
        XCTAssertEqual(SignatureAlgorithm.sha256WithRSAEncryption.displayName, "sha256WithRSAEncryption")
        XCTAssertEqual(SignatureAlgorithm.ecdsaWithSHA256.displayName, "ecdsa-with-SHA256")
    }
}
