import XCTest
@testable import ZynSign

/// Profile verification orchestration: the sequence from container to evidence.
///
/// These tests are the ones that hold the separation of states in place. A
/// parsed profile is not a structurally valid profile; a structurally valid
/// profile is not cryptographically authentic; an authentic profile is neither
/// trusted nor authorized. Each assertion names the state it checks.
///
/// Fixtures are synthetic. The signature mechanism is a test double, so a
/// `.verified` status here means "the composed mechanism accepted the
/// signature", never "Apple accepts this profile".
final class ProvisioningProfileVerificationUseCaseTests: XCTestCase {

    private let clock = FixedEvaluationClock(instant: Date(timeIntervalSince1970: 1_800_000_000))

    // MARK: - Verified container

    func testVerifiedContainerIsParsedAndEveryStateIsReportedSeparately() throws {
        let result = try verify(CMSFixtures.validRSASignedAttributes)

        XCTAssertEqual(result.cms.status, .verified)
        XCTAssertEqual(result.parsingState, .parsed)
        XCTAssertTrue(result.isParsed)
        XCTAssertTrue(result.isStructurallyValid)
        XCTAssertTrue(result.isCurrentlyValid)
        XCTAssertTrue(result.isCMSAuthenticated)
        XCTAssertEqual(result.inspection?.authenticity, .authenticated)
        XCTAssertEqual(result.inspection?.validation.classification, .valid)
        XCTAssertEqual(result.profile?.uuid?.uuidString, CMSFixtures.validRSAProfileUUID)
        XCTAssertEqual(result.profile?.profileName, CMSFixtures.validRSAProfileName)
    }

    func testVerifiedContainerRemainsUntrustedAndUnauthorized() throws {
        let result = try verify(CMSFixtures.validRSASignedAttributes)

        XCTAssertEqual(result.trustEvaluation, .notPerformed)
        XCTAssertEqual(result.authorization, .notEvaluated)
        XCTAssertEqual(result.inspection?.authorization, .notEvaluated)
        XCTAssertEqual(result.certificateRelationship.trustEvaluation, .notPerformed)
        XCTAssertTrue(result.isCMSAuthenticated)
        XCTAssertFalse(
            result.diagnosticDescription.contains("trusted"),
            "No stage in this increment may report trust."
        )
    }

    func testSignerCertificateMatchesTheProfileCertificate() throws {
        let result = try verify(CMSFixtures.validRSASignedAttributes)

        XCTAssertEqual(result.certificateRelationship.match, .matched)
        XCTAssertEqual(result.certificateRelationship.profileCertificateCount, 1)
        XCTAssertEqual(result.signerFingerprint?.hexDigest, CMSFixtures.signerCertificateFingerprint)
        XCTAssertEqual(result.summary.certificateMatch, .matched)
        XCTAssertEqual(result.summary.signerCertificateFingerprint, CMSFixtures.signerCertificateFingerprint)
        XCTAssertEqual(result.summary.cmsSignatureStatus, .verified)
        XCTAssertEqual(result.summary.profileParsed, true)
        XCTAssertEqual(result.summary.structurallyValid, true)
        XCTAssertEqual(result.summary.trustEvaluation, .notPerformed)
        XCTAssertEqual(result.summary.authorization, .notEvaluated)
    }

    func testVerificationDoesNotReachThePayloadDecoderSeam() throws {
        let decoder = UnusedPayloadDecoder()
        _ = try verify(CMSFixtures.validRSASignedAttributes, payloadDecoder: decoder)

        XCTAssertEqual(decoder.callCount, 0)
    }

    // MARK: - Unverified containers

    func testRejectedSignatureLeavesTheProfileUnparsed() throws {
        let rejecting = RecordingCMSSignatureVerifier()
        rejecting.result = false
        let result = try verify(CMSFixtures.validRSASignedAttributes, signatureVerifier: rejecting)

        XCTAssertEqual(result.cms.status, .invalid)
        XCTAssertEqual(result.parsingState, .notAttempted)
        XCTAssertNil(result.profile)
        XCTAssertNil(result.inspection)
        XCTAssertFalse(result.isParsed)
        XCTAssertFalse(result.isStructurallyValid)
        XCTAssertFalse(result.isCurrentlyValid)
        XCTAssertFalse(result.isCMSAuthenticated)
        XCTAssertEqual(result.authenticity, .rejected)
        XCTAssertEqual(result.summary.profileParsed, false)
    }

