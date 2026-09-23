import XCTest
@testable import ZynSign

/// The CMS boundary's vocabulary and failure model.
///
/// These are pure model tests: algorithm mapping, status classification,
/// identifier redaction, and error construction. They matter because a mapped
/// algorithm decides whether a signature is checked at all, and a status
/// decides whether an outcome is a rejection or an absence of evidence.
final class CMSVerificationModelTests: XCTestCase {

    // MARK: - Digest algorithms

    func testRecognisedDigestsReuseTheExistingVocabulary() {
        XCTAssertEqual(CMSDigestAlgorithm.from(objectIdentifier: "2.16.840.1.101.3.4.2.1"), .recognized(.sha256))
        XCTAssertEqual(CMSDigestAlgorithm.from(objectIdentifier: "1.3.14.3.2.26"), .recognized(.sha1))
        XCTAssertEqual(CMSDigestAlgorithm.from(objectIdentifier: "2.16.840.1.101.3.4.2.2"), .recognized(.sha384))
        XCTAssertEqual(CMSDigestAlgorithm.from(objectIdentifier: "2.16.840.1.101.3.4.2.3"), .recognized(.sha512))
        XCTAssertEqual(CMSDigestAlgorithm.from(objectIdentifier: "2.16.840.1.101.3.4.2.1").digestLength, 32)
    }

    func testUnrecognisedDigestsArePreservedExactly() {
        let digest = CMSDigestAlgorithm.from(objectIdentifier: "1.2.3.4.5")

        XCTAssertEqual(digest, .unknown("1.2.3.4.5"))
        XCTAssertEqual(digest.isRecognised, false)
        XCTAssertNil(digest.digestLength)
        XCTAssertEqual(digest.displayName, "1.2.3.4.5")
    }

    // MARK: - Verification algorithm mapping

    func testSupportedPairsMapOntoVerificationOperations() {
        XCTAssertEqual(
            CMSVerificationAlgorithm.from(
                digestObjectIdentifier: "2.16.840.1.101.3.4.2.1",
                signatureObjectIdentifier: "1.2.840.113549.1.1.1"
            ),
            .rsaPKCS1SHA256Message
        )
        XCTAssertEqual(
            CMSVerificationAlgorithm.from(
                digestObjectIdentifier: "2.16.840.1.101.3.4.2.1",
                signatureObjectIdentifier: "1.2.840.113549.1.1.11"
            ),
            .rsaPKCS1SHA256Message
        )
        XCTAssertEqual(
            CMSVerificationAlgorithm.from(
                digestObjectIdentifier: "2.16.840.1.101.3.4.2.1",
                signatureObjectIdentifier: "1.2.840.10045.4.3.2"
            ),
            .ecdsaX962SHA256Message
        )
        XCTAssertTrue(CMSVerificationAlgorithm.rsaPKCS1SHA256Message.isSupported)
        XCTAssertTrue(CMSVerificationAlgorithm.ecdsaX962SHA256Message.isSupported)
    }

    func testUnsupportedPairsKeepBothIdentifiers() {
        let pairs = [
            ("1.3.14.3.2.26", "1.2.840.113549.1.1.1"),
            ("1.3.14.3.2.26", "1.2.840.113549.1.1.5"),
            ("2.16.840.1.101.3.4.2.2", "1.2.840.113549.1.1.12"),
            ("2.16.840.1.101.3.4.2.1", "1.3.101.112"),
            ("2.16.840.1.101.3.4.2.1", "1.2.3.4.5"),
        ]
        for (digest, signature) in pairs {
            let algorithm = CMSVerificationAlgorithm.from(
                digestObjectIdentifier: digest,
                signatureObjectIdentifier: signature
            )
            XCTAssertEqual(algorithm, .unsupported(digestObjectIdentifier: digest, signatureObjectIdentifier: signature))
            XCTAssertFalse(algorithm.isSupported)
            XCTAssertTrue(algorithm.displayName.contains(digest))
            XCTAssertTrue(algorithm.displayName.contains(signature))
        }
    }

