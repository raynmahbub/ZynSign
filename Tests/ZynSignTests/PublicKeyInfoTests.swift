import XCTest
@testable import ZynSign

final class PublicKeyInfoTests: XCTestCase {

    func testRSA2048Adequate() {
        let info = PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048)
        XCTAssertTrue(info.appearsAdequateForCodeSigning)
    }

    func testRSA1024NotAdequate() {
        let info = PublicKeyInfo(algorithm: .rsa, keySizeInBits: 1024)
        XCTAssertFalse(info.appearsAdequateForCodeSigning)
    }

    func testRSAWithoutSizeNotAdequate() {
        let info = PublicKeyInfo(algorithm: .rsa, keySizeInBits: nil)
        XCTAssertFalse(info.appearsAdequateForCodeSigning)
    }

    func testECP256Adequate() {
        let info = PublicKeyInfo(algorithm: .ec, keySizeInBits: 256, curveName: "P-256")
        XCTAssertTrue(info.appearsAdequateForCodeSigning)
    }

    func testECP384Adequate() {
        let info = PublicKeyInfo(algorithm: .ec, keySizeInBits: 384, curveName: "P-384")
        XCTAssertTrue(info.appearsAdequateForCodeSigning)
    }

    func testECWithPrime256v1Name() {
        let info = PublicKeyInfo(algorithm: .ec, keySizeInBits: 256, curveName: "prime256v1")
        XCTAssertTrue(info.appearsAdequateForCodeSigning)
    }

    func testECWithoutCurveButWithSize() {
        let info = PublicKeyInfo(algorithm: .ec, keySizeInBits: 256, curveName: nil)
        XCTAssertTrue(info.appearsAdequateForCodeSigning)
    }

    func testECTooSmallNotAdequate() {
        let info = PublicKeyInfo(algorithm: .ec, keySizeInBits: 128, curveName: nil)
        XCTAssertFalse(info.appearsAdequateForCodeSigning)
    }

    func testUnknownAlgorithmNotAdequate() {
        let info = PublicKeyInfo(algorithm: .unknown("1.2.3.4"), keySizeInBits: 2048)
        XCTAssertFalse(info.appearsAdequateForCodeSigning)
    }

    func testPublicKeyAlgorithmDisplayName() {
        XCTAssertEqual(PublicKeyAlgorithm.rsa.displayName, "RSA")
        XCTAssertEqual(PublicKeyAlgorithm.ec.displayName, "EC")
        XCTAssertEqual(PublicKeyAlgorithm.unknown("Custom").displayName, "Custom")
    }

    func testPublicKeyAlgorithmRecognition() {
        XCTAssertTrue(PublicKeyAlgorithm.rsa.isRecognised)
        XCTAssertTrue(PublicKeyAlgorithm.ec.isRecognised)
        XCTAssertFalse(PublicKeyAlgorithm.unknown("X").isRecognised)
    }
}
