import Foundation
import XCTest
@testable import ZynSign

/// Application-layer orchestration of policy validation.
///
/// These tests hold the boundary in place: the use case assembles a context
/// from evidence that already exists, resolves identity metadata read-only,
/// never requests a signing capability, and reports a structured result instead
/// of throwing when a profile is not authenticated.
final class ValidateProvisioningConfigurationUseCaseTests: XCTestCase {

    private typealias Fixtures = ProvisioningPolicyFixtures

    // MARK: - Compatible request

    func testCompatibleRequestIsReportedAsCompatible() {
        let store = makeStore(with: Fixtures.identityMetadata())
        let useCase = makeUseCase(store: store)

        let result = useCase.validate(makeRequest(identityID: Fixtures.identityID))

        XCTAssertEqual(result.overall, .compatible)
        XCTAssertTrue(result.isEligibleForSigning)
        XCTAssertEqual(result.trustEvaluation, .notPerformed)
        XCTAssertEqual(result.authorization, .notEvaluated)
        XCTAssertEqual(result.evaluationDate, Fixtures.evaluationDate)
    }

    func testIdentityMetadataIsResolvedWithoutRequestingASigningCapability() {
        let store = makeStore(with: Fixtures.identityMetadata())
        let useCase = makeUseCase(store: store)

        let evaluation = useCase.validate(makeRequest(identityID: Fixtures.identityID))

        XCTAssertTrue(
            store.capabilityRequests.isEmpty,
            "Policy evaluation must never request a signing capability."
        )
        XCTAssertEqual(evaluation.certificate, .satisfied)
    }

    func testEvaluationIsDeterministicAndPerformsNoSigning() {
        let store = makeStore(with: Fixtures.identityMetadata())
        let useCase = makeUseCase(store: store)

        let first = useCase.validate(makeRequest(identityID: Fixtures.identityID))
        let second = useCase.validate(makeRequest(identityID: Fixtures.identityID))

        XCTAssertEqual(first, second)
        XCTAssertTrue(
            store.capabilityRequests.isEmpty,
            "Policy evaluation must not request a signing capability, and it must not sign."
        )
        XCTAssertFalse(first.diagnosticDescription.contains(Fixtures.profileCertificateFingerprint.hexDigest))
        XCTAssertFalse(first.diagnosticDescription.contains(Fixtures.bundleIdentifier))
    }

    // MARK: - Identity availability

