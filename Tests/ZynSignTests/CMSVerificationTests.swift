import XCTest
@testable import ZynSign

/// CMS verification orchestration over synthetic containers.
///
/// These tests drive the boundary with a recording signature mechanism so that
/// container reading, signer selection, attribute binding, and status mapping
/// are exercised deterministically on any platform. The actual signature
/// mathematics over real fixture keys is exercised by
/// `AppleCMSSignatureVerifierTests`, which is gated on iOS because the
/// platform primitives it uses are not available here.
///
/// Nothing asserted below is a trust, authorization, or compatibility claim.
final class CMSVerificationTests: XCTestCase {

    // MARK: - Verified container

    func testVerifiedContainerReportsEvidenceWithoutTrustOrAuthorization() throws {
        let (result, verifier) = try verify(CMSFixtures.validRSASignedAttributes)

        XCTAssertEqual(result.status, .verified)
        XCTAssertTrue(result.isSignatureVerified)
        XCTAssertNil(result.failure)
        XCTAssertNil(result.failureDetail)
        XCTAssertEqual(result.signerCount, 1)
        XCTAssertEqual(result.trustEvaluation, .notPerformed)
        XCTAssertEqual(verifier.callCount, 1)
        XCTAssertEqual(
            result.signedPayload,
            Data(CMSFixtures.validRSASignedAttributes[CMSFixtures.validRSAEncapsulatedContentRange])
        )
        XCTAssertTrue(result.description.contains("cms.status(verified)"))
        XCTAssertTrue(result.description.contains("cms.trust(notPerformed)"))
        XCTAssertFalse(
            result.description.contains(CMSFixtures.validRSAProfileUUID),
            "The diagnostic rendering must not quote payload content."
        )
        XCTAssertFalse(
            result.description.contains(CMSFixtures.validRSAProfileName),
            "The diagnostic rendering must not quote payload content."
        )
    }

    func testVerifiedContainerExtractsSignerCertificateBySerial() throws {
        let (result, _) = try verify(CMSFixtures.validRSASignedAttributes)

        XCTAssertEqual(result.signerCertificateStatus, .extracted)
        XCTAssertEqual(result.signerFingerprint?.hexDigest, CMSFixtures.signerCertificateFingerprint)
        XCTAssertEqual(result.embeddedCertificates.count, 2)
        XCTAssertEqual(result.unparsableEmbeddedCertificateCount, 0)
        XCTAssertEqual(
            result.signerIdentifier,
            .issuerAndSerialNumber(
                try XCTUnwrap(
                    CertificateSerialNumber(hexadecimal: CMSFixtures.signerCertificateSerialHexadecimal)
                )
            )
        )
    }

    func testVerifiedContainerRecordsAlgorithms() throws {
        let (result, _) = try verify(CMSFixtures.validRSASignedAttributes)

        XCTAssertEqual(result.digestAlgorithm, .recognized(.sha256))
        XCTAssertEqual(result.verificationAlgorithm, .rsaPKCS1SHA256Message)
        XCTAssertEqual(result.verificationAlgorithm?.isSupported, true)
        // The CMS names the key algorithm for an RSA signer, which the existing
        // certificate signature vocabulary preserves as unknown rather than
        // inventing a digest combination that was never declared.
        XCTAssertEqual(result.signatureAlgorithm, .unknown(CMSVerificationAlgorithm.rsaEncryptionObjectIdentifier))
    }

    func testVerifiedContainerChecksAttributesAgainstSignedBytes() throws {
        let (result, verifier) = try verify(CMSFixtures.validRSASignedAttributes)
        let call = try XCTUnwrap(verifier.lastCall)
        let structure = try CMSStructureReader.read(CMSFixtures.validRSASignedAttributes)
        let expectedMessage = try XCTUnwrap(
            try XCTUnwrap(try XCTUnwrap(structure.signerInfos.first).signedAttributes).verificationMessage
        )

        XCTAssertEqual(result.signedAttributes.present, true)
        XCTAssertEqual(result.signedAttributes.messageDigestPresent, true)
        XCTAssertEqual(result.signedAttributes.messageDigestMatchesContent, true)
        XCTAssertEqual(result.signedAttributes.contentTypeMatchesEncapsulated, true)
        XCTAssertEqual(result.signedAttributes.attributeObjectIdentifiers.count, 3)
        XCTAssertEqual(call.message, expectedMessage)
        XCTAssertEqual(call.signature, Data(CMSFixtures.validRSASignedAttributes[CMSFixtures.validRSASignatureRange]))
        XCTAssertEqual(call.algorithm, .rsaPKCS1SHA256Message)
        XCTAssertEqual(call.certificateFingerprint.hexDigest, CMSFixtures.signerCertificateFingerprint)
    }