    func testUnevaluatedAuthenticityIsNotReportedAsRejected() throws {
        let result = try verify(
            CMSFixtures.validRSASignedAttributes,
            signatureVerifier: UnavailableCMSSignatureVerifier()
        )

        XCTAssertEqual(result.cms.status, .unavailable)
        XCTAssertEqual(result.parsingState, .notAttempted)
        XCTAssertEqual(result.authenticity, .notEvaluated)
        XCTAssertFalse(result.isCMSAuthenticated)
    }

    func testStructurallyInvalidProfileCanStillBeAuthenticated() throws {
        let result = try verify(CMSFixtures.structurallyInvalidProfile)

        XCTAssertEqual(result.cms.status, .verified)
        XCTAssertEqual(result.parsingState, .parsed)
        XCTAssertTrue(result.isParsed)
        XCTAssertFalse(result.isStructurallyValid)
        XCTAssertEqual(result.inspection?.validation.classification, .invalid)
        XCTAssertTrue(result.isCMSAuthenticated, "Authenticity is a CMS fact, not a structural one.")
        XCTAssertFalse(result.isCurrentlyValid, "The sparse profile carries no validity period.")
    }

    func testMismatchedProfileCertificatesDoNotChangeCMSAuthenticity() throws {
        let result = try verify(CMSFixtures.mismatchedProfileCertificates)

        XCTAssertEqual(result.cms.status, .verified)
        XCTAssertTrue(result.isCMSAuthenticated)
        XCTAssertEqual(result.certificateRelationship.match, .mismatched)
        XCTAssertEqual(result.certificateRelationship.profileCertificateCount, 1)
        XCTAssertEqual(
            result.certificateRelationship.profileCertificateFingerprints.map { $0.hexDigest },
            [CMSFixtures.otherCertificateFingerprint]
        )
        XCTAssertNotEqual(result.signerFingerprint?.hexDigest, CMSFixtures.otherCertificateFingerprint)
    }

    func testDuplicateProfileCertificatesAreCounted() throws {
        let result = try verify(CMSFixtures.duplicateProfileCertificates)

        XCTAssertEqual(result.certificateRelationship.profileCertificateCount, 2)
        XCTAssertEqual(result.certificateRelationship.duplicateProfileCertificateCount, 1)
        XCTAssertEqual(result.certificateRelationship.match, .matched)
    }

    func testAmbiguousSignerSelectionReachesTheRelationshipUnresolved() throws {
        let result = try verify(CMSFixtures.duplicateEmbeddedCertificates)

        XCTAssertEqual(result.cms.status, .signerCertificateUnavailable)
        XCTAssertEqual(result.cms.signerCertificateStatus, .ambiguous)
        XCTAssertEqual(result.certificateRelationship.match, .ambiguous)
        XCTAssertEqual(result.parsingState, .notAttempted)
    }

    func testProfileWithoutCertificateMetadataIsIncomparableNotMismatched() throws {
        let result = try verify(CMSFixtures.validRSASignedAttributes, attachCertificateMetadata: false)

        XCTAssertEqual(result.cms.status, .verified)
        XCTAssertEqual(result.certificateRelationship.match, .incomparable)
        XCTAssertEqual(result.certificateRelationship.profileCertificateCount, 1)
        XCTAssertEqual(result.certificateRelationship.profileReferenceWithoutMetadataCount, 1)
        XCTAssertTrue(result.certificateRelationship.profileCertificateFingerprints.isEmpty)
    }

    // MARK: - Local signing identities

    func testLocalIdentityMatchIsReportedWithoutRequestingACapability() throws {
        let signer = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)
        let store = TestIdentityStore()
        store.identities = [SigningIdentity(certificate: signer.metadata, keyAvailability: .available)]

        let result = try verify(CMSFixtures.validRSASignedAttributes, identityStore: store)

