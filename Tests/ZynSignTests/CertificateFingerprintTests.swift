import XCTest
@testable import ZynSign

final class CertificateFingerprintTests: XCTestCase {

    func testValidHexDigestAccepted() {
        let hex = CertificateFixtures.validFingerprintHex
        let fingerprint = CertificateFingerprint(hexDigest: hex)
        XCTAssertNotNil(fingerprint)
        XCTAssertEqual(fingerprint?.hexDigest, hex)
        XCTAssertEqual(fingerprint?.algorithm, .sha256)
    }

    func testUppercaseHexNormalizedToLowercase() {
        let upper = CertificateFixtures.validFingerprintHex.uppercased()
        let fingerprint = CertificateFingerprint(hexDigest: upper)
        XCTAssertNotNil(fingerprint)
        XCTAssertEqual(fingerprint?.hexDigest, CertificateFixtures.validFingerprintHex)
    }

    func testInvalidLengthRejected() {
        XCTAssertNil(CertificateFingerprint(hexDigest: "abc"))
        XCTAssertNil(CertificateFingerprint(hexDigest: ""))
        XCTAssertNil(CertificateFingerprint(hexDigest: String(repeating: "a", count: 63)))
        XCTAssertNil(CertificateFingerprint(hexDigest: String(repeating: "a", count: 65)))
    }

    func testNonHexRejected() {
        let invalid = String(repeating: "z", count: 64)
        XCTAssertNil(CertificateFingerprint(hexDigest: invalid))
        let withSpace = CertificateFixtures.validFingerprintHex + " "
        XCTAssertNil(CertificateFingerprint(hexDigest: withSpace))
    }

    func testDigestBytesInit() {
        let bytes = Array(repeating: UInt8(0xAB), count: 32)
        let fingerprint = CertificateFingerprint(digestBytes: bytes)
        XCTAssertNotNil(fingerprint)
        XCTAssertEqual(fingerprint?.hexDigest, String(repeating: "ab", count: 32))
    }

    func testDigestBytesWrongLengthRejected() {
        XCTAssertNil(CertificateFingerprint(digestBytes: [0x00, 0x01]))
        XCTAssertNil(CertificateFingerprint(digestBytes: Array(repeating: 0, count: 20)))
    }

    func testDescription() {
        let fingerprint = CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!
        XCTAssertTrue(fingerprint.description.hasPrefix("sha256:"))
        XCTAssertTrue(fingerprint.description.contains(CertificateFixtures.validFingerprintHex))
    }

    func testEquality() {
        let first = CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!
        let second = CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!
        XCTAssertEqual(first, second)
        let different = CertificateFingerprint(hexDigest: CertificateFixtures.expiredFingerprintHex)!
        XCTAssertNotEqual(first, different)
    }

    func testDigestBytesRoundTrip() {
        let fingerprint = CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!
        let bytes = fingerprint.digestBytes
        XCTAssertEqual(bytes.count, 32)
        let reconstructed = CertificateFingerprint(digestBytes: bytes)
        XCTAssertEqual(reconstructed, fingerprint)
    }
}