    func testVerifiedContainerMarksPayloadAuthenticated() throws {
        let (result, _) = try verify(CMSFixtures.validRSASignedAttributes)
        let payload = try XCTUnwrap(result.profilePayload())

        XCTAssertEqual(payload.authenticity, .authenticated)
        XCTAssertEqual(payload.plistData, result.signedPayload)
    }

    func testECDSAContainerVerifiesWithItsOwnSignerCertificate() throws {
        let (result, verifier) = try verify(CMSFixtures.ecDSASignedAttributes)

        XCTAssertEqual(result.status, .verified)
        XCTAssertEqual(result.verificationAlgorithm, .ecdsaX962SHA256Message)
        XCTAssertEqual(result.signatureAlgorithm, .ecdsaWithSHA256)
        XCTAssertEqual(result.signerFingerprint?.hexDigest, CMSFixtures.ecSignerCertificateFingerprint)
        XCTAssertEqual(verifier.callCount, 1)
    }

    func testContainerWithoutSignedAttributesSignsThePayloadDirectly() throws {
        let (result, verifier) = try verify(CMSFixtures.noSignedAttributes)
        let call = try XCTUnwrap(verifier.lastCall)

        XCTAssertEqual(result.status, .verified)
        XCTAssertEqual(result.signedAttributes, .absent)
        XCTAssertEqual(call.message, result.signedPayload)
        XCTAssertEqual(verifier.callCount, 1)
    }

    // MARK: - Signer selection

    func testSignerSelectionIgnoresBagOrder() throws {
        let (result, _) = try verify(CMSFixtures.reorderedCertificateBag)

        XCTAssertEqual(result.status, .verified)
        XCTAssertEqual(result.signerCertificateStatus, .extracted)
        XCTAssertEqual(result.signerFingerprint?.hexDigest, CMSFixtures.signerCertificateFingerprint)
        XCTAssertEqual(result.embeddedCertificates.count, 2)
        XCTAssertEqual(
            result.embeddedCertificates.map { $0.fingerprint.hexDigest },
            [CMSFixtures.issuerCertificateFingerprint, CMSFixtures.signerCertificateFingerprint]
        )
    }

    func testUnparsableEmbeddedCertificateIsCountedAndDoesNotBlockSelection() throws {
        let (result, _) = try verify(CMSFixtures.unparsableEmbeddedCertificate)

        XCTAssertEqual(result.status, .verified)
        XCTAssertEqual(result.signerCertificateStatus, .extracted)
        XCTAssertEqual(result.signerFingerprint?.hexDigest, CMSFixtures.signerCertificateFingerprint)
        XCTAssertEqual(result.embeddedCertificates.count, 1)
        XCTAssertEqual(result.unparsableEmbeddedCertificateCount, 1)
    }

    func testContainerWithoutEmbeddedCertificatesReportsUnavailableSigner() throws {
        let (result, verifier) = try verify(CMSFixtures.noEmbeddedCertificates)

        XCTAssertEqual(result.status, .signerCertificateUnavailable)
        XCTAssertEqual(result.failure, .signerCertificateUnavailable)
        XCTAssertEqual(result.signerCertificateStatus, .absentFromMessage)
        XCTAssertNil(result.signerCertificate)
        XCTAssertTrue(result.embeddedCertificates.isEmpty)
        XCTAssertEqual(result.unparsableEmbeddedCertificateCount, 0)
        XCTAssertEqual(verifier.callCount, 0, "No signature may be checked without a signer certificate.")
        XCTAssertNotNil(result.signedPayload, "The payload is still evidence about the container.")
        XCTAssertEqual(result.profilePayload()?.authenticity, .notEvaluated)
        XCTAssertNotNil(result.failureDetail)
    }