    func testIdentityTheStoreDoesNotListIsReportedAsUnavailable() {
        let store = makeStore(with: nil)
        let useCase = makeUseCase(store: store)

        let result = useCase.validate(makeRequest(identityID: Fixtures.identityID))

        XCTAssertEqual(result.certificate, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .signingIdentityNoneAvailable })
    }

    func testUnreadableIdentityStoreIsRecordedAsAFailedLookupNotAsAProfileDefect() {
        let store = makeStore(with: Fixtures.identityMetadata())
        store.failure = ZynSignError.identity(.capabilityUnavailable)
        let useCase = makeUseCase(store: store)

        let result = useCase.validate(makeRequest(identityID: Fixtures.identityID))

        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .signingIdentityLookupFailed })
        XCTAssertEqual(result.profileValidity, .satisfied)
        XCTAssertEqual(result.profileAuthenticity, .satisfied)
        XCTAssertFalse(result.violations.contains { $0.code == .profileDatesMalformed })
    }

    func testRequestWithoutAnIdentityRecordsTheQuestionAsNotAsked() {
        let store = makeStore(with: Fixtures.identityMetadata())
        let useCase = makeUseCase(store: store)

        let result = useCase.validate(makeRequest(identityID: nil))

        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .signingIdentityNotProvided })
        XCTAssertFalse(result.indeterminateFindings.contains { $0.code == .signingIdentityLookupFailed })
    }

    func testRequestWithAnIdentityAndNoStoreComposesTheQuestionAsNotAsked() {
        let useCase = makeUseCase(store: nil)

        let result = useCase.validate(makeRequest(identityID: Fixtures.identityID))

        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .signingIdentityNotProvided })
    }

    // MARK: - Staged evidence that is not authenticated

    func testUnverifiedContainerIsNotEvaluatedByPolicyRules() {
        let useCase = makeUseCase(store: nil)
        let request = ValidateProvisioningConfigurationRequest(
            verification: Fixtures.verification(profile: nil, authenticity: .notEvaluated)
        )

        let result = useCase.validate(request)

        XCTAssertEqual(result.overall, .indeterminate)
        XCTAssertEqual(result.profileAuthenticity, .indeterminate)
        XCTAssertEqual(result.bundleIdentifier, .indeterminate)
        XCTAssertTrue(result.violations.isEmpty)
    }

    func testRejectedContainerIsReportedWithoutThrowing() {
        let useCase = makeUseCase(store: nil)
        let request = ValidateProvisioningConfigurationRequest(
            verification: Fixtures.verification(
                profile: nil,
                authenticity: .rejected,
                relationship: Fixtures.relationship(match: .notEvaluated, signerFingerprint: nil)
            )
        )

        let result = useCase.validate(request)

        XCTAssertEqual(result.overall, .incompatible)
        XCTAssertEqual(result.profileAuthenticity, .violated)
    }

    func testAuthenticatedProfileStillFailsPolicyWhenItDoesNotFit() {
        let store = makeStore(with: Fixtures.identityMetadata())
        let useCase = makeUseCase(store: store)
        let request = makeRequest(
            identityID: Fixtures.identityID,
            profile: Fixtures.profile(applicationIdentifierComponent: Fixtures.otherBundleIdentifier)
        )

        let result = useCase.validate(request)

        XCTAssertEqual(result.profileAuthenticity, .satisfied)
        XCTAssertEqual(result.bundleIdentifier, .violated)
        XCTAssertEqual(result.overall, .incompatible)
    }

    // MARK: - Context passed through

    func testEstimatedPlatformsAndDeviceContextArePassedThrough() {
        let store = makeStore(with: Fixtures.identityMetadata())
        let useCase = makeUseCase(store: store)
        let request = ValidateProvisioningConfigurationRequest(
            verification: Fixtures.verification(profile: Fixtures.profile(shape: .adHoc)),
            applicationMetadata: Fixtures.applicationMetadata(deviceFamilies: [.tv]),
            signingIdentityID: Fixtures.identityID,
            signingConfiguration: Fixtures.configuration(),
            deviceContext: .identified(Fixtures.deviceA),
            intendedPlatforms: [.iPhoneOS]
        )

        let result = useCase.validate(request)

        XCTAssertEqual(result.platform, .satisfied)
        XCTAssertEqual(result.device, .satisfied)
    }

    func testDeclaredApplicationMetadataDrivesThePlatformRuleWhenNoPlatformIsStated() {
        let store = makeStore(with: Fixtures.identityMetadata())
        let useCase = makeUseCase(store: store)
        let request = ValidateProvisioningConfigurationRequest(
            verification: Fixtures.verification(),
            applicationMetadata: Fixtures.applicationMetadata(deviceFamilies: [.tv]),
            signingIdentityID: Fixtures.identityID
        )

        let result = useCase.validate(request)

        XCTAssertEqual(result.platform, .violated, "An iPhone-only profile does not cover a tvOS application.")
    }

    // MARK: - Summary

    func testSummaryCarriesCategoryStatusesAndExplainsOnlyNonSatisfiedCategories() {
        let store = makeStore(with: Fixtures.identityMetadata(fingerprint: Fixtures.unrelatedFingerprint))
        let useCase = makeUseCase(store: store)

        let result = useCase.validate(makeRequest(identityID: Fixtures.identityID))
        let summary = result.summary

        XCTAssertEqual(summary.overall, result.overall)
        XCTAssertEqual(summary.certificate, .violated)
        XCTAssertEqual(summary.profileValidity, .satisfied)
        XCTAssertEqual(summary.bundleIdentifier, .satisfied)
        XCTAssertEqual(summary.trustEvaluation, .notPerformed)
        XCTAssertEqual(summary.authorization, .notEvaluated)
        XCTAssertFalse(summary.reasons.isEmpty)
        XCTAssertTrue(summary.reasons.allSatisfy { $0.status != .satisfied })
        XCTAssertTrue(summary.reasons.contains { $0.code == .signingIdentityCertificateMismatch })
    }

    func testCompatibleSummaryCarriesNoReasons() {
        let store = makeStore(with: Fixtures.identityMetadata())
        let useCase = makeUseCase(store: store)

        let summary = useCase.validate(makeRequest(identityID: Fixtures.identityID)).summary

        XCTAssertEqual(summary.overall, .compatible)
        XCTAssertTrue(summary.reasons.isEmpty)
    }

    func testSummaryTextCarriesNoIdentifiersOrValues() {
        let store = makeStore(with: Fixtures.identityMetadata(fingerprint: Fixtures.unrelatedFingerprint))
        let useCase = makeUseCase(store: store)
        let sentinel = "SENTINEL-9f3a"
        let request = makeRequest(
            identityID: Fixtures.identityID,
            configuration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["com.example.unapproved": .string(sentinel)])
            )
        )

        let summary = useCase.validate(request).summary

        XCTAssertFalse(summary.reasons.isEmpty)
        for reason in summary.reasons {
            XCTAssertFalse(reason.text.contains(Fixtures.bundleIdentifier))
            XCTAssertFalse(reason.text.contains(Fixtures.teamIdentifier))
            XCTAssertFalse(reason.text.contains(Fixtures.profileCertificateFingerprint.hexDigest))
            XCTAssertFalse(reason.text.contains(sentinel))
        }
    }

    // MARK: - Support

    private func makeUseCase(store: TestIdentityStore?) -> ValidateProvisioningConfigurationUseCase {
        ValidateProvisioningConfigurationUseCase(
            policyValidator: Fixtures.validator(),
            identityStore: store
        )
    }

    private func makeStore(with metadata: SigningIdentityMetadata?) -> TestIdentityStore {
        let store = TestIdentityStore()
        if let metadata {
            store.identities = [
                SigningIdentity(
                    id: metadata.id,
                    certificate: metadata.certificate,
                    keyAvailability: metadata.keyAvailability,
                    association: metadata.association,
                    capabilityState: metadata.capabilityState
                )
            ]
        }
        return store
    }

    private func makeRequest(
        identityID: SigningIdentityIdentifier?,
        profile: ProvisioningProfile = Fixtures.profile(),
        configuration: SigningConfiguration = Fixtures.configuration(),
        applicationMetadata: ApplicationMetadata? = Fixtures.applicationMetadata()
    ) -> ValidateProvisioningConfigurationRequest {
        ValidateProvisioningConfigurationRequest(
            verification: Fixtures.verification(profile: profile),
            applicationMetadata: applicationMetadata,
            signingIdentityID: identityID,
            signingConfiguration: configuration
        )
    }
}
