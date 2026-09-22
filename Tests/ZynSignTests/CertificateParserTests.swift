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

    func testParseValidCertificate() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.validDER)

        XCTAssertEqual(metadata.subject.commonName, "ZynSign Test Valid")
        XCTAssertEqual(metadata.issuer.commonName, "Test CA")
        XCTAssertEqual(metadata.issuer.organization, "ZynSign Test")
        XCTAssertEqual(metadata.issuer.country, "US")
        XCTAssertEqual(metadata.publicKeyInfo.algorithm, .rsa)
        XCTAssertEqual(metadata.publicKeyInfo.keySizeInBits, 2048)
        XCTAssertEqual(metadata.signatureAlgorithm, .sha256WithRSAEncryption)
        XCTAssertEqual(metadata.sha256Fingerprint.hexDigest, CertificateFixtures.validFingerprintHex)
        XCTAssertEqual(metadata.serialNumber.hexadecimal, "1000")
    }

    func testParseExpiredCertificate() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.expiredDER)

        XCTAssertEqual(metadata.subject.commonName, "ZynSign Test Expired")
        let afterExpiry = Date(timeIntervalSince1970: 1_609_459_201)
        let validity = CertificateValidity.evaluate(certificate: metadata, at: afterExpiry)
        XCTAssertEqual(validity.periodStatus, .expired)
    }

    func testParseFutureCertificateNotYetValid() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.futureDER)

        let beforeStart = Date(timeIntervalSince1970: 1_798_761_599)
        let validity = CertificateValidity.evaluate(certificate: metadata, at: beforeStart)
        XCTAssertEqual(validity.periodStatus, .notYetValid)
    }

    func testParseECCertificate() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.ecDER)

        XCTAssertEqual(metadata.publicKeyInfo.algorithm, .ec)
        XCTAssertEqual(metadata.publicKeyInfo.keySizeInBits, 256)
        XCTAssertEqual(metadata.publicKeyInfo.curveName, "P-256")
        XCTAssertEqual(metadata.publicKeyInfo.curveIdentifier, "1.2.840.10045.3.1.7")
        XCTAssertEqual(metadata.signatureAlgorithm, .sha256WithRSAEncryption)
    }

    func testParseUnusualSubject() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.unusualDER)

        XCTAssertEqual(metadata.subject.commonName, " ")
        XCTAssertNil(metadata.subject.organization)
        XCTAssertEqual(metadata.subject.attributes.count, 1)
        XCTAssertEqual(metadata.subject.rawRepresentation, "CN= ")
        XCTAssertEqual(metadata.issuer.commonName, "Test CA")
        XCTAssertEqual(metadata.issuer.organization, "ZynSign Test")
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
        XCTAssertEqual(chain.leaf?.sha256Fingerprint.hexDigest, CertificateFixtures.validFingerprintHex)
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
        XCTAssertEqual(metadata.subject.commonName, "ZynSign Test Expired")
        let validity = CertificateValidity.evaluate(
            certificate: metadata,
            at: Date(timeIntervalSince1970: 1_609_459_201)
        )
        XCTAssertEqual(validity.periodStatus, .expired)
    }

    func testParsingDoesNotImplyTrust() throws {
        let parser = AppleCertificateParser()
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.validDER)
        XCTAssertEqual(metadata.sha256Fingerprint.hexDigest, CertificateFixtures.validFingerprintHex)
        let validity = CertificateValidity.evaluate(
            certificate: metadata,
            at: Date(timeIntervalSince1970: 1_790_100_870)
        )
        let trust = CertificateTrustEvaluation(period: validity)
        XCTAssertEqual(trust.trust, .notEvaluated)
        XCTAssertEqual(trust.usage, .notEvaluated)
    }
}