    func testSignerIdentifierBySubjectKeyIdentifierIsNotMatched() throws {
        let (result, verifier) = try verify(CMSFixtures.subjectKeyIdentifierSigner)

        XCTAssertEqual(result.status, .signerCertificateUnavailable)
        XCTAssertEqual(result.signerCertificateStatus, .identifierNotMatchable)
        XCTAssertNil(result.signerCertificate)
        XCTAssertEqual(result.embeddedCertificates.count, 1)
        XCTAssertEqual(verifier.callCount, 0)
        if case .subjectKeyIdentifier(let identifier) = try XCTUnwrap(result.signerIdentifier) {
            XCTAssertEqual(identifier.count, 20)
        } else {
            XCTFail("Expected a subject key identifier.")
        }
    }

    func testNoEmbeddedCertificateMatchingSerialReportsUnparsableCandidate() throws {
        let (result, _) = try verify(CMSFixtures.unparsableEmbeddedCertificate, certificateParser: OpaqueCertificateParser())

        XCTAssertEqual(result.status, .signerCertificateUnavailable)
        XCTAssertEqual(result.signerCertificateStatus, .unparsable)
        XCTAssertTrue(result.embeddedCertificates.isEmpty)
        XCTAssertEqual(result.unparsableEmbeddedCertificateCount, 2)
    }

    func testAmbiguousSignerSelectionIsNotResolved() throws {
        // The bag names the same certificate twice, so two embedded entries
        // match the signer's serial. ZynSign reports the ambiguity instead of
        // taking the first match, which would depend on bag order.
        let (result, verifier) = try verify(CMSFixtures.duplicateEmbeddedCertificates)

        XCTAssertEqual(result.status, .signerCertificateUnavailable)
        XCTAssertEqual(result.failure, .signerCertificateUnavailable)
        XCTAssertEqual(result.signerCertificateStatus, .ambiguous)
        XCTAssertNil(result.signerCertificate)
        XCTAssertEqual(result.embeddedCertificates.count, 2)
        XCTAssertEqual(result.unparsableEmbeddedCertificateCount, 0)
        XCTAssertEqual(verifier.callCount, 0)
        XCTAssertNotNil(result.failureDetail)
    }

    // MARK: - Attribute binding

    func testTamperedPayloadBreaksAttributeBindingBeforeAnySignatureCheck() throws {
        let (result, verifier) = try verify(CMSFixtures.tamperedPayload())

        XCTAssertEqual(result.status, .invalid)
        XCTAssertEqual(result.failure, .signatureInvalid)
        XCTAssertEqual(result.signedAttributes.messageDigestMatchesContent, false)
        XCTAssertEqual(verifier.callCount, 0, "A payload the signature does not bind must not reach a signature check.")
        XCTAssertNotNil(result.signedPayload)
        XCTAssertEqual(result.profilePayload()?.authenticity, .rejected)
    }

    func testTamperedMessageDigestIsRejected() throws {
        let (result, verifier) = try verify(CMSFixtures.tamperedMessageDigest())

        XCTAssertEqual(result.status, .invalid)
        XCTAssertEqual(result.failure, .signatureInvalid)
        XCTAssertEqual(result.signedAttributes.messageDigestMatchesContent, false)
        XCTAssertEqual(verifier.callCount, 0)
    }

    func testTamperedSignatureIsRejectedByTheMechanism() throws {
        let rejecting = RecordingCMSSignatureVerifier()
        rejecting.result = false
        let (result, _) = try verify(CMSFixtures.tamperedSignature(), signatureVerifier: rejecting)

        XCTAssertEqual(result.status, .invalid)
        XCTAssertEqual(result.failure, .signatureInvalid)
        XCTAssertEqual(result.signedAttributes.messageDigestMatchesContent, true)
        XCTAssertEqual(rejecting.callCount, 1)
        XCTAssertEqual(rejecting.lastCall?.signature, Data(CMSFixtures.tamperedSignature()[CMSFixtures.validRSASignatureRange]))
    }

    func testRejectionByDigestEchoMechanismIsReportedAsInvalid() throws {
        let (result, _) = try verify(CMSFixtures.validRSASignedAttributes, signatureVerifier: DigestEchoCMSSignatureVerifier())

        XCTAssertEqual(result.status, .invalid)
        XCTAssertEqual(result.failure, .signatureInvalid)
        XCTAssertNotNil(result.failureDetail)
    }

    // MARK: - Algorithm support

