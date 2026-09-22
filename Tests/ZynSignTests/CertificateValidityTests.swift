import XCTest
@testable import ZynSign

final class CertificateValidityTests: XCTestCase {

    private let notBefore = Date(timeIntervalSince1970: 1_000_000) // 1970-01-12
    private let notAfter = Date(timeIntervalSince1970: 2_000_000)  // 1970-01-24

    func testCurrentlyValid() {
        let evaluationDate = Date(timeIntervalSince1970: 1_500_000)
        let validity = CertificateValidity.evaluate(
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            at: evaluationDate
        )
        XCTAssertEqual(validity.periodStatus, .currentlyValid)
        XCTAssertTrue(validity.isCurrentlyValid)
        XCTAssertEqual(validity.evaluationDate, evaluationDate)
    }

    func testExpired() {
        let evaluationDate = Date(timeIntervalSince1970: 3_000_000)
        let validity = CertificateValidity.evaluate(
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            at: evaluationDate
        )
        XCTAssertEqual(validity.periodStatus, .expired)
        XCTAssertFalse(validity.isCurrentlyValid)
    }

    func testNotYetValid() {
        let evaluationDate = Date(timeIntervalSince1970: 500_000)
        let validity = CertificateValidity.evaluate(
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            at: evaluationDate
        )
        XCTAssertEqual(validity.periodStatus, .notYetValid)
        XCTAssertFalse(validity.isCurrentlyValid)
    }

    func testBoundaryInclusiveNotBefore() {
        let validity = CertificateValidity.evaluate(
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            at: notBefore
        )
        XCTAssertEqual(validity.periodStatus, .currentlyValid)
    }

    func testBoundaryInclusiveNotAfter() {
        let validity = CertificateValidity.evaluate(
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            at: notAfter
        )
        XCTAssertEqual(validity.periodStatus, .currentlyValid)
    }

    func testEvaluateFromMetadata() {
        let subject = CertificateDistinguishedName(rawRepresentation: "CN=Test")
        let issuer = CertificateDistinguishedName(rawRepresentation: "CN=CA")
        let fingerprint = CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!
        let metadata = CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: CertificateSerialNumber(hexadecimal: "01")!,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: fingerprint
        )
        let validity = CertificateValidity.evaluate(
            certificate: metadata,
            at: Date(timeIntervalSince1970: 1_500_000)
        )
        XCTAssertEqual(validity.periodStatus, .currentlyValid)
    }

    func testValidityPeriodStatusDisplayName() {
        XCTAssertEqual(CertificateValidityPeriodStatus.currentlyValid.displayName, "Currently Valid")
        XCTAssertEqual(CertificateValidityPeriodStatus.expired.displayName, "Expired")
        XCTAssertEqual(CertificateValidityPeriodStatus.notYetValid.displayName, "Not Yet Valid")
    }

    func testTrustEvaluationDefaults() {
        let validity = CertificateValidity.evaluate(
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            at: Date(timeIntervalSince1970: 1_500_000)
        )
        let trust = CertificateTrustEvaluation(period: validity)
        XCTAssertEqual(trust.usage, .notEvaluated)
        XCTAssertEqual(trust.trust, .notEvaluated)
        XCTAssertTrue(trust.isCurrentlyValidForDisplay)
    }

    func testTrustEvaluationExpiredIsNotValidForDisplay() {
        let validity = CertificateValidity.evaluate(
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            at: Date(timeIntervalSince1970: 3_000_000)
        )
        let trust = CertificateTrustEvaluation(period: validity)
        XCTAssertFalse(trust.isCurrentlyValidForDisplay)
        XCTAssertEqual(validity.periodStatus, .expired)
    }

    func testValidityDistinctFromParsing() {
        // Parsing succeeded (metadata exists) does not imply currently valid.
        // This test documents the distinction required by the architecture.
        let subject = CertificateDistinguishedName(rawRepresentation: "CN=Test")
        let issuer = CertificateDistinguishedName(rawRepresentation: "CN=CA")
        let fingerprint = CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!
        let metadata = CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: CertificateSerialNumber(hexadecimal: "01")!,
            notValidBefore: Date(timeIntervalSince1970: 1_000_000),
            notValidAfter: Date(timeIntervalSince1970: 2_000_000),
            publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: fingerprint
        )
        // Metadata exists (parsing succeeded)
        XCTAssertNotNil(metadata)
        // But validity is expired when evaluated now (2026)
        let validity = CertificateValidity.evaluate(certificate: metadata, at: Date(timeIntervalSince1970: 3_000_000))
        XCTAssertEqual(validity.periodStatus, .expired)
        // Parsing succeeded ≠ currently valid
    }
}
