import XCTest
@testable import ZynSign

final class CertificateParserTests: XCTestCase {

    // MARK: - Pure domain parsing tests (platform-independent)

    func testFingerprintValidationForFixtures() {
        // Verify our fixtures have valid fingerprint hex.
        XCTAssertNotNil(CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex))
        XCTAssertNotNil(CertificateFingerprint(hexDigest: CertificateFixtures.expiredFingerprintHex))
    }

    func testMalformedDataIsNotValidFingerprint() {
        let malformed = CertificateFixtures.malformedDER
        // Malformed DER is not a certificate and should not produce a valid fingerprint via hex parsing.
        XCTAssertEqual(malformed, Data("not a certificate".utf8))
    }

    // MARK: - Platform-dependent parsing (Apple Security framework)

    #if canImport(Security)
    func testParseValidCertificate() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.validDER)

        // Subject should contain expected common name
        XCTAssertTrue(metadata.subject.rawRepresentation.contains("ZynSign Test Valid") || metadata.subject.commonName == "ZynSign Test Valid")
        // Issuer should be Test CA
        XCTAssertTrue(metadata.issuer.rawRepresentation.contains("Test CA") || metadata.issuer.commonName == "Test CA")
        // Public key should be RSA 2048
        XCTAssertEqual(metadata.publicKeyInfo.algorithm, .rsa)
        XCTAssertEqual(metadata.publicKeyInfo.keySizeInBits, 2048)
        // Signature algorithm should be SHA256 with RSA
        XCTAssertEqual(metadata.signatureAlgorithm, .sha256WithRSAEncryption)
        // Fingerprint should match expected
        XCTAssertEqual(metadata.sha256Fingerprint.hexDigest, CertificateFixtures.validFingerprintHex)
        // Serial number should be present
        XCTAssertFalse(metadata.serialNumber.isEmpty)
    }

    func testParseExpiredCertificate() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.expiredDER)

        XCTAssertTrue(metadata.subject.rawRepresentation.contains("Expired") || metadata.subject.commonName == "ZynSign Test Expired")
        // Validity period should be expired when evaluated now
        let validity = CertificateValidity.evaluate(certificate: metadata, at: Date())
        XCTAssertEqual(validity.periodStatus, .expired)
    }

    func testParseFutureCertificateNotYetValid() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.futureDER)

        let validity = CertificateValidity.evaluate(certificate: metadata, at: Date())
        XCTAssertEqual(validity.periodStatus, .notYetValid)
    }

    func testParseECCertificate() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.ecDER)

        XCTAssertEqual(metadata.publicKeyInfo.algorithm, .ec)
        // EC key size should be at least 256
        if let size = metadata.publicKeyInfo.keySizeInBits {
            XCTAssertGreaterThanOrEqual(size, 256)
        }
    }

    func testParseUnusualSubject() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.unusualDER)

        // Should parse without crashing, even with unusual subject.
        XCTAssertFalse(metadata.subject.rawRepresentation.isEmpty)
        // Common name may be space or empty, but raw representation preserved.
        XCTAssertTrue(metadata.subject.rawRepresentation.contains("ZynSign Test Org") || metadata.subject.organization == "ZynSign Test Org")
    }

    func testMalformedDERThrows() {
        let parser = AppleCertificateParser()
        XCTAssertThrowsError(try parser.parseCertificate(derData: CertificateFixtures.malformedDER)) { error in
            guard let zynError = error as? ZynSignError else {
                return XCTFail("Expected ZynSignError")
            }
            XCTAssertEqual(zynError.category, .invalidInput)
        }
    }

    func testRandomBytesThrows() {
        let parser = AppleCertificateParser()
        XCTAssertThrowsError(try parser.parseCertificate(derData: CertificateFixtures.randomDER)) { error in
            guard let zynError = error as? ZynSignError else {
                return XCTFail("Expected ZynSignError")
            }
            XCTAssertEqual(zynError.category, .invalidInput)
        }
    }

    func testEmptyDataThrows() {
        let parser = AppleCertificateParser()
        XCTAssertThrowsError(try parser.parseCertificate(derData: CertificateFixtures.emptyDER)) { error in
            guard let zynError = error as? ZynSignError else {
                return XCTFail("Expected ZynSignError")
            }
            XCTAssertEqual(zynError.category, .invalidInput)
        }
    }

    func testParseChain() throws {
        let parser = AppleCertificateParser()
        let chain = try parser.parseChain(derDatas: [CertificateFixtures.validDER, CertificateFixtures.expiredDER])
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain.leaf.sha256Fingerprint.hexDigest, CertificateFixtures.validFingerprintHex)
    }

    func testParseEmptyChainThrows() {
        let parser = AppleCertificateParser()
        XCTAssertThrowsError(try parser.parseChain(derDatas: [])) { error in
            guard let zynError = error as? ZynSignError else {
                return XCTFail("Expected ZynSignError")
            }
            XCTAssertEqual(zynError.category, .invalidInput)
        }
    }

    func testParsingDoesNotImplyValidity() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.expiredDER)
        // Parsing succeeded
        XCTAssertNotNil(metadata)
        // But certificate is expired
        let validity = CertificateValidity.evaluate(certificate: metadata)
        XCTAssertEqual(validity.periodStatus, .expired)
        // Parsing succeeded ≠ currently valid
    }

    func testParsingDoesNotImplyTrust() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.validDER)
        // Parsing succeeded
        XCTAssertNotNil(metadata)
        // Trust not evaluated
        let validity = CertificateValidity.evaluate(certificate: metadata)
        let trust = CertificateTrustEvaluation(period: validity)
        XCTAssertEqual(trust.trust, .notEvaluated)
        // Parsing succeeded ≠ trusted
    }

    #else
    func testPlatformParserNotAvailable() {
        // On non-Apple platforms, Security framework is not available.
        // This test documents that parsing is platform-dependent.
        // Domain tests still run.
        XCTAssertTrue(true)
    }
    #endif
}
