import XCTest
@testable import ZynSign

final class CertificateDigestTests: XCTestCase {

    func testSHA256KnownVectors() {
        assertDigest(Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        assertDigest(Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        assertDigest(Data("not a certificate".utf8), "47209c9b7af839de69e9a9cd625e9182c1ad63dae79ed88a2dd680fe34218620")
        assertDigest(Data((0..<256).map { UInt8($0) }), "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880")
    }

    func testFingerprintMatchesDigestOfAcceptedBytes() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.validDER)
        let digest = CertificateDigest.sha256(CertificateFixtures.validDER)
        XCTAssertEqual(metadata.sha256Fingerprint, CertificateFingerprint(digestBytes: digest))
        XCTAssertEqual(metadata.sha256Fingerprint.hexDigest, CertificateFixtures.validFingerprintHex)
    }

    private func assertDigest(_ data: Data, _ hex: String, file: StaticString = #filePath, line: UInt = #line) {
        let digest = CertificateDigest.sha256(data)
        XCTAssertEqual(CertificateFingerprint(digestBytes: digest)?.hexDigest, hex, file: file, line: line)
    }
}