    // MARK: - Status classification

    func testStatusesClassifyRejectionAndAbsenceOfEvidenceSeparately() {
        let rejections: [CMSSignatureVerificationStatus] = [.invalid, .noSigner, .multipleSigners]
        let unevaluated: [CMSSignatureVerificationStatus] = [
            .signerCertificateUnavailable,
            .unsupportedAlgorithm,
            .unavailable,
            .verificationFailed,
        ]

        XCTAssertTrue(CMSSignatureVerificationStatus.verified.isVerified)
        XCTAssertFalse(CMSSignatureVerificationStatus.verified.isRejection)
        for status in rejections {
            XCTAssertTrue(status.isRejection, "\(status) should reject the container")
            XCTAssertFalse(status.isVerified)
            XCTAssertFalse(status.isUnevaluated)
        }
        for status in unevaluated {
            XCTAssertTrue(status.isUnevaluated, "\(status) must not be reported as a rejection")
            XCTAssertFalse(status.isRejection)
            XCTAssertFalse(status.isVerified)
        }
        XCTAssertEqual(CMSSignatureVerificationStatus.allCases.count, 8)
    }

    func testSignerCertificateStatusesDoNotImplyTrust() {
        XCTAssertTrue(CMSSignerCertificateStatus.extracted.isExtracted)
        for status in CMSSignerCertificateStatus.allCases where status != .extracted {
            XCTAssertFalse(status.isExtracted)
        }
    }

    func testTrustEvaluationHasOnlyTheNotPerformedState() {
        XCTAssertEqual(CMSTrustEvaluationStatus.allCases, [.notPerformed])
    }

    // MARK: - Identifier redaction

    func testSignerIdentifierDiagnosticsNeverQuoteRawBytes() throws {
        let serial = try XCTUnwrap(CertificateSerialNumber(hexadecimal: "0102ff"))
        let identifier: CMSSignerIdentifier = .issuerAndSerialNumber(serial)

        XCTAssertTrue(identifier.isMatchable)
        XCTAssertEqual(identifier.diagnosticDescription, "issuerAndSerialNumber(serial 0102ff)")

        let keyIdentifier = CMSSignerIdentifier.subjectKeyIdentifier(Data(repeating: 0xAB, count: 20))
        XCTAssertFalse(keyIdentifier.isMatchable)
        XCTAssertEqual(keyIdentifier.diagnosticDescription, "subjectKeyIdentifier(20 bytes)")
        XCTAssertFalse(keyIdentifier.diagnosticDescription.lowercased().contains("ab"))
    }

    // MARK: - Signed attribute observation

    func testAbsentObservationClaimsNothing() {
        let observation = CMSSignedAttributeObservation.absent

        XCTAssertFalse(observation.present)
        XCTAssertTrue(observation.attributeObjectIdentifiers.isEmpty)
        XCTAssertFalse(observation.messageDigestPresent)
        XCTAssertNil(observation.messageDigestMatchesContent)
        XCTAssertFalse(observation.contentTypePresent)
        XCTAssertNil(observation.contentTypeMatchesEncapsulated)
    }

    // MARK: - Failure model

    func testEveryCMSFailureHasACategoryAndAMessage() {
        for failure in CMSFailure.allCases {
            XCTAssertFalse(failure.userMessage.isEmpty, "\(failure) needs a user message")
            XCTAssertFalse(failure.rawValue.isEmpty)
            XCTAssertNotNil(DiagnosticCategory(rawValue: failure.category.rawValue))
        }
        XCTAssertEqual(CMSFailure.allCases.count, 18)
    }

    func testCMSFailureCategories() {
        XCTAssertEqual(CMSFailure.unsupportedAlgorithm.category, .unsupportedInput)
        XCTAssertEqual(CMSFailure.unsupportedStructure.category, .unsupportedInput)
        XCTAssertEqual(CMSFailure.platformVerificationUnavailable.category, .capabilityUnavailable)
        XCTAssertEqual(CMSFailure.decodeFailed.category, .internalFailure)
        XCTAssertEqual(CMSFailure.unexpectedSecurityError.category, .internalFailure)
        XCTAssertEqual(CMSFailure.malformedCMS.category, .invalidInput)
        XCTAssertEqual(CMSFailure.signatureInvalid.category, .invalidInput)
    }

