import XCTest
@testable import ZynSign

final class CertificateInspectionTests: XCTestCase {

    private let parser = AppleCertificateParser()

    func testShortSerialIsExactOctet() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.shortSerialDER)
        XCTAssertEqual(metadata.serialNumber.hexadecimal, "07")
        XCTAssertEqual(metadata.serialNumber.contentByteCount, 1)
    }

    func testLeadingZeroSerialIsNotCollapsed() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.leadingZeroSerialDER)
        XCTAssertEqual(metadata.serialNumber.hexadecimal, "0080")
        XCTAssertNotEqual(metadata.serialNumber, CertificateSerialNumber(hexadecimal: "80")!)
        XCTAssertEqual(
            metadata.sha256Fingerprint.hexDigest,
            "70411443d1487c3daa7136fc4191a52d18ae78bf454e583d25d79641de77a0fd"
        )
    }

    func testLongSerialIsNotAMachineInteger() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.longSerialDER)
        XCTAssertEqual(metadata.serialNumber.hexadecimal, "0102030405060708090a0b0c0d0e0f1011121314")
        XCTAssertNil(UInt64(metadata.serialNumber.hexadecimal, radix: 16))
        XCTAssertEqual(
            metadata.sha256Fingerprint.hexDigest,
            "55433c355098d315d971f6fb271dd3022bbb2da0d57be801a9cc23778e2cabaf"
        )
    }

    func testMultiAttributeNamePreservesEveryValue() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.multiAttributeDER)
        let subject = metadata.subject
        XCTAssertEqual(subject.country, "US")
        XCTAssertEqual(subject.stateOrProvince, "California")
        XCTAssertEqual(subject.locality, "Cupertino")
        XCTAssertEqual(subject.organization, "ZynSign Test Org")
        XCTAssertEqual(subject.organizationalUnit, "Test Unit")
        XCTAssertEqual(subject.commonName, "ZynSign Multi")
        XCTAssertEqual(subject.emailAddress, "test@example.invalid")
        let units = subject.attributes.filter { $0.recognition == .organizationalUnit }.compactMap(\.text)
        XCTAssertEqual(units, ["Test Unit", "Second Unit"])
        XCTAssertEqual(subject.attributes.count, 8)
        XCTAssertEqual(
            subject.rawRepresentation,
            "C=US, ST=California, L=Cupertino, O=ZynSign Test Org, OU=Test Unit, OU=Second Unit, CN=ZynSign Multi, emailAddress=test@example.invalid"
        )
        XCTAssertEqual(subject.rawRepresentation, metadata.issuer.rawRepresentation)
        XCTAssertTrue(metadata.isSelfSigned)
    }

    func testUnknownNameAttributeIsPreserved() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.unknownAttributeDER)
        XCTAssertEqual(metadata.subject.commonName, "ZynSign Unknown Attribute")
        XCTAssertEqual(metadata.subject.organization, "ZynSign Test Org")
        let unknown = metadata.subject.attributes.first { $0.recognition == .unrecognized }
        XCTAssertEqual(unknown?.objectIdentifier, "1.3.6.1.4.1.99999.1")
        XCTAssertEqual(unknown?.text, "preserved-unknown")
        XCTAssertEqual(unknown?.shortLabel, "1.3.6.1.4.1.99999.1")
        XCTAssertEqual(
            metadata.sha256Fingerprint.hexDigest,
            "bf09b3774434ea40532ed6376b22754ba3de255f59999b4950e0fb1900d67372"
        )
    }

    func testECDSASignatureIsNotInferredFromTheKey() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.ecdsaDER)
        XCTAssertEqual(metadata.signatureAlgorithm, .ecdsaWithSHA256)
        XCTAssertEqual(metadata.publicKeyInfo.algorithm, .ec)
        XCTAssertEqual(metadata.publicKeyInfo.keySizeInBits, 256)
        XCTAssertEqual(metadata.publicKeyInfo.curveName, "P-256")
        XCTAssertEqual(metadata.publicKeyInfo.curveIdentifier, "1.2.840.10045.3.1.7")
        XCTAssertEqual(
            metadata.sha256Fingerprint.hexDigest,
            "82683137f15f9d26fa68292627a016c48aee4a878de135d9251f07f4decca3ac"
        )
    }

    func testEmbeddedECCertificateKeepsRSASignatureAndECKey() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.ecDER)
        XCTAssertEqual(metadata.signatureAlgorithm, .sha256WithRSAEncryption)
        XCTAssertEqual(metadata.publicKeyInfo.algorithm, .ec)
        XCTAssertNotEqual(metadata.publicKeyInfo.algorithm, .rsa)
    }

    func testEd25519ParsesWithoutInventingAKeySize() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.ed25519DER)
        XCTAssertEqual(metadata.signatureAlgorithm, .ed25519)
        XCTAssertEqual(metadata.publicKeyInfo.algorithm, .unknown("1.3.101.112"))
        XCTAssertNil(metadata.publicKeyInfo.keySizeInBits)
        XCTAssertNil(metadata.publicKeyInfo.curveName)
        XCTAssertNil(metadata.publicKeyInfo.curveIdentifier)
        XCTAssertEqual(
            metadata.sha256Fingerprint.hexDigest,
            "85405d03066b4cd2bb935f0bfead47f61171680684d8f19214e6762f67df6207"
        )
        let suitability = CodeSigningSuitability.evaluate(
            metadata: metadata,
            evaluationDate: Date(timeIntervalSince1970: 1_790_102_524)
        )
        XCTAssertTrue(suitability.isParseable)
        XCTAssertFalse(suitability.appearsSuitableForCodeSigning)
        XCTAssertTrue(suitability.unsuitabilityReasons.contains(.unknownKeyAlgorithm))
    }

    func testUnknownSignatureAlgorithmDoesNotHideTheKey() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.unknownSignatureDER)
        XCTAssertEqual(metadata.signatureAlgorithm, .unknown("1.2.840.113549.1.1.99"))
        XCTAssertEqual(metadata.publicKeyInfo.algorithm, .rsa)
        XCTAssertEqual(metadata.publicKeyInfo.keySizeInBits, 2048)
        XCTAssertEqual(metadata.serialNumber.hexadecimal, "07")
        XCTAssertEqual(
            metadata.sha256Fingerprint.hexDigest,
            "3a2ecc1da9705f0ee7dde10ca12ed7bddc9d99f4eb937c7a52e2d9e84d03d186"
        )
    }

    func testGeneralizedTimeAndTinyKey() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.generalizedTimeDER)
        XCTAssertEqual(metadata.serialNumber.hexadecimal, "2a")
        XCTAssertEqual(metadata.notValidBefore.timeIntervalSince1970, 2_524_608_000, accuracy: 0.001)
        XCTAssertEqual(metadata.notValidAfter.timeIntervalSince1970, 2_556_144_000.5, accuracy: 0.001)
        XCTAssertEqual(metadata.publicKeyInfo.algorithm, .rsa)
        XCTAssertEqual(metadata.publicKeyInfo.keySizeInBits, 8)
        XCTAssertEqual(metadata.signatureAlgorithm, .sha256WithRSAEncryption)
        XCTAssertEqual(
            metadata.sha256Fingerprint.hexDigest,
            "d2531c1570e2f8652b83009be4dcc16feeb7c455d0f6b9e76454c36316ad36db"
        )
    }

    func testNamedCurveSizeForP521IsNotRounded() {
        XCTAssertEqual(CertificateAlgorithmIdentifiers.namedCurve(for: "1.3.132.0.35")?.sizeInBits, 521)
        XCTAssertEqual(CertificateAlgorithmIdentifiers.namedCurve(for: "1.3.132.0.34")?.sizeInBits, 384)
        XCTAssertNil(CertificateAlgorithmIdentifiers.namedCurve(for: "1.2.3.4"))
    }

    func testRepeatedParseIsDeterministic() throws {
        let first = try parser.parseCertificate(derData: CertificateFixtures.multiAttributeDER)
        let second = try parser.parseCertificate(derData: CertificateFixtures.multiAttributeDER)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.serialNumber, second.serialNumber)
        XCTAssertEqual(first.sha256Fingerprint, second.sha256Fingerprint)
        XCTAssertEqual(first.subject, second.subject)
    }

    func testValidityBoundariesUseTheInjectedClock() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.validDER)
        let notBefore = metadata.notValidBefore
        let notAfter = metadata.notValidAfter
        XCTAssertEqual(notBefore.timeIntervalSince1970, 1_790_100_870, accuracy: 0.001)
        XCTAssertEqual(notAfter.timeIntervalSince1970, 1_821_636_870, accuracy: 0.001)

        func status(at instant: Date) throws -> CertificateValidityPeriodStatus {
            let inspection = try CertificateInspector(
                parser: parser,
                clock: FixedEvaluationClock(instant: instant)
            ).inspect(CertificateInput(bytes: CertificateFixtures.validDER))
            XCTAssertEqual(inspection.validity.evaluationDate, instant)
            XCTAssertEqual(inspection.trustStatus, .notEvaluated)
            XCTAssertEqual(inspection.certificate.derData, CertificateFixtures.validDER)
            return inspection.validity.periodStatus
        }

        XCTAssertEqual(try status(at: notBefore.addingTimeInterval(-1)), .notYetValid)
        XCTAssertEqual(try status(at: notBefore), .currentlyValid)
        XCTAssertEqual(try status(at: notAfter), .currentlyValid)
        XCTAssertEqual(try status(at: notAfter.addingTimeInterval(1)), .expired)
    }

    func testExpiredBoundaryIsInclusive() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.expiredDER)
        let atEnd = CertificateValidity.evaluate(certificate: metadata, at: metadata.notValidAfter)
        let afterEnd = CertificateValidity.evaluate(
            certificate: metadata,
            clock: FixedEvaluationClock(instant: metadata.notValidAfter.addingTimeInterval(1))
        )
        XCTAssertEqual(atEnd.periodStatus, .currentlyValid)
        XCTAssertEqual(afterEnd.periodStatus, .expired)
        XCTAssertEqual(afterEnd.evaluationDate, metadata.notValidAfter.addingTimeInterval(1))
    }

    func testInspectionDoesNotEvaluateTrust() throws {
        let clock = FixedEvaluationClock(instant: Date(timeIntervalSince1970: 0))
        let inspection = try CompositionRoot.makeCertificateInspector(parser: parser, clock: clock)
            .inspect(CertificateInput(bytes: CertificateFixtures.validDER))
        XCTAssertEqual(inspection.trustStatus, .notEvaluated)
        XCTAssertEqual(inspection.validity.periodStatus, .notYetValid)
        XCTAssertEqual(inspection.validity.evaluationDate, clock.instant)
    }

    func testChainReturnsIssuerMetadataWithoutTrust() throws {
        let chain = try parser.parseChain(derDatas: [
            CertificateFixtures.shortSerialDER,
            CertificateFixtures.longSerialDER
        ])
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain.leaf?.issuer.commonName, "Short Serial")
        XCTAssertNotEqual(chain.leaf?.issuer.commonName, chain.certificates[1].subject.commonName)
    }

    func testEmptyInputIsDistinct() {
        assertThrows(Data(), message: "The certificate file is empty.", category: .invalidInput)
    }

    func testTruncatedInputIsDistinct() {
        let prefix = CertificateFixtures.validDER.prefix(12)
        assertThrows(
            Data(prefix),
            message: "The certificate file is incomplete.",
            category: .invalidInput,
            absentFromDiagnostic: "MIID"
        )
    }

    func testMalformedInputDoesNotEchoBytes() {
        assertThrows(
            CertificateFixtures.malformedDER,
            message: "The certificate is not a valid certificate.",
            category: .invalidInput,
            absentFromDiagnostic: "not a certificate"
        )
    }

    func testPEMIsUnsupportedFormat() {
        let pem = Data("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n".utf8)
        assertThrows(pem, message: "The certificate is not in a supported format.", category: .unsupportedInput)
    }

    func testIndefiniteLengthIsUnsupportedFormat() {
        assertThrows(
            Data([0x30, 0x80, 0x00, 0x00]),
            message: "The certificate is not in a supported format.",
            category: .unsupportedInput
        )
    }

    func testNonMinimalLengthIsInvalid() {
        assertThrows(
            Data([0x30, 0x81, 0x01, 0x00]),
            message: "The certificate is not a valid certificate.",
            category: .invalidInput
        )
    }

    func testOversizedInputIsRejectedBeforeParsing() {
        let oversized = Data(count: CertificateInput.maximumByteCount + 1)
        assertThrows(
            oversized,
            message: "The certificate file is too large to inspect.",
            category: .invalidInput
        )
    }

    func testTrailingByteIsRejected() {
        var bytes = [UInt8](CertificateFixtures.shortSerialDER)
        bytes.append(0x00)
        assertThrows(Data(bytes), message: "The certificate is not a valid certificate.", category: .invalidInput)
    }

    func testMismatchedSignatureIdentifiersAreRejected() {
        var bytes = [UInt8](CertificateFixtures.generalizedTimeDER)
        let oid = [UInt8]([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])
        guard let last = bytes.indices.reversed().first(where: { index in
            index + oid.count <= bytes.count && Array(bytes[index..<(index + oid.count)]) == oid
        }) else {
            return XCTFail("Fixture no longer contains the signature algorithm identifier")
        }
        bytes[last + oid.count - 1] = 0x0C
        assertThrows(Data(bytes), message: "The certificate is not a valid certificate.", category: .invalidInput)
    }

    func testFingerprintIsNotATrustDecision() throws {
        let metadata = try parser.parseCertificate(derData: CertificateFixtures.validDER)
        XCTAssertFalse(metadata.sha256Fingerprint.hexDigest.isEmpty)
        let trust = CertificateTrustEvaluation(
            period: CertificateValidity.evaluate(
                certificate: metadata,
                at: metadata.notValidBefore
            )
        )
        XCTAssertEqual(trust.trust, .notEvaluated)
    }

    private func assertThrows(
        _ data: Data,
        message: String,
        category: DiagnosticCategory,
        absentFromDiagnostic: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try parser.parseCertificate(CertificateInput(bytes: data)), file: file, line: line) { error in
            guard let zynError = error as? ZynSignError else {
                return XCTFail("Expected ZynSignError", file: file, line: line)
            }
            XCTAssertEqual(zynError.category, category, file: file, line: line)
            XCTAssertEqual(zynError.userMessage, message, file: file, line: line)
            XCTAssertFalse(zynError.userMessage.contains("private"), file: file, line: line)
            if let absentFromDiagnostic {
                XCTAssertFalse(zynError.diagnosticDetail?.contains(absentFromDiagnostic) ?? false, file: file, line: line)
                XCTAssertFalse(zynError.userMessage.contains(absentFromDiagnostic), file: file, line: line)
            }
            XCTAssertLessThan(zynError.diagnosticDetail?.count ?? 0, 120, file: file, line: line)
        }
    }
}
