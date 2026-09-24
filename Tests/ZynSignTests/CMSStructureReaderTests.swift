import XCTest
@testable import ZynSign

/// Structural CMS reading over synthetic test fixtures.
///
/// Every fixture is a test-only container built by `CMSFixtures`; no real
/// provisioning profile and no production certificate appears here. These tests
/// assert what the structure reader reported, never that a profile is trusted,
/// authorized, or safe.
final class CMSStructureReaderTests: XCTestCase {

    // MARK: - Signed containers

    func testReadsSignedDataWithSignedAttributes() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.validRSASignedAttributes)

        XCTAssertEqual(structure.contentType, CMSObjectIdentifiers.signedData)
        XCTAssertEqual(structure.version, 1)
        XCTAssertEqual(structure.digestAlgorithmIdentifiers, [CMSDigestAlgorithm.sha256ObjectIdentifier])
        XCTAssertEqual(structure.encapsulatedContentType, CMSObjectIdentifiers.data)
        XCTAssertEqual(structure.certificateRevocationListCount, 0)
        XCTAssertNotNil(structure.encapsulatedContent)

        let payload = try XCTUnwrap(structure.encapsulatedContent)
        XCTAssertEqual(payload, Data(CMSFixtures.validRSASignedAttributes[CMSFixtures.validRSAEncapsulatedContentRange]))
        XCTAssertEqual(payload.count, CMSFixtures.validRSAPayloadByteCount)
    }

    func testReadsEmbeddedCertificateBagInBagOrder() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.validRSASignedAttributes)

        XCTAssertEqual(structure.certificateEncodings.count, 2)
        XCTAssertEqual(structure.certificateEncodings[0], CMSFixtures.signerCertificateDER)
        XCTAssertEqual(structure.certificateEncodings[1], CMSFixtures.issuerCertificateDER)
    }

    func testRecordsBagOrderWithoutAssigningItMeaning() throws {
        let original = try CMSStructureReader.read(CMSFixtures.validRSASignedAttributes)
        let reordered = try CMSStructureReader.read(CMSFixtures.reorderedCertificateBag)

        XCTAssertEqual(reordered.certificateEncodings.count, 2)
        XCTAssertEqual(reordered.certificateEncodings[0], CMSFixtures.issuerCertificateDER)
        XCTAssertEqual(reordered.certificateEncodings[1], CMSFixtures.signerCertificateDER)
        XCTAssertEqual(
            Set(reordered.certificateEncodings),
            Set(original.certificateEncodings)
        )
    }

    func testReadsSignerInfo() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.validRSASignedAttributes)
        let signer = try XCTUnwrap(structure.signerInfos.first)
        let expectedSerial = try AppleCertificateParser()
            .parseCertificate(derData: CMSFixtures.signerCertificateDER)
            .serialNumber

        XCTAssertEqual(structure.signerInfos.count, 1)
        XCTAssertEqual(signer.version, 1)
        XCTAssertEqual(signer.identifier, .issuerAndSerialNumber(serialContentBytes: expectedSerial.contentBytes))
        XCTAssertEqual(signer.digestAlgorithm, CMSDigestAlgorithm.sha256ObjectIdentifier)
        XCTAssertEqual(signer.signatureAlgorithm, CMSVerificationAlgorithm.rsaEncryptionObjectIdentifier)
        XCTAssertEqual(signer.signature, Data(CMSFixtures.validRSASignedAttributes[CMSFixtures.validRSASignatureRange]))
    }

    func testReadsSignedAttributesAndMessageDigest() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.validRSASignedAttributes)
        let signer = try XCTUnwrap(structure.signerInfos.first)
        let attributes = try XCTUnwrap(signer.signedAttributes)

        XCTAssertEqual(
            attributes.attributeObjectIdentifiers,
            [
                CMSObjectIdentifiers.attributeContentType,
                CMSObjectIdentifiers.attributeSigningTime,
                CMSObjectIdentifiers.attributeMessageDigest,
            ]
        )
        XCTAssertEqual(attributes.contentType, CMSObjectIdentifiers.data)
        XCTAssertEqual(
            attributes.messageDigest,
            Data(try XCTUnwrap(CertificateFingerprint(hexDigest: CMSFixtures.validRSAContentDigest)).digestBytes)
        )
        XCTAssertEqual(attributes.messageDigest?.count, 32)
        XCTAssertNotNil(attributes.verificationMessage)
    }

    func testVerificationMessageIsAttributeSetEncodingOfSignedContent() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.validRSASignedAttributes)
        let attributes = try XCTUnwrap(try XCTUnwrap(structure.signerInfos.first).signedAttributes)
        let message = try XCTUnwrap(attributes.verificationMessage)

        XCTAssertEqual(message.first, 0x31)
        XCTAssertGreaterThan(message.count, 32)
        XCTAssertLessThan(message.count, CMSFixtures.validRSASignatureRange.lowerBound)

        // The re-encoding changes only the outer tag: the same bytes appear in
        // the container under the context-specific tag the writer used.
        var asWritten = message
        asWritten[0] = 0xA0
        let offset = try XCTUnwrap(
            CMSVerificationTestSupport.firstIndex(of: asWritten, in: CMSFixtures.validRSASignedAttributes)
        )
        XCTAssertLessThan(offset, CMSFixtures.validRSASignatureRange.lowerBound)
        XCTAssertEqual(
            try XCTUnwrap(CMSVerificationTestSupport.sha256Hexadecimal(message)),
            CMSFixtures.validRSASignedAttributesMessageDigest
        )
    }

    func testReadsECDSAContainer() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.ecDSASignedAttributes)
        let signer = try XCTUnwrap(structure.signerInfos.first)
        let attributes = try XCTUnwrap(signer.signedAttributes)

        XCTAssertEqual(signer.digestAlgorithm, CMSDigestAlgorithm.sha256ObjectIdentifier)
        XCTAssertEqual(signer.signatureAlgorithm, CMSVerificationAlgorithm.ecdsaWithSHA256ObjectIdentifier)
        XCTAssertEqual(attributes.messageDigest?.count, 32)
        XCTAssertEqual(
            attributes.messageDigest,
            Data(CertificateDigest.sha256(try XCTUnwrap(structure.encapsulatedContent)))
        )
    }

    func testReadsContainerWithoutSignedAttributes() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.noSignedAttributes)
        let signer = try XCTUnwrap(structure.signerInfos.first)

        XCTAssertNil(signer.signedAttributes)
        XCTAssertEqual(signer.digestAlgorithm, CMSDigestAlgorithm.sha256ObjectIdentifier)
    }

    func testReadsSHA1ContainerAndPreservesItsIdentifiers() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.sha1DigestAlgorithm)
        let signer = try XCTUnwrap(structure.signerInfos.first)

        XCTAssertEqual(structure.digestAlgorithmIdentifiers, [CMSDigestAlgorithm.sha1ObjectIdentifier])
        XCTAssertEqual(signer.digestAlgorithm, CMSDigestAlgorithm.sha1ObjectIdentifier)
    }

    func testReadsSubjectKeyIdentifierSigner() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.subjectKeyIdentifierSigner)
        let signer = try XCTUnwrap(structure.signerInfos.first)

        if case .subjectKeyIdentifier(let identifier) = signer.identifier {
            XCTAssertEqual(identifier.count, 20)
        } else {
            XCTFail("Expected a subject key identifier signer, got \(signer.identifier)")
        }
    }

    func testReadsMultipleSignersWithoutChoosingOne() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.twoSignerInfos)

        XCTAssertEqual(structure.signerInfos.count, 2)
        XCTAssertNotEqual(
            structure.signerInfos[0].signature,
            structure.signerInfos[1].signature
        )
    }

    func testReadsContainerWithoutSignerInfos() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.noSignerInfos)

        XCTAssertTrue(structure.signerInfos.isEmpty)
        XCTAssertNotNil(structure.encapsulatedContent)
    }

    func testReadsContainerWithNoEmbeddedCertificates() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.noEmbeddedCertificates)

        XCTAssertTrue(structure.certificateEncodings.isEmpty)
        XCTAssertEqual(structure.signerInfos.count, 1)
    }

    func testPreservesUnparsableEmbeddedCertificateEncoding() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.unparsableEmbeddedCertificate)

        XCTAssertEqual(structure.certificateEncodings.count, 2)
        XCTAssertNotEqual(structure.certificateEncodings[0], CMSFixtures.signerCertificateDER)
        XCTAssertEqual(structure.certificateEncodings[1], CMSFixtures.signerCertificateDER)
    }

    func testPayloadDigestMatchesRecordedMessageDigest() throws {
        let structure = try CMSStructureReader.read(CMSFixtures.validRSASignedAttributes)
        let payload = try XCTUnwrap(structure.encapsulatedContent)
        let attributes = try XCTUnwrap(try XCTUnwrap(structure.signerInfos.first).signedAttributes)

        XCTAssertEqual(
            attributes.messageDigest,
            Data(CertificateDigest.sha256(payload))
        )
    }

    // MARK: - Rejected containers

    func testRejectsEmptyInput() {
        assertCMSError(Data(), expected: .emptyInput)
    }

    func testRejectsOversizedInput() {
        let oversized = Data(repeating: 0x30, count: ProvisioningProfileInput.maximumByteCount + 1)
        assertCMSError(oversized, expected: .inputTooLarge)
    }

    func testRejectsArmoredInput() {
        assertCMSError(CMSFixtures.armoredContainer(), expected: .unsupportedStructure)
    }

    func testRejectsNonCMSContent() {
        assertCMSError(CMSFixtures.notCMSMessage, expected: .malformedCMS)
    }

    func testRejectsUnsupportedOuterContentType() {
        assertCMSError(CMSFixtures.dataContentType, expected: .unsupportedContentType)
    }

    func testRejectsIndefiniteLengthEncoding() {
        assertCMSError(CMSFixtures.indefiniteLengthEncoding, expected: .unsupportedStructure)
    }

    func testRejectsTruncatedContainer() {
        assertCMSError(CMSFixtures.truncatedContainer(), expected: .truncatedCMS)
    }

    func testRejectsTrailingBytes() {
        assertCMSError(CMSFixtures.trailingBytes(), expected: .malformedCMS)
    }

    func testReadsTamperedContainersAndLeavesDetectionToVerification() throws {
        // A flipped byte inside encoded content does not make the container
        // unreadable; it makes the signature fail to bind. The reader reports
        // structure, so tampering is deliberately not its concern.
        for container in [
            CMSFixtures.tamperedPayload(),
            CMSFixtures.tamperedSignature(),
            CMSFixtures.tamperedMessageDigest(),
        ] {
            let structure = try CMSStructureReader.read(container)
            XCTAssertEqual(structure.signerInfos.count, 1)
            XCTAssertNotNil(structure.encapsulatedContent)
        }
    }

    func testDetachedContentParsesStructurallyWithNoPayload() throws {
        // Detached content is structurally valid: the reader reports the
        // absent payload as nil. Rejection with .payloadUnavailable happens
        // where the payload is required (see CMSVerificationTests), because
        // detached messages are the normal form for Mach-O code signatures.
        let structure = try CMSStructureReader.read(CMSFixtures.detachedContent)
        XCTAssertEqual(structure.encapsulatedContentType, CMSObjectIdentifiers.data)
        XCTAssertNil(structure.encapsulatedContent)
    }

    // MARK: - Support

    private func assertCMSError(
        _ container: Data,
        expected: CMSFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try CMSStructureReader.read(container), file: file, line: line) { error in
            guard let zynSignError = error as? ZynSignError else {
                XCTFail("Expected a typed ZynSignError, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(zynSignError.cmsFailure, expected, file: file, line: line)
            XCTAssertNotNil(zynSignError.diagnosticDetail, file: file, line: line)
            XCTAssertFalse(zynSignError.debugDescription.isEmpty, file: file, line: line)
        }
    }
}
