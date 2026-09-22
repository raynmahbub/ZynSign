import XCTest
@testable import ZynSign

final class CertificateMetadataTests: XCTestCase {

    private func makeSubject(commonName: String = "ZynSign Test Valid") -> CertificateDistinguishedName {
        CertificateDistinguishedName(
            commonName: commonName,
            organization: "ZynSign Test Org",
            organizationalUnit: "Test Unit",
            country: "US",
            rawRepresentation: "CN=\(commonName), O=ZynSign Test Org, OU=Test Unit, C=US"
        )
    }

    private func makeIssuer(commonName: String = "Test CA") -> CertificateDistinguishedName {
        CertificateDistinguishedName(
            commonName: commonName,
            organization: "ZynSign Test",
            country: "US",
            rawRepresentation: "CN=\(commonName), O=ZynSign Test, C=US"
        )
    }

    private func makeFingerprint(hex: String = CertificateFixtures.validFingerprintHex) -> CertificateFingerprint {
        CertificateFingerprint(hexDigest: hex)!
    }

    func testCreatesMetadata() {
        let subject = makeSubject()
        let issuer = makeIssuer()
        let fingerprint = makeFingerprint()
        let notBefore = Date(timeIntervalSince1970: 1_000_000)
        let notAfter = Date(timeIntervalSince1970: 2_000_000)
        let publicKeyInfo = PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048)
        let metadata = CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: CertificateSerialNumber(hexadecimal: "04abcd")!,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            publicKeyInfo: publicKeyInfo,
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: fingerprint
        )
        XCTAssertEqual(metadata.subject, subject)
        XCTAssertEqual(metadata.issuer, issuer)
        XCTAssertEqual(metadata.serialNumber, CertificateSerialNumber(hexadecimal: "04abcd")!)
        XCTAssertEqual(metadata.notValidBefore, notBefore)
        XCTAssertEqual(metadata.notValidAfter, notAfter)
        XCTAssertEqual(metadata.publicKeyInfo.algorithm, .rsa)
        XCTAssertEqual(metadata.publicKeyInfo.keySizeInBits, 2048)
        XCTAssertEqual(metadata.signatureAlgorithm, .sha256WithRSAEncryption)
        XCTAssertEqual(metadata.sha256Fingerprint, fingerprint)
    }

    func testSelfSignedDetection() {
        let name = makeSubject(commonName: "Same")
        let fingerprint = makeFingerprint()
        let metadata = CertificateMetadata(
            subject: name,
            issuer: name,
            serialNumber: CertificateSerialNumber(hexadecimal: "01")!,
            notValidBefore: Date(),
            notValidAfter: Date().addingTimeInterval(3600),
            publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: fingerprint
        )
        XCTAssertTrue(metadata.isSelfSigned)
    }

    func testNotSelfSignedWhenIssuerDiffers() {
        let subject = makeSubject(commonName: "Leaf")
        let issuer = makeIssuer(commonName: "CA")
        let fingerprint = makeFingerprint()
        let metadata = CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: CertificateSerialNumber(hexadecimal: "02")!,
            notValidBefore: Date(),
            notValidAfter: Date().addingTimeInterval(3600),
            publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: fingerprint
        )
        XCTAssertFalse(metadata.isSelfSigned)
    }

    func testEquality() {
        let subject = makeSubject()
        let issuer = makeIssuer()
        let fingerprint = makeFingerprint()
        let notBefore = Date(timeIntervalSince1970: 1_000_000)
        let notAfter = Date(timeIntervalSince1970: 2_000_000)
        let info = PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048)
        let first = CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: CertificateSerialNumber(hexadecimal: "01")!,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            publicKeyInfo: info,
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: fingerprint
        )
        let second = CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: CertificateSerialNumber(hexadecimal: "01")!,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            publicKeyInfo: info,
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: fingerprint
        )
        XCTAssertEqual(first, second)
    }

    func testFingerprintPreserved() {
        let fingerprint = CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!
        let metadata = CertificateMetadata(
            subject: makeSubject(),
            issuer: makeIssuer(),
            serialNumber: CertificateSerialNumber(hexadecimal: "01")!,
            notValidBefore: Date(),
            notValidAfter: Date().addingTimeInterval(3600),
            publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: fingerprint
        )
        XCTAssertEqual(metadata.sha256Fingerprint.hexDigest, CertificateFixtures.validFingerprintHex)
    }
}
