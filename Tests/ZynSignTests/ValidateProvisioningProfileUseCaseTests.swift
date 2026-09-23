import Foundation
import XCTest
@testable import ZynSign

/// The integrated provisioning-profile pipeline: one request, staged evidence,
/// one status.
///
/// These tests are the ones that hold the integration together. They check that
/// the stages run in the security order and that no later state is inferred from
/// an earlier one: a discovered profile is not a parsed profile, a parsed profile
/// is not an authenticated one, an authenticated profile is not a compatible
/// configuration, and a compatible configuration is not trust, not
/// authorization, and not installability.
///
/// Fixtures are the synthetic CMS containers the ZS-018 suite already commits, so
/// container reading, payload parsing, structural validation, relationship
/// analysis, and policy evaluation are the real ones; only the signature
/// mechanism is a double. A `.verified` status here therefore means "the composed
/// mechanism accepted the signature", never "the platform accepts this profile".
final class ValidateProvisioningProfileUseCaseTests: XCTestCase {

    private typealias Fixtures = ProvisioningPolicyFixtures

    /// An instant inside the synthetic fixture profile's validity period — the
    /// same one the ZS-018 suite evaluates at.
    private static let insideValidity = Date(timeIntervalSince1970: 1_800_000_000)

    /// An instant after every synthetic fixture's validity period.
    private static let afterValidity = Date(timeIntervalSince1970: 4_000_000_000)

    // MARK: - A complete successful run