    func testSHA1ContainerIsReportedUnsupportedWithoutCheckingASignature() throws {
        let (result, verifier) = try verify(CMSFixtures.sha1DigestAlgorithm)

        XCTAssertEqual(result.status, .unsupportedAlgorithm)
        XCTAssertEqual(result.failure, .unsupportedAlgorithm)
        XCTAssertEqual(result.digestAlgorithm, .recognized(.sha1))
        XCTAssertEqual(result.signatureAlgorithm, .sha1WithRSAEncryption)
        XCTAssertEqual(
            result.verificationAlgorithm,
            .unsupported(
                digestObjectIdentifier: CMSDigestAlgorithm.sha1ObjectIdentifier,
                signatureObjectIdentifier: "1.2.840.113549.1.1.5"
            )
        )
        XCTAssertEqual(result.signerCertificateStatus, .extracted)
        XCTAssertEqual(verifier.callCount, 0)
    }

    // MARK: - Signer counts

    func testContainerWithoutSignerIsNotVerified() throws {
        let (result, verifier) = try verify(CMSFixtures.noSignerInfos)

        XCTAssertEqual(result.status, .noSigner)
        XCTAssertEqual(result.failure, .signerUnavailable)
        XCTAssertEqual(result.signerCount, 0)
        XCTAssertEqual(result.signerCertificateStatus, .notSought)
        XCTAssertEqual(verifier.callCount, 0)
        XCTAssertNotNil(result.signedPayload)
        XCTAssertEqual(result.profilePayload()?.authenticity, .rejected)
    }

    func testContainerWithTwoSignersIsNotVerified() throws {
        let (result, verifier) = try verify(CMSFixtures.twoSignerInfos)

        XCTAssertEqual(result.status, .multipleSigners)
        XCTAssertEqual(result.failure, .multipleSigners)
        XCTAssertEqual(result.signerCount, 2)
        XCTAssertEqual(result.signerCertificateStatus, .notSought)
        XCTAssertEqual(verifier.callCount, 0)
    }

    // MARK: - Structural failures surface as typed errors

    func testStructuralFailuresThrowTypedErrors() {
        assertThrowsCMSFailure(Data(), expected: .emptyInput)
        assertThrowsCMSFailure(CMSFixtures.detachedContent, expected: .payloadUnavailable)
        assertThrowsCMSFailure(CMSFixtures.dataContentType, expected: .unsupportedContentType)
        assertThrowsCMSFailure(CMSFixtures.notCMSMessage, expected: .malformedCMS)
        assertThrowsCMSFailure(CMSFixtures.trailingBytes(), expected: .malformedCMS)
        assertThrowsCMSFailure(CMSFixtures.truncatedContainer(), expected: .truncatedCMS)
        assertThrowsCMSFailure(CMSFixtures.armoredContainer(), expected: .unsupportedStructure)
        assertThrowsCMSFailure(CMSFixtures.indefiniteLengthEncoding, expected: .unsupportedStructure)
        assertThrowsCMSFailure(
            Data(repeating: 0x30, count: ProvisioningProfileInput.maximumByteCount + 1),
            expected: .inputTooLarge
        )
    }

    func testStructuralFailureDetailIsRedacted() {
        XCTAssertThrowsError(try verifyOrThrow(CMSFixtures.truncatedContainer())) { error in
            guard let zynSignError = error as? ZynSignError else {
                XCTFail("Expected a typed error.")
                return
            }
            let detail = zynSignError.diagnosticDetail ?? ""
            XCTAssertFalse(detail.isEmpty)
            XCTAssertFalse(detail.contains("-----BEGIN"))
            XCTAssertFalse(detail.contains("CMSFixtures"))
        }
    }

    // MARK: - Mechanism failures