    func testCMSFailureNeverCarriesPayloadBytes() {
        for failure in CMSFailure.allCases {
            let error = ZynSignError.cms(failure, diagnosticDetail: "structural detail")
            XCTAssertEqual(error.cmsFailure, failure)
            XCTAssertEqual(error.userMessage, failure.userMessage)
            XCTAssertEqual(error.diagnosticDetail, "structural detail")
            XCTAssertTrue(error.debugDescription.contains(failure.rawValue))
            XCTAssertFalse(error.userMessage.contains("-----BEGIN"))
        }
    }

    func testSanitizedCMSFailureKeepsOnlyKnownReasons() {
        let typed = ZynSignError.cms(.truncatedCMS, diagnosticDetail: "detail that must be dropped")
        let sanitizedTyped = ZynSignError.sanitizedCMSFailure(typed)
        XCTAssertEqual(sanitizedTyped.cmsFailure, .truncatedCMS)
        XCTAssertNil(sanitizedTyped.diagnosticDetail)

        let foreign = NSError(
            domain: "com.example.private",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "private platform prose"]
        )
        let sanitizedForeign = ZynSignError.sanitizedCMSFailure(foreign)
        XCTAssertEqual(sanitizedForeign.cmsFailure, .unexpectedSecurityError)
        XCTAssertFalse(sanitizedForeign.debugDescription.contains("private platform prose"))
        XCTAssertFalse(sanitizedForeign.userMessage.contains("private platform prose"))
    }

    // MARK: - Unavailable mechanism

    func testUnavailableMechanismThrowsRatherThanReturningFalse() throws {
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)

        XCTAssertThrowsError(
            try UnavailableCMSSignatureVerifier().verify(
                message: Data([0x01]),
                signature: Data([0x02]),
                algorithm: .rsaPKCS1SHA256Message,
                certificate: certificate
            )
        ) { error in
            XCTAssertEqual((error as? ZynSignError)?.cmsFailure, .platformVerificationUnavailable)
        }
    }

    // MARK: - Result semantics

    func testResultReportsPayloadAuthenticityPerOutcome() {
        let payload = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74])

        XCTAssertEqual(
            CMSVerificationResult(status: .verified, signerCount: 1, signedPayload: payload)
                .profilePayload()?.authenticity,
            .authenticated
        )
        XCTAssertEqual(
            CMSVerificationResult(status: .invalid, signerCount: 1, signedPayload: payload)
                .profilePayload()?.authenticity,
            .rejected
        )
        XCTAssertEqual(
            CMSVerificationResult(status: .noSigner, signerCount: 0, signedPayload: payload)
                .profilePayload()?.authenticity,
            .rejected
        )
        XCTAssertEqual(
            CMSVerificationResult(status: .unavailable, signerCount: 1, signedPayload: payload)
                .profilePayload()?.authenticity,
            .notEvaluated
        )
        XCTAssertNil(CMSVerificationResult(status: .verified, signerCount: 1).profilePayload())
    }

    func testResultDefaultsRecordThatNothingWasEvaluated() {
        let result = CMSVerificationResult(status: .verificationFailed, signerCount: 0)

        XCTAssertNil(result.failure)
        XCTAssertNil(result.signedPayload)
        XCTAssertNil(result.signerCertificate)
        XCTAssertNil(result.signerFingerprint)
        XCTAssertEqual(result.signerCertificateStatus, .notSought)
        XCTAssertTrue(result.embeddedCertificates.isEmpty)
        XCTAssertEqual(result.unparsableEmbeddedCertificateCount, 0)
        XCTAssertEqual(result.signedAttributes, .absent)
        XCTAssertEqual(result.trustEvaluation, .notPerformed)
    }
}
