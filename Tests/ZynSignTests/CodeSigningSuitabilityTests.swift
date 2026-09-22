import XCTest
@testable import ZynSign

final class CodeSigningSuitabilityTests: XCTestCase {

    private func makeMetadata(
        notBefore: Date = Date(timeIntervalSince1970: 1_000_000),
        notAfter: Date = Date(timeIntervalSince1970: 4_000_000_000),
        publicKeyInfo: PublicKeyInfo = PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
        signatureAlgorithm: SignatureAlgorithm = .sha256WithRSAEncryption
    ) -> CertificateMetadata {
        let subject = CertificateDistinguishedName(commonName: "Test", rawRepresentation: "CN=Test")
        let issuer = CertificateDistinguishedName(commonName: "CA", rawRepresentation: "CN=CA")
        return CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: CertificateSerialNumber(hexadecimal: "01")!,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            publicKeyInfo: publicKeyInfo,
            signatureAlgorithm: signatureAlgorithm,
            sha256Fingerprint: CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!
        )
    }

    func testSuitableCertificate() {
        let metadata = makeMetadata()
        let suitability = CodeSigningSuitability.evaluate(
            metadata: metadata,
            evaluationDate: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertTrue(suitability.isParseable)
        XCTAssertTrue(suitability.hasAdequateKeyCharacteristics)
        XCTAssertTrue(suitability.appearsSuitableForCodeSigning)
        XCTAssertTrue(suitability.unsuitabilityReasons.isEmpty)
    }

    func testExpiredNotSuitable() {
        let metadata = makeMetadata(
            notBefore: Date(timeIntervalSince1970: 1_000_000),
            notAfter: Date(timeIntervalSince1970: 2_000_000)
        )
        let suitability = CodeSigningSuitability.evaluate(
            metadata: metadata,
            evaluationDate: Date(timeIntervalSince1970: 3_000_000)
        )
        XCTAssertFalse(suitability.appearsSuitableForCodeSigning)
        XCTAssertTrue(suitability.unsuitabilityReasons.contains(.expired))
    }

    func testNotYetValidNotSuitable() {
        let metadata = makeMetadata(
            notBefore: Date(timeIntervalSince1970: 3_000_000),
            notAfter: Date(timeIntervalSince1970: 4_000_000)
        )
        let suitability = CodeSigningSuitability.evaluate(
            metadata: metadata,
            evaluationDate: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertFalse(suitability.appearsSuitableForCodeSigning)
        XCTAssertTrue(suitability.unsuitabilityReasons.contains(.notYetValid))
    }

    func testWeakKeyNotSuitable() {
        let metadata = makeMetadata(
            publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 1024)
        )
        let suitability = CodeSigningSuitability.evaluate(
            metadata: metadata,
            evaluationDate: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertFalse(suitability.appearsSuitableForCodeSigning)
        XCTAssertTrue(suitability.unsuitabilityReasons.contains(.weakKey))
    }

    func testUnknownKeyAlgorithmNotSuitable() {
        let metadata = makeMetadata(
            publicKeyInfo: PublicKeyInfo(algorithm: .unknown("1.2.3"), keySizeInBits: 2048)
        )
        let suitability = CodeSigningSuitability.evaluate(
            metadata: metadata,
            evaluationDate: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertFalse(suitability.appearsSuitableForCodeSigning)
        XCTAssertTrue(suitability.unsuitabilityReasons.contains(.unknownKeyAlgorithm))
    }

    func testWeakSignatureAlgorithmNotSuitable() {
        let metadata = makeMetadata(
            signatureAlgorithm: .sha1WithRSAEncryption
        )
        let suitability = CodeSigningSuitability.evaluate(
            metadata: metadata,
            evaluationDate: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertFalse(suitability.appearsSuitableForCodeSigning)
        XCTAssertTrue(suitability.unsuitabilityReasons.contains(.weakSignatureAlgorithm))
    }

    func testUnknownSignatureAlgorithmNotSuitable() {
        let metadata = makeMetadata(
            signatureAlgorithm: .unknown("1.2.3.4")
        )
        let suitability = CodeSigningSuitability.evaluate(
            metadata: metadata,
            evaluationDate: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertFalse(suitability.appearsSuitableForCodeSigning)
        XCTAssertTrue(suitability.unsuitabilityReasons.contains(.unknownSignatureAlgorithm))
    }

    func testNotParseable() {
        let suitability = CodeSigningSuitability.notParseable()
        XCTAssertFalse(suitability.isParseable)
        XCTAssertFalse(suitability.appearsSuitableForCodeSigning)
        XCTAssertTrue(suitability.unsuitabilityReasons.contains(.notParseable))
    }

    func testSuitabilityDoesNotImplyPlatformAcceptance() {
        // Suitability in this milestone is a heuristic, not a platform policy
        // decision. This test documents that distinction.
        let metadata = makeMetadata()
        let suitability = CodeSigningSuitability.evaluate(
            metadata: metadata,
            evaluationDate: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertTrue(suitability.appearsSuitableForCodeSigning)
        // Appears suitable does not mean platform will accept it.
        // Platform acceptance is not evaluated in this milestone.
    }
}