    func testUnavailableMechanismIsReportedAsUnavailableNotInvalid() throws {
        let unavailable = RecordingCMSSignatureVerifier()
        unavailable.error = ZynSignError.cms(.platformVerificationUnavailable)
        let (result, _) = try verify(CMSFixtures.validRSASignedAttributes, signatureVerifier: unavailable)

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.failure, .platformVerificationUnavailable)
        XCTAssertEqual(result.signerCertificateStatus, .extracted)
        XCTAssertEqual(result.trustEvaluation, .notPerformed)
    }

    func testUnsupportedAlgorithmFromMechanismIsNotAMismatch() throws {
        let failing = RecordingCMSSignatureVerifier()
        failing.error = ZynSignError.cms(.unsupportedAlgorithm)
        let (result, _) = try verify(CMSFixtures.validRSASignedAttributes, signatureVerifier: failing)

        XCTAssertEqual(result.status, .unsupportedAlgorithm)
        XCTAssertEqual(result.failure, .unsupportedAlgorithm)
    }

    func testUnexpectedMechanismFailureDrawsNoConclusion() throws {
        let failing = RecordingCMSSignatureVerifier()
        failing.error = ZynSignError.cms(
            .unexpectedSecurityError,
            diagnosticDetail: "SecKeyVerifySignature returned -4 (errSecUnimplemented)"
        )
        let (result, _) = try verify(CMSFixtures.validRSASignedAttributes, signatureVerifier: failing)

        XCTAssertEqual(result.status, .verificationFailed)
        XCTAssertEqual(result.failure, .unexpectedSecurityError)
        XCTAssertEqual(result.signerCertificateStatus, .extracted)
        XCTAssertNotNil(result.failureDetail)
    }

    func testUnavailableVerifierTypeReportsUnavailable() throws {
        let verifier = ProvisioningProfileCMSVerifier(
            certificateParser: AppleCertificateParser(),
            signatureVerifier: UnavailableCMSSignatureVerifier()
        )
        let result = try verifier.verify(ProvisioningProfileInput(bytes: CMSFixtures.validRSASignedAttributes))

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.failure, .platformVerificationUnavailable)
    }

    // MARK: - Payload decoder seam

    func testPayloadDecoderSeamPassesOnlyAuthenticatedPayloads() throws {
        let decoder = CMSProvisioningProfilePayloadDecoder(
            verifier: ProvisioningProfileCMSVerifier(
                certificateParser: AppleCertificateParser(),
                signatureVerifier: RecordingCMSSignatureVerifier()
            )
        )

        let payload = try decoder.decodePayload(
            from: ProvisioningProfileInput(bytes: CMSFixtures.validRSASignedAttributes)
        )
        XCTAssertEqual(payload.authenticity, .authenticated)
        XCTAssertEqual(payload.plistData.count, CMSFixtures.validRSAPayloadByteCount)
    }

    func testPayloadDecoderSeamFailsClosedOnRejectedContainer() {
        let rejecting = RecordingCMSSignatureVerifier()
        rejecting.result = false
        let decoder = CMSProvisioningProfilePayloadDecoder(
            verifier: ProvisioningProfileCMSVerifier(
                certificateParser: AppleCertificateParser(),
                signatureVerifier: rejecting
            )
        )

        XCTAssertThrowsError(
            try decoder.decodePayload(from: ProvisioningProfileInput(bytes: CMSFixtures.validRSASignedAttributes))
        ) { error in
            XCTAssertEqual((error as? ZynSignError)?.cmsFailure, .signatureInvalid)
        }
    }

    func testPayloadDecoderSeamHandsOverUnevaluatedPayloads() throws {
        let decoder = CMSProvisioningProfilePayloadDecoder(
            verifier: ProvisioningProfileCMSVerifier(
                certificateParser: AppleCertificateParser(),
                signatureVerifier: UnavailableCMSSignatureVerifier()
            )
        )

        let payload = try decoder.decodePayload(
            from: ProvisioningProfileInput(bytes: CMSFixtures.validRSASignedAttributes)
        )
        XCTAssertEqual(payload.authenticity, .notEvaluated)
    }

    // MARK: - Support

    private func verify(
        _ container: Data,
        certificateParser: any CertificateParser = AppleCertificateParser(),
        signatureVerifier: any CMSSignatureVerifier = RecordingCMSSignatureVerifier()
    ) throws -> (CMSVerificationResult, RecordingCMSSignatureVerifier) {
        let recording = signatureVerifier as? RecordingCMSSignatureVerifier ?? RecordingCMSSignatureVerifier()
        let verifier = ProvisioningProfileCMSVerifier(
            certificateParser: certificateParser,
            signatureVerifier: signatureVerifier
        )
        let result = try verifier.verify(ProvisioningProfileInput(bytes: container))
        return (result, recording)
    }

    private func verifyOrThrow(_ container: Data) throws -> CMSVerificationResult {
        let verifier = ProvisioningProfileCMSVerifier(
            certificateParser: AppleCertificateParser(),
            signatureVerifier: RecordingCMSSignatureVerifier()
        )
        return try verifier.verify(ProvisioningProfileInput(bytes: container))
    }

    private func assertThrowsCMSFailure(
        _ container: Data,
        expected: CMSFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try verifyOrThrow(container), file: file, line: line) { error in
            XCTAssertEqual((error as? ZynSignError)?.cmsFailure, expected, file: file, line: line)
        }
    }
}