    func testCompleteValidProfileRunsEveryStageAndIsReportedValid() throws {
        let result = try validate(successRequest())

        XCTAssertEqual(result.overallStatus, .valid)
        XCTAssertTrue(result.overallStatus.isFullyEstablished)
        for stage in ProvisioningProfilePipelineStage.allCases {
            XCTAssertEqual(result.outcome(for: stage), .passed, "\(stage.rawValue) should have passed.")
        }
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.input.byteCount, CMSFixtures.validRSASignedAttributes.count)
        XCTAssertEqual(result.input.origin, .supplied)
        XCTAssertTrue(result.isProfileDiscovered)
        XCTAssertTrue(result.isProfileParsed)
        XCTAssertTrue(result.isStructurallyValid)
        XCTAssertTrue(result.isProfileAuthenticated)
        XCTAssertTrue(result.isProfileWithinValidityPeriod)
        XCTAssertEqual(result.authenticity, .authenticated)
        XCTAssertEqual(result.profile?.classification, .development)
        XCTAssertEqual(result.certificateCorrespondence, .matched)
        XCTAssertEqual(result.signerFingerprint?.hexDigest, CMSFixtures.signerCertificateFingerprint)
        XCTAssertEqual(result.evaluationDate, Self.insideValidity)
        XCTAssertEqual(result.policy?.overall, .compatible)
        XCTAssertEqual(result.policy?.profileAuthenticity, .satisfied)
        XCTAssertEqual(result.policy?.bundleIdentifier, .satisfied)
        XCTAssertEqual(result.policy?.entitlements, .satisfied)
        XCTAssertEqual(result.policy?.device, .satisfied)
    }

    func testValidRunStillReportsNoTrustAndNoAuthorization() throws {
        let result = try validate(successRequest())

        XCTAssertEqual(result.trustEvaluation, .notPerformed)
        XCTAssertEqual(result.authorization, .notEvaluated)
        XCTAssertEqual(result.certificateRelationship?.trustEvaluation, .notPerformed)
        XCTAssertEqual(result.policy?.trustEvaluation, .notPerformed)
        XCTAssertEqual(result.policy?.authorization, .notEvaluated)
        XCTAssertFalse(result.diagnosticDescription.contains("trusted"))
        XCTAssertFalse(result.diagnosticDescription.contains("installable"))
        XCTAssertTrue(result.findings.isEmpty, "A clean run has no reason to explain.")
    }

    func testSummaryStatesDiscoveryAuthenticationAndCompatibilitySeparately() throws {
        let result = try validate(successRequest())
        let summary = result.summary

        XCTAssertEqual(summary.overallStatus, .valid)
        XCTAssertTrue(summary.profileDiscovered)
        XCTAssertTrue(summary.profileParsed)
        XCTAssertTrue(summary.profileAuthenticated)
        XCTAssertTrue(summary.structurallyValid)
        XCTAssertTrue(summary.profileWithinValidityPeriod)
        XCTAssertEqual(summary.cmsSignatureStatus, .verified)
        XCTAssertTrue(summary.signerCertificatePresent)
        XCTAssertEqual(summary.certificateCorrespondence, .matched)
        XCTAssertTrue(summary.policyWasEvaluated)
        XCTAssertEqual(summary.policyCompatibility, .compatible)
        XCTAssertEqual(summary.trustEvaluation, .notPerformed)
        XCTAssertEqual(summary.authorization, .notEvaluated)
        XCTAssertTrue(summary.reasons.isEmpty)
    }

    func testTwoRunsWithTheSameRequestAndClockAgree() throws {
        let first = try validate(successRequest())
        let second = try validate(successRequest())

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.diagnosticDescription, second.diagnosticDescription)
    }

    func testSigningIdentityIsReadForMetadataOnlyAndNeverAskedForACapability() throws {
        let store = TestIdentityStore()
        store.identities = [identity(fingerprint: CMSFixtures.signerCertificateFingerprint)]
        let result = try validate(successRequest(), identityStore: store)

        XCTAssertEqual(result.overallStatus, .valid)
        XCTAssertEqual(result.signingIdentityRelationship, .matched(Fixtures.identityID))
        XCTAssertEqual(result.signingIdentityKeyAvailability, .available)
        XCTAssertTrue(
            store.capabilityRequests.isEmpty,
            "Validation may resolve metadata and report a capability state; it may never request the capability."
        )
    }

    func testPipelineRunsOneContainerVerificationAndOneIdentityResolutionPerKind() throws {
        let cms = ProvisioningProfileCMSVerifier(
            certificateParser: AppleCertificateParser(),
            signatureVerifier: RecordingCMSSignatureVerifier()
        )
        let evidence = try cms.verify(ProvisioningProfileInput(bytes: CMSFixtures.validRSASignedAttributes))
        let countingVerifier = CountingCMSVerifier(evidence: evidence)
        let store = CallCountingIdentityStore()
        store.listed = identity(fingerprint: CMSFixtures.signerCertificateFingerprint)

        let result = try makeUseCase(
            at: Self.insideValidity,
            cmsVerifier: countingVerifier,
            identityStore: store
        ).validate(successRequest())

        XCTAssertEqual(result.overallStatus, .valid)
        XCTAssertEqual(countingVerifier.callCount, 1, "The pipeline must not decode the container twice.")
        XCTAssertEqual(store.listCount, 1, "The listing answers the relationship question once.")
        XCTAssertEqual(store.metadataCount, 1, "Metadata answers the identity question once.")
        XCTAssertEqual(store.capabilityCount, 0)
    }

    // MARK: - Time dependence

    func testExpiredProfileIsReflectedInTheIntegratedStatus() throws {
        let result = try validate(successRequest(), at: Self.afterValidity, identityStore: identityStoreForRequest())

        XCTAssertEqual(result.overallStatus, .invalid)
        XCTAssertEqual(result.outcome(for: .cmsVerification), .passed, "Expiration does not undo authentication.")
        XCTAssertEqual(result.outcome(for: .profileParsing), .passed)
        XCTAssertEqual(result.outcome(for: .structuralValidation), .passed, "An expired profile can be structurally valid.")
        XCTAssertEqual(result.outcome(for: .policyValidation), .failed)
        XCTAssertFalse(result.isProfileWithinValidityPeriod)
        XCTAssertEqual(result.policy?.profileValidity, .violated)
        XCTAssertTrue(result.rejections.contains { $0.code == ProvisioningPolicyFindingCode.profileExpired.rawValue })
        XCTAssertEqual(result.evaluationDate, Self.afterValidity)
    }

    // MARK: - Parsing and structural failures

    func testUndecodableContainerStopsAtTheContainerStage() throws {
        for container in [CMSFixtures.notCMSMessage, CMSFixtures.truncatedContainer()] {
            let result = try validate(request(profile: .bytes(container)))

            XCTAssertEqual(result.outcome(for: .profileInput), .passed)
            XCTAssertEqual(result.outcome(for: .cmsVerification), .failed)
            XCTAssertEqual(result.outcome(for: .profileParsing), .notAttempted)
            XCTAssertEqual(result.outcome(for: .structuralValidation), .notAttempted)
            XCTAssertEqual(result.outcome(for: .policyValidation), .notAttempted)
            XCTAssertNil(result.verification)
            XCTAssertNil(result.policy, "No policy rule is applied to a container that produced no evidence.")
            XCTAssertEqual(result.overallStatus, .invalid)
            XCTAssertTrue(result.rejections.contains { $0.stage == .cmsVerification })
            XCTAssertTrue(result.rejections.contains { CMSFailure(rawValue: $0.code) != nil })
        }
    }

    func testArmoredContainerIsUnsupportedNotInvalid() throws {
        let result = try validate(request(profile: .bytes(CMSFixtures.armoredContainer())))

        XCTAssertEqual(result.outcome(for: .cmsVerification), .indeterminate)
        XCTAssertEqual(result.overallStatus, .unsupported)
        XCTAssertTrue(result.unsupportedFindings.contains { $0.code == CMSFailure.unsupportedStructure.rawValue })
        XCTAssertTrue(result.rejections.isEmpty, "An armor form ZynSign deliberately refuses is not a broken profile.")
    }

    func testEmptyInputIsRejectedBeforeTheContainerBoundaryRuns() throws {
        let result = try validate(request(profile: .bytes(Data())))

        XCTAssertEqual(result.input.byteCount, 0)
        XCTAssertEqual(result.outcome(for: .profileInput), .failed)
        XCTAssertEqual(result.outcome(for: .cmsVerification), .notAttempted)
        XCTAssertEqual(result.overallStatus, .invalid)
        XCTAssertEqual(result.findings.map(\.code), [ProvisioningProfileFailure.emptyInput.rawValue])
        XCTAssertEqual(result.findings.first?.stage, .profileInput)
    }

    func testOversizedInputIsRejectedBeforeTheContainerBoundaryRuns() throws {
        let oversized = Data(repeating: 0x30, count: ProvisioningProfileInput.maximumByteCount + 1)
        let result = try validate(request(profile: .bytes(oversized)))

        XCTAssertEqual(result.outcome(for: .profileInput), .failed)
        XCTAssertEqual(result.outcome(for: .cmsVerification), .notAttempted)
        XCTAssertEqual(result.overallStatus, .invalid)
        XCTAssertEqual(result.findings.map(\.code), [ProvisioningProfileFailure.inputTooLarge.rawValue])
    }

    func testAuthenticatedPayloadThatIsNotAPropertyListFailsAtTheParsingStage() throws {
        let result = try validate(request(profile: .bytes(CMSFixtures.nonPropertyListPayload)))

        XCTAssertEqual(result.outcome(for: .profileInput), .passed)
        XCTAssertEqual(
            result.outcome(for: .cmsVerification),
            .indeterminate,
            "The boundary returned no evidence object, so authentication is not claimed."
        )
        XCTAssertEqual(result.outcome(for: .profileParsing), .failed)
        XCTAssertNil(result.profile)
        XCTAssertNil(result.policy)
        XCTAssertEqual(result.overallStatus, .invalid)
        XCTAssertEqual(result.findings.map(\.code), [
            ProvisioningProfilePipelineFindingCode.containerEvidenceUnavailable,
            ProvisioningProfileFailure.malformedPayload.rawValue,
        ])
    }

    func testStructurallyInvalidProfileIsAuthenticatedAndStillInvalid() throws {
        let result = try validate(request(profile: .bytes(CMSFixtures.structurallyInvalidProfile)))

        XCTAssertEqual(result.outcome(for: .cmsVerification), .passed)
        XCTAssertEqual(result.outcome(for: .profileParsing), .passed)
        XCTAssertEqual(result.outcome(for: .structuralValidation), .failed)
        XCTAssertEqual(result.overallStatus, .invalid)
        XCTAssertTrue(result.isProfileAuthenticated, "Authenticity is a container fact, not a structural one.")
        XCTAssertFalse(result.isStructurallyValid)
        XCTAssertTrue(result.rejections.contains { $0.stage == .structuralValidation })
        XCTAssertEqual(result.policy?.profileAuthenticity, .satisfied)
    }

    // MARK: - Cryptographic failure

    func testRejectedSignatureIsNotReportedAsPolicyAuthorization() throws {
        let rejecting = RecordingCMSSignatureVerifier()
        rejecting.result = false
        let result = try validate(successRequest(), signatureVerifier: rejecting, identityStore: identityStoreForRequest())

        XCTAssertEqual(result.cms?.status, .invalid)
        XCTAssertEqual(result.outcome(for: .cmsVerification), .failed)
        XCTAssertEqual(result.outcome(for: .profileParsing), .notAttempted)
        XCTAssertNil(result.profile)
        XCTAssertFalse(result.isProfileAuthenticated)
        XCTAssertEqual(result.authenticity, .rejected)
        XCTAssertEqual(result.overallStatus, .invalid)
        XCTAssertTrue(result.rejections.contains { $0.code == CMSSignatureVerificationStatus.invalid.rawValue })
        // Policy ran, and it ran only to say that nothing may be concluded from an
        // unauthenticated payload: the gate is the finding, never a pass.
        XCTAssertNotNil(result.policy)
        XCTAssertEqual(result.policy?.profileAuthenticity, .violated)
        XCTAssertEqual(result.policy?.bundleIdentifier, .indeterminate)
        XCTAssertEqual(result.policy?.entitlements, .indeterminate)
        XCTAssertFalse(result.isPolicyCompatible)
    }

    func testTamperedPayloadIsRejectedWithoutReachingTheMechanism() throws {
        let mechanism = RecordingCMSSignatureVerifier()
        let result = try validate(
            request(profile: .bytes(CMSFixtures.tamperedPayload())),
            signatureVerifier: mechanism
        )

        XCTAssertEqual(result.cms?.status, .invalid)
        XCTAssertEqual(
            mechanism.callCount,
            0,
            "A payload that does not bind to the signed attributes is refused before any signature is checked."
        )
        XCTAssertEqual(result.overallStatus, .invalid)
    }

    func testMechanismUnavailabilityIsIndeterminateAndNotADefectInTheProfile() throws {
        let result = try validate(
            request(profile: .bytes(CMSFixtures.validRSASignedAttributes)),
            signatureVerifier: UnavailableCMSSignatureVerifier()
        )

        XCTAssertEqual(result.cms?.status, .unavailable)
        XCTAssertEqual(result.outcome(for: .cmsVerification), .indeterminate)
        XCTAssertEqual(result.outcome(for: .profileParsing), .notAttempted)
        XCTAssertEqual(result.authenticity, .notEvaluated)
        XCTAssertNil(result.profile)
        XCTAssertEqual(result.overallStatus, .indeterminate, "Unverified is not invalid.")
        XCTAssertEqual(result.policy?.profileAuthenticity, .indeterminate)
        XCTAssertTrue(result.rejections.isEmpty)
        XCTAssertTrue(result.unresolvedFindings.contains { $0.code == CMSSignatureVerificationStatus.unavailable.rawValue })
    }

    func testUnsupportedAlgorithmIsReportedAsUnsupportedRatherThanInvalid() throws {
        let result = try validate(request(profile: .bytes(CMSFixtures.sha1DigestAlgorithm)))

        XCTAssertEqual(result.cms?.status, .unsupportedAlgorithm)
        XCTAssertEqual(result.outcome(for: .cmsVerification), .indeterminate)
        XCTAssertEqual(result.overallStatus, .unsupported)
        XCTAssertTrue(result.unsupportedFindings.contains { $0.code == CMSSignatureVerificationStatus.unsupportedAlgorithm.rawValue })
        XCTAssertTrue(result.rejections.isEmpty, "A digest ZynSign cannot name is not a broken profile.")
    }

    // MARK: - Certificate relationship

    func testProfileCertificatesThatDoNotIncludeTheSignerStayAnOpenQuestion() throws {
        let result = try validate(request(profile: .bytes(CMSFixtures.mismatchedProfileCertificates)))

        XCTAssertEqual(result.outcome(for: .cmsVerification), .passed)
        XCTAssertEqual(result.certificateCorrespondence, .mismatched)
        XCTAssertEqual(result.outcome(for: .certificateRelationship), .failed)
        XCTAssertTrue(result.unresolvedFindings.contains { $0.code == CertificateMatchOutcome.mismatched.rawValue })
        XCTAssertTrue(result.rejections.filter { $0.stage == .certificateRelationship }.isEmpty)
        XCTAssertEqual(result.policy?.certificate, .indeterminate)
        XCTAssertEqual(
            result.overallStatus,
            .indeterminate,
            "Correspondence is the container stage's evidence, and the policy stage treats a mismatch as an open question."
        )
    }

    func testUnrelatedSigningIdentityCannotBeReportedAsCompatible() throws {
        let store = TestIdentityStore()
        store.identities = [identity(fingerprint: Fixtures.unrelatedFingerprint)]

        let result = try validate(successRequest(), identityStore: store)

        XCTAssertEqual(result.signingIdentityRelationship, .noMatch)
        XCTAssertEqual(result.policy?.certificate, .violated)
        XCTAssertEqual(result.overallStatus, .invalid)
        XCTAssertTrue(result.isProfileAuthenticated, "An unrelated identity does not change the container's authentication.")
        XCTAssertTrue(result.rejections.contains { $0.code == ProvisioningPolicyFindingCode.signingIdentityCertificateMismatch.rawValue })
    }

    func testUnreadableIdentityStoreLeavesTheIdentityQuestionOpenNotTheProfileBroken() throws {
        let store = TestIdentityStore()
        store.identities = [identity(fingerprint: CMSFixtures.signerCertificateFingerprint)]
        store.failure = ZynSignError.identity(.keychainAccessFailure)

        let result = try validate(successRequest(), identityStore: store)

        XCTAssertEqual(result.signingIdentityRelationship, .lookupFailed)
        XCTAssertEqual(result.outcome(for: .cmsVerification), .passed)
        XCTAssertEqual(result.outcome(for: .profileParsing), .passed)
        XCTAssertEqual(result.overallStatus, .indeterminate)
        XCTAssertTrue(result.rejections.isEmpty)
        XCTAssertTrue(result.unresolvedFindings.contains { $0.code == ProvisioningPolicyFindingCode.signingIdentityLookupFailed.rawValue })
    }

    func testAbsentIdentityStoreLeavesTheRelationshipNotEvaluated() throws {
        let result = try validate(successRequest(), identityStore: nil)

        XCTAssertEqual(result.signingIdentityRelationship, .notEvaluated)
        XCTAssertTrue(result.summary.signerCertificatePresent)
        XCTAssertEqual(result.overallStatus, .indeterminate, "The identity questions stay open, so nothing is `valid`.")
        XCTAssertTrue(result.unresolvedFindings.contains { $0.code == ProvisioningPolicyFindingCode.signingIdentityNotProvided.rawValue })
    }

    // MARK: - Policy findings preserved

    func testBundleIdentifierMismatchIsPreservedFromPolicy() throws {
        let request = ValidateProvisioningProfileRequest(
            profile: .bytes(CMSFixtures.validRSASignedAttributes),
            applicationMetadata: Fixtures.applicationMetadata(bundleIdentifier: Fixtures.otherBundleIdentifier),
            signingIdentityID: Fixtures.identityID,
            signingConfiguration: Fixtures.configuration(),
            deviceContext: .identified(Fixtures.deviceA)
        )

        let result = try validate(request, identityStore: identityStoreForRequest())

        XCTAssertEqual(result.outcome(for: .policyValidation), .failed)
        XCTAssertEqual(result.policy?.bundleIdentifier, .violated)
        XCTAssertTrue(result.rejections.contains { $0.code == ProvisioningPolicyFindingCode.bundleIdentifierMismatch.rawValue })
        XCTAssertEqual(result.overallStatus, .invalid)
        XCTAssertEqual(result.outcome(for: .cmsVerification), .passed)
    }

    func testEntitlementFailurePropagatesIntoTheIntegratedResult() throws {
        let result = try validate(
            successRequest(
                configuration: Fixtures.configuration(
                    entitlements: Fixtures.entitlements(
                        applicationIdentifierValue: Fixtures.teamIdentifier + "." + Fixtures.bundleIdentifier,
                        teamValue: Fixtures.teamIdentifier,
                        getTaskAllow: true,
                        additional: ["com.example.unapproved": .string("SENTINEL-4c17")]
                    )
                )
            ),
            identityStore: identityStoreForRequest()
        )

        XCTAssertEqual(result.policy?.entitlements, .violated)
        XCTAssertTrue(result.rejections.contains { $0.code == ProvisioningPolicyFindingCode.entitlementNotAuthorized.rawValue })
        XCTAssertEqual(result.overallStatus, .invalid)
        for finding in result.findings {
            XCTAssertFalse(finding.detail.contains("SENTINEL-4c17"), "A requested value must not reach a finding.")
        }
        XCTAssertFalse(result.diagnosticDescription.contains("SENTINEL-4c17"))
        XCTAssertFalse(result.summary.reasons.contains { $0.text.contains("SENTINEL-4c17") })
    }

    func testSeveralFailuresAreReportedTogether() throws {
        let request = ValidateProvisioningProfileRequest(
            profile: .bytes(CMSFixtures.validRSASignedAttributes),
            applicationMetadata: Fixtures.applicationMetadata(bundleIdentifier: Fixtures.otherBundleIdentifier),
            signingIdentityID: Fixtures.identityID,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(
                    applicationIdentifierValue: Fixtures.teamIdentifier + "." + Fixtures.bundleIdentifier,
                    teamValue: Fixtures.otherTeamIdentifier,
                    getTaskAllow: false
                )
            ),
            deviceContext: .identified(Fixtures.deviceB)
        )

        let result = try validate(request, at: Self.afterValidity, identityStore: identityStoreForRequest())

        XCTAssertTrue(result.rejections.contains { $0.code == ProvisioningPolicyFindingCode.profileExpired.rawValue })
        XCTAssertTrue(result.rejections.contains { $0.code == ProvisioningPolicyFindingCode.bundleIdentifierMismatch.rawValue })
        XCTAssertTrue(result.rejections.contains { $0.code == ProvisioningPolicyFindingCode.teamIdentifierClaimMismatch.rawValue })
        XCTAssertTrue(result.rejections.contains { $0.code == ProvisioningPolicyFindingCode.deviceNotProvisioned.rawValue })
        XCTAssertGreaterThanOrEqual(result.rejections.count, 4)
        XCTAssertEqual(result.overallStatus, .invalid)
        XCTAssertEqual(
            result.outcome(for: .cmsVerification),
            .passed,
            "Several policy failures do not disturb the container evidence."
        )
        XCTAssertEqual(result.policy?.overall, .incompatible)
    }

    // MARK: - Input that is not there

    func testMissingProfileIsADistinctStateAndNotAnInvalidApplication() throws {
        let result = try validate(request(profile: .notFound))

        XCTAssertEqual(result.input.acquisition, .notFound)
        XCTAssertFalse(result.isProfileDiscovered)
        XCTAssertEqual(result.outcome(for: .profileInput), .indeterminate)
        XCTAssertEqual(result.outcome(for: .cmsVerification), .notAttempted)
        XCTAssertEqual(result.outcome(for: .policyValidation), .notAttempted)
        XCTAssertNil(result.verification)
        XCTAssertNil(result.policy)
        XCTAssertEqual(result.overallStatus, .indeterminate)
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.findings.first?.code, ProvisioningProfilePipelineFindingCode.profileNotFound)
        XCTAssertEqual(result.findings.first?.severity, .unresolved)
        XCTAssertFalse(result.summary.profileAuthenticated)
        XCTAssertFalse(result.summary.policyWasEvaluated)
    }

    func testUnreadableProfileEntryIsDistinctFromAnAbsentOne() throws {
        let result = try validate(request(profile: .unusable(.entryUnreadable)))

        XCTAssertEqual(result.input.acquisition, .unusable(.entryUnreadable))
        XCTAssertEqual(result.overallStatus, .indeterminate)
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.findings.first?.code, ProvisioningProfilePipelineAcquisitionFailure.entryUnreadable.rawValue)
        XCTAssertTrue(result.findings.first?.detail.contains("read bound") == true)
        XCTAssertNil(result.policy)
    }

    func testDiscoveryParsingAuthenticationAndCompatibilityAreFourSeparateStates() throws {
        let absent = try validate(request(profile: .notFound))
        let unreadable = try validate(request(profile: .unusable(.containerUnreadable)))
        let parsedOnly = try validate(request(profile: .bytes(CMSFixtures.structurallyInvalidProfile)))
        let complete = try validate(successRequest())

        XCTAssertFalse(absent.isProfileDiscovered)
        XCTAssertFalse(unreadable.isProfileDiscovered)
        XCTAssertFalse(absent.isProfileParsed)
        XCTAssertFalse(unreadable.isProfileParsed)
        XCTAssertTrue(parsedOnly.isProfileDiscovered)
        XCTAssertTrue(parsedOnly.isProfileParsed)
        XCTAssertTrue(parsedOnly.isProfileAuthenticated)
        XCTAssertFalse(parsedOnly.isPolicyCompatible)
        XCTAssertFalse(parsedOnly.isStructurallyValid)
        XCTAssertTrue(complete.isProfileDiscovered)
        XCTAssertTrue(complete.isProfileParsed)
        XCTAssertTrue(complete.isProfileAuthenticated)
        XCTAssertTrue(complete.isPolicyCompatible)
        XCTAssertNotEqual(parsedOnly.overallStatus, complete.overallStatus)
    }

    // MARK: - Immutability

    func testThePipelineMutatesNothingItWasGiven() throws {
        let bytes = CMSFixtures.validRSASignedAttributes
        let configuration = Fixtures.configuration(
            entitlements: Fixtures.entitlements(
                applicationIdentifierValue: Fixtures.teamIdentifier + "." + Fixtures.bundleIdentifier,
                teamValue: Fixtures.teamIdentifier,
                getTaskAllow: false,
                additional: [
                    "com.example.dict": .dictionary(["nested": .integer(3)]),
                    "com.example.seq": .array([.string("a"), .string("b")]),
                ]
            )
        )
        let metadata = Fixtures.applicationMetadata()
        let identity = self.identity(fingerprint: CMSFixtures.signerCertificateFingerprint)
        let store = TestIdentityStore()
        store.identities = [identity]

        let request = ValidateProvisioningProfileRequest(
            profile: .bytes(bytes),
            applicationMetadata: metadata,
            signingIdentityID: identity.id,
            signingConfiguration: configuration,
            deviceContext: .identified(Fixtures.deviceA)
        )
        let snapshot = request

        let result = try validate(request, identityStore: store)

        XCTAssertEqual(request, snapshot, "The request is a value the pipeline only reads.")
        XCTAssertEqual(request.profile, .bytes(bytes), "Profile bytes are handed to the stages unchanged.")
        XCTAssertEqual(request.applicationMetadata, metadata)
        XCTAssertEqual(request.signingConfiguration, configuration)
        XCTAssertEqual(store.identities, [identity], "The identity listing is read, not revised.")
        XCTAssertEqual(
            result.profile?.entitlements,
            independentlyParsedEntitlements(bytes),
            "The parsed profile's entitlement tree is the payload's own, rewritten by nothing."
        )
    }

    // MARK: - Diagnostics

    func testDiagnosticsCarryStagesAndCodesAndNoProfileContent() throws {
        let result = try validate(request(profile: .bytes(CMSFixtures.structurallyInvalidProfile)))
        let diagnostic = result.diagnosticDescription

        XCTAssertTrue(diagnostic.contains("pipeline.status(invalid)"))
        XCTAssertTrue(diagnostic.contains("pipeline.stage.profileParsing(passed)"))
        XCTAssertTrue(diagnostic.contains("pipeline.stage.structuralValidation(failed)"))
        XCTAssertTrue(diagnostic.contains("cms.status(verified)"))
        XCTAssertFalse(diagnostic.contains(CMSFixtures.validRSAProfileName))
        XCTAssertFalse(diagnostic.contains("TEAM123456"))
        XCTAssertFalse(diagnostic.contains("com.example.synthetic"))
        XCTAssertFalse(diagnostic.contains("-----BEGIN"))

        let missing = try validate(request(profile: .notFound))
        XCTAssertTrue(missing.diagnosticDescription.contains("pipeline.input(supplied notFound)"))
    }

    func testResultExposesEveryStageWithoutRerunningAnyStage() throws {
        let result = try validate(successRequest())

        XCTAssertEqual(result.verification?.inspection?.profile.applicationIdentifier?.fullValue, "TEAM123456.com.example.synthetic")
        XCTAssertEqual(result.structuralValidation?.validity?.periodStatus, .currentlyValid)
        XCTAssertEqual(result.cms?.signerCount, 1)
        XCTAssertEqual(result.certificateRelationship?.profileCertificateCount, 1)
        XCTAssertEqual(result.signerCertificatePresent, true)
        XCTAssertEqual(result.profileCertificateReferencePresent, true)
        XCTAssertEqual(result.profile?.teamIdentifier, "TEAM123456")
    }

    // MARK: - Support

    private func identity(fingerprint: String) -> SigningIdentity {
        identity(fingerprint: Fixtures.fingerprint(fingerprint))
    }

    private func identity(fingerprint: CertificateFingerprint) -> SigningIdentity {
        let metadata = Fixtures.identityMetadata(fingerprint: fingerprint)
        return SigningIdentity(
            id: metadata.id,
            certificate: metadata.certificate,
            keyAvailability: metadata.keyAvailability,
            association: metadata.association,
            capabilityState: metadata.capabilityState
        )
    }

    private func identityStoreForRequest() -> TestIdentityStore {
        let store = TestIdentityStore()
        store.identities = [identity(fingerprint: CMSFixtures.signerCertificateFingerprint)]
        return store
    }

    private func successRequest(
        configuration: SigningConfiguration = Fixtures.configuration()
    ) -> ValidateProvisioningProfileRequest {
        ValidateProvisioningProfileRequest(
            profile: .bytes(CMSFixtures.validRSASignedAttributes),
            applicationMetadata: Fixtures.applicationMetadata(),
            signingIdentityID: Fixtures.identityID,
            signingConfiguration: configuration,
            deviceContext: .identified(Fixtures.deviceA)
        )
    }

    private func request(profile: ProvisioningProfilePipelineProfile) -> ValidateProvisioningProfileRequest {
        ValidateProvisioningProfileRequest(profile: profile)
    }

    private func makeInspection(
        clock: any EvaluationClock,
        payloadDecoder: any ProvisioningProfilePayloadDecoder = UnusedPayloadDecoder()
    ) -> ProvisioningProfileInspectionUseCase {
        ProvisioningProfileInspectionUseCase(
            payloadDecoder: payloadDecoder,
            parser: PropertyListProvisioningProfileParser(certificateParser: AppleCertificateParser()),
            clock: clock
        )
    }

    private func makeUseCase(
        at instant: Date,
        cmsVerifier: any CMSVerifier,
        identityStore: (any IdentityStore)?
    ) -> ValidateProvisioningProfileUseCase {
        ValidateProvisioningProfileUseCase(
            profileVerification: ProvisioningProfileVerificationUseCase(
                cmsVerifier: cmsVerifier,
                inspection: makeInspection(clock: FixedEvaluationClock(instant: instant)),
                identityStore: identityStore
            ),
            configurationValidation: ValidateProvisioningConfigurationUseCase(
                policyValidator: ProvisioningPolicyValidator(clock: FixedEvaluationClock(instant: instant)),
                identityStore: identityStore
            )
        )
    }

    private func validate(
        _ request: ValidateProvisioningProfileRequest,
        at instant: Date = Self.insideValidity,
        signatureVerifier: any CMSSignatureVerifier = RecordingCMSSignatureVerifier(),
        identityStore: (any IdentityStore)? = nil
    ) throws -> ProvisioningProfilePipelineResult {
        try makeUseCase(
            at: instant,
            cmsVerifier: ProvisioningProfileCMSVerifier(
                certificateParser: AppleCertificateParser(),
                signatureVerifier: signatureVerifier
            ),
            identityStore: identityStore
        ).validate(request)
    }

    /// The entitlements the ZS-017 parser produces for the fixture's payload, read
    /// independently, so the assertion compares the pipeline's parsed profile with
    /// a fresh parse rather than with itself.
    private func independentlyParsedEntitlements(_ container: Data) -> ProvisioningProfileEntitlements? {
        let payload = ProvisioningProfilePayload(plistData: Data(container[CMSFixtures.validRSAEncapsulatedContentRange]))
        return try? PropertyListProvisioningProfileParser().parse(payload).entitlements
    }

    // MARK: - Doubles

    /// A container boundary that hands back prepared evidence and counts how often
    /// it was asked, so a test can prove the pipeline verifies once.
    private final class CountingCMSVerifier: CMSVerifier {

        private let evidence: CMSVerificationResult
        private(set) var callCount = 0

        init(evidence: CMSVerificationResult) {
            self.evidence = evidence
        }

        func verify(_ input: ProvisioningProfileInput) throws -> CMSVerificationResult {
            callCount += 1
            return evidence
        }
    }

    /// An identity store that counts each kind of read, so a test can see that the
    /// pipeline reads listing and metadata and never asks for a capability.
    fileprivate final class CallCountingIdentityStore: IdentityStore {

        /// The one identity the store lists, if any. Named apart from the
        /// `identity(withID:)` requirement so the two cannot collide.
        var listed: SigningIdentity?
        var failure: Error?

        private(set) var listCount = 0
        private(set) var metadataCount = 0
        private(set) var capabilityCount = 0

        func listIdentities() throws -> [SigningIdentity] {
            listCount += 1
            if let failure { throw failure }
            return listed.map { [$0] } ?? []
        }

        func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? {
            if let failure { throw failure }
            guard let listed, listed.id == id else { return nil }
            return listed
        }

        func metadata(for id: SigningIdentityIdentifier) throws -> SigningIdentityMetadata? {
            metadataCount += 1
            guard let found = try identity(withID: id) else { return nil }
            return SigningIdentityMetadata(identity: found)
        }

        func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability {
            capabilityCount += 1
            throw ZynSignError.identity(.capabilityUnavailable)
        }
    }
}