        XCTAssertEqual(
            result.certificateRelationship.localSigningIdentity,
            .matched(store.identities[0].id)
        )
        XCTAssertEqual(result.certificateRelationship.localSigningIdentityKeyAvailability, .available)
        XCTAssertEqual(result.summary.localSigningIdentity, .matched(store.identities[0].id))
        XCTAssertTrue(store.capabilityRequests.isEmpty, "A relationship question must never request a signing capability.")
        XCTAssertEqual(result.authorization, .notEvaluated, "Holding the key is not authorization.")
    }

    func testLocalIdentityMismatchIsReportedAsNoMatch() throws {
        let other = try CMSVerificationTestSupport.certificate(CMSFixtures.otherCertificateDER)
        let store = TestIdentityStore()
        store.identities = [SigningIdentity(certificate: other.metadata, keyAvailability: .available)]

        let result = try verify(CMSFixtures.validRSASignedAttributes, identityStore: store)

        XCTAssertEqual(result.certificateRelationship.localSigningIdentity, .noMatch)
        XCTAssertNil(result.certificateRelationship.localSigningIdentityKeyAvailability)
        XCTAssertTrue(store.capabilityRequests.isEmpty)
    }

    func testUnreadableIdentityStoreIsRecordedNotPropagated() throws {
        let store = TestIdentityStore()
        store.failure = ZynSignError.identity(.keychainAccessFailure)

        let result = try verify(CMSFixtures.validRSASignedAttributes, identityStore: store)

        XCTAssertEqual(result.certificateRelationship.localSigningIdentity, .lookupFailed)
        XCTAssertEqual(result.cms.status, .verified)
        XCTAssertEqual(result.certificateRelationship.match, .matched)
    }

    func testNoIdentityStoreLeavesTheRelationshipNotEvaluated() throws {
        let result = try verify(CMSFixtures.validRSASignedAttributes)

        XCTAssertEqual(result.certificateRelationship.localSigningIdentity, .notEvaluated)
        XCTAssertFalse(result.certificateRelationship.hasLocalSigningIdentityForProfileCertificate)
    }

    // MARK: - Failures

    func testEmptyInputThrowsBeforeAnyDecoding() {
        XCTAssertThrowsError(try makeUseCase().verify(ProvisioningProfileInput(bytes: Data()))) { error in
            guard let typed = error as? ZynSignError else {
                XCTFail("Expected a typed error.")
                return
            }
            XCTAssertEqual(typed.provisioningProfileFailure, .emptyInput)
            XCTAssertNil(typed.cmsFailure)
        }
    }

    func testOversizedInputThrowsBeforeAnyDecoding() {
        let oversized = Data(repeating: 0x30, count: ProvisioningProfileInput.maximumByteCount + 1)
        XCTAssertThrowsError(try makeUseCase().verify(ProvisioningProfileInput(bytes: oversized))) { error in
            XCTAssertEqual((error as? ZynSignError)?.provisioningProfileFailure, .inputTooLarge)
        }
    }

    func testMalformedContainerThrowsTypedCMSFailure() {
        for container in [
            CMSFixtures.truncatedContainer(),
            CMSFixtures.trailingBytes(),
            CMSFixtures.notCMSMessage,
            CMSFixtures.detachedContent,
            CMSFixtures.armoredContainer(),
        ] {
            XCTAssertThrowsError(try makeUseCase().verify(ProvisioningProfileInput(bytes: container))) { error in
                guard let typed = error as? ZynSignError else {
                    XCTFail("Expected a typed error.")
                    return
                }
                XCTAssertNotNil(typed.cmsFailure)
                XCTAssertNil(typed.provisioningProfileFailure)
            }
        }
    }

    func testNonPropertyListPayloadFailsAsAProfileFailure() {
        XCTAssertThrowsError(
            try verifyOrThrow(CMSFixtures.nonPropertyListPayload)
        ) { error in
            guard let typed = error as? ZynSignError else {
                XCTFail("Expected a typed error.")
                return
            }
            XCTAssertNotNil(typed.provisioningProfileFailure)
            XCTAssertNil(typed.cmsFailure, "CMS verification succeeded; the payload is what failed.")
        }
    }

    func testVerifiedResultWithoutPayloadCannotBeParsed() {
        // A verified status with no encapsulated content is contradictory
        // evidence; the use case refuses it rather than parsing nothing.
        let useCase = ProvisioningProfileVerificationUseCase(
            cmsVerifier: StubCMSVerifier(
                result: CMSVerificationResult(status: .verified, signerCount: 1)
            ),
            inspection: makeInspection(),
            identityStore: nil
        )

        XCTAssertThrowsError(
            try useCase.verify(ProvisioningProfileInput(bytes: CMSFixtures.validRSASignedAttributes))
        ) { error in
            XCTAssertEqual((error as? ZynSignError)?.cmsFailure, .payloadUnavailable)
        }
    }

    func testForeignCMSFailureIsSanitized() {
        let useCase = ProvisioningProfileVerificationUseCase(
            cmsVerifier: ForeignErrorCMSVerifier(),
            inspection: makeInspection(),
            identityStore: nil
        )

        XCTAssertThrowsError(try useCase.verify(ProvisioningProfileInput(bytes: CMSFixtures.validRSASignedAttributes))) { error in
            guard let typed = error as? ZynSignError else {
                XCTFail("Expected a typed error.")
                return
            }
            XCTAssertEqual(typed.cmsFailure, .decodeFailed)
            XCTAssertFalse(typed.debugDescription.contains(ForeignErrorCMSVerifier.privateText))
            XCTAssertFalse(typed.userMessage.contains(ForeignErrorCMSVerifier.privateText))
        }
    }

    func testDiagnosticsCarryStatesAndFingerprintsOnly() throws {
        let result = try verify(CMSFixtures.validRSASignedAttributes)
        let diagnostic = result.diagnosticDescription

        XCTAssertTrue(diagnostic.contains("profile.parsing(parsed)"))
        XCTAssertTrue(diagnostic.contains("profile.authenticity(authenticated)"))
        XCTAssertTrue(diagnostic.contains("cms.status(verified)"))
        XCTAssertTrue(diagnostic.contains("relationship.match(matched)"))
        XCTAssertTrue(diagnostic.contains(CMSFixtures.signerCertificateFingerprint))
        XCTAssertFalse(diagnostic.contains(CMSFixtures.validRSAProfileName))
        XCTAssertFalse(diagnostic.contains("-----BEGIN"))
    }

    // MARK: - Support

    private func makeInspection(
        payloadDecoder: any ProvisioningProfilePayloadDecoder = UnusedPayloadDecoder(),
        attachCertificateMetadata: Bool = true
    ) -> ProvisioningProfileInspectionUseCase {
        ProvisioningProfileInspectionUseCase(
            payloadDecoder: payloadDecoder,
            parser: PropertyListProvisioningProfileParser(
                certificateParser: attachCertificateMetadata ? AppleCertificateParser() : nil
            ),
            clock: clock
        )
    }

    private func makeUseCase(
        signatureVerifier: any CMSSignatureVerifier = RecordingCMSSignatureVerifier(),
        payloadDecoder: any ProvisioningProfilePayloadDecoder = UnusedPayloadDecoder(),
        attachCertificateMetadata: Bool = true,
        identityStore: (any IdentityStore)? = nil
    ) -> ProvisioningProfileVerificationUseCase {
        ProvisioningProfileVerificationUseCase(
            cmsVerifier: ProvisioningProfileCMSVerifier(
                certificateParser: AppleCertificateParser(),
                signatureVerifier: signatureVerifier
            ),
            inspection: makeInspection(
                payloadDecoder: payloadDecoder,
                attachCertificateMetadata: attachCertificateMetadata
            ),
            identityStore: identityStore
        )
    }

    private func verifyOrThrow(
        _ container: Data,
        signatureVerifier: any CMSSignatureVerifier = RecordingCMSSignatureVerifier(),
        payloadDecoder: any ProvisioningProfilePayloadDecoder = UnusedPayloadDecoder(),
        attachCertificateMetadata: Bool = true,
        identityStore: (any IdentityStore)? = nil
    ) throws -> ProvisioningProfileVerification {
        try makeUseCase(
            signatureVerifier: signatureVerifier,
            payloadDecoder: payloadDecoder,
            attachCertificateMetadata: attachCertificateMetadata,
            identityStore: identityStore
        ).verify(ProvisioningProfileInput(bytes: container))
    }

    private func verify(
        _ container: Data,
        signatureVerifier: any CMSSignatureVerifier = RecordingCMSSignatureVerifier(),
        payloadDecoder: any ProvisioningProfilePayloadDecoder = UnusedPayloadDecoder(),
        attachCertificateMetadata: Bool = true,
        identityStore: (any IdentityStore)? = nil
    ) throws -> ProvisioningProfileVerification {
        try verifyOrThrow(
            container,
            signatureVerifier: signatureVerifier,
            payloadDecoder: payloadDecoder,
            attachCertificateMetadata: attachCertificateMetadata,
            identityStore: identityStore
        )
    }
}
