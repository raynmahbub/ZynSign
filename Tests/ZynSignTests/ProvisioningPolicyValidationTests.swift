import Foundation
import XCTest
@testable import ZynSign

/// Policy validation: the authenticity gate, every category rule, combined
/// failures, and the separations the pipeline must keep.
///
/// These tests are the ones that hold the trust boundary in place. An
/// authenticated profile is not a compatible profile; a matching certificate is
/// not compatible entitlements; compatible entitlements are not installation
/// authorization; and a compatible evaluation creates no signature.
final class ProvisioningPolicyValidationTests: XCTestCase {

    private typealias Fixtures = ProvisioningPolicyFixtures

    // MARK: - Baseline

    func testEveryCategoryIsSatisfiedForACompatibleConfiguration() {
        let result = Fixtures.validate(Fixtures.context())

        XCTAssertEqual(result.overall, .compatible)
        XCTAssertTrue(result.isPolicyCompatible)
        XCTAssertTrue(result.isEligibleForSigning)
        for category in ProvisioningPolicyCategory.allCases {
            XCTAssertEqual(result.status(for: category), .satisfied, "Unexpected status for \(category.rawValue)")
        }
        XCTAssertEqual(result.profileAuthenticity, .satisfied)
        XCTAssertEqual(result.profileValidity, .satisfied)
        XCTAssertEqual(result.profileType, .satisfied)
        XCTAssertEqual(result.bundleIdentifier, .satisfied)
        XCTAssertEqual(result.teamIdentifier, .satisfied)
        XCTAssertEqual(result.certificate, .satisfied)
        XCTAssertEqual(result.entitlements, .satisfied)
        XCTAssertEqual(result.platform, .satisfied)
        XCTAssertEqual(result.device, .satisfied)
        XCTAssertEqual(result.evaluationDate, Fixtures.evaluationDate)
        XCTAssertTrue(result.violations.isEmpty)
        XCTAssertTrue(result.indeterminateFindings.isEmpty)
    }

    func testCategoryResultsAreReportedInDeclaredOrder() {
        let result = Fixtures.validate(Fixtures.context())

        XCTAssertEqual(result.categories.map(\.category), ProvisioningPolicyCategory.allCases)
    }

    // MARK: - Authenticity gate

    func testUnauthenticatedProfileIsNotEvaluatedByPolicyRules() {
        let context = Fixtures.context(profileAuthenticity: .notEvaluated)
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.overall, .indeterminate)
        XCTAssertEqual(result.profileAuthenticity, .indeterminate)
        XCTAssertFalse(result.isEligibleForSigning)
        for category in ProvisioningPolicyCategory.allCases where category != .profileAuthenticity {
            XCTAssertEqual(result.status(for: category), .indeterminate, "Unexpected status for \(category.rawValue)")
            XCTAssertEqual(
                result.result(for: category)?.findings.first?.code,
                .profileAuthenticityNotEvaluated,
                "The gate must be visible in every category it stopped"
            )
        }
    }

    func testAuthenticatedProfileWithNoParsedPayloadIsIndeterminate() {
        let context = Fixtures.context(profile: nil, profileAuthenticity: .authenticated)
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.overall, .indeterminate)
        XCTAssertEqual(result.profileAuthenticity, .indeterminate)
        XCTAssertEqual(result.findings.first?.code, .profileNotParsed)
    }

    func testRejectedContainerIsIncompatibleAndLeavesEveryOtherQuestionOpen() {
        let context = Fixtures.context(
            profile: nil,
            profileAuthenticity: .rejected,
            certificateRelationship: Fixtures.relationship(match: .notEvaluated, signerFingerprint: nil)
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.overall, .incompatible)
        XCTAssertEqual(result.profileAuthenticity, .violated)
        XCTAssertEqual(result.violations.first?.code, .profileAuthenticityRejected)
        XCTAssertEqual(result.bundleIdentifier, .indeterminate)
        XCTAssertEqual(result.certificate, .indeterminate)
    }

    func testAuthenticatedProfileDoesNotBecomeCompatibleByAuthenticityAlone() {
        let context = Fixtures.context(
            profile: Fixtures.profile(applicationIdentifierComponent: Fixtures.otherBundleIdentifier)
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.profileAuthenticity, .satisfied)
        XCTAssertEqual(result.overall, .incompatible)
        XCTAssertEqual(result.bundleIdentifier, .violated)
    }

    // MARK: - Profile validity

    func testCurrentlyValidProfileIsSatisfied() {
        let result = Fixtures.validate(Fixtures.context(profile: Fixtures.profile()))

        XCTAssertEqual(result.profileValidity, .satisfied)
        XCTAssertEqual(result.findings.first { $0.category == .profileValidity }?.code, .profileWithinValidityPeriod)
    }

    func testExpiredProfileIsViolated() {
        let result = Fixtures.validate(Fixtures.context(), at: Fixtures.afterExpirationDate)

        XCTAssertEqual(result.profileValidity, .violated)
        XCTAssertEqual(result.overall, .incompatible)
        XCTAssertTrue(result.violations.contains { $0.code == .profileExpired })
    }

    func testNotYetValidProfileIsViolated() {
        let result = Fixtures.validate(Fixtures.context(), at: Fixtures.beforeCreationDate)

        XCTAssertEqual(result.profileValidity, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .profileNotYetValid })
    }

    func testExpirationBoundaryIsInclusive() {
        let atExpiration = Fixtures.validate(Fixtures.context(), at: Fixtures.expirationDate)
        let afterExpiration = Fixtures.validate(
            Fixtures.context(),
            at: Fixtures.expirationDate.addingTimeInterval(1)
        )

        XCTAssertEqual(atExpiration.profileValidity, .satisfied)
        XCTAssertEqual(afterExpiration.profileValidity, .violated)
    }

    func testCreationBoundaryIsInclusive() {
        let atCreation = Fixtures.validate(Fixtures.context(), at: Fixtures.creationDate)
        let beforeCreation = Fixtures.validate(
            Fixtures.context(),
            at: Fixtures.creationDate.addingTimeInterval(-1)
        )

        XCTAssertEqual(atCreation.profileValidity, .satisfied)
        XCTAssertEqual(beforeCreation.profileValidity, .violated)
    }

    func testExpirationStateChangesWithTheInjectedClockAndNotOtherwise() {
        let first = Fixtures.validate(Fixtures.context(), at: Fixtures.afterExpirationDate)
        let second = Fixtures.validate(Fixtures.context(), at: Fixtures.afterExpirationDate)
        let valid = Fixtures.validate(Fixtures.context(), at: Fixtures.evaluationDate)

        XCTAssertEqual(first.profileValidity, .violated)
        XCTAssertEqual(first, second, "The evaluation must be deterministic for identical inputs and instant.")
        XCTAssertEqual(valid.profileValidity, .satisfied)
        XCTAssertNotEqual(first.overall, valid.overall)
    }

    func testMalformedValidityIntervalIsViolated() {
        let profile = Fixtures.profile(
            creationDate: Fixtures.expirationDate,
            expirationDate: Fixtures.creationDate
        )
        let result = Fixtures.validate(Fixtures.context(profile: profile))

        XCTAssertEqual(result.profileValidity, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .profileDatesMalformed })
    }

    func testMissingDatesAreIndeterminateRatherThanViolated() {
        let profile = Fixtures.profile(creationDate: nil, expirationDate: nil)
        let result = Fixtures.validate(Fixtures.context(profile: profile))

        XCTAssertEqual(result.profileValidity, .indeterminate)
        XCTAssertFalse(result.violations.contains { $0.category == .profileValidity })
    }

    func testValidityWithinThePeriodIsNotTrust() {
        let result = Fixtures.validate(Fixtures.context())

        XCTAssertEqual(result.profileValidity, .satisfied)
        XCTAssertEqual(result.trustEvaluation, .notPerformed)
        XCTAssertEqual(result.authorization, .notEvaluated)
    }

    // MARK: - Profile classification

    func testKnownProfileClassesAreSatisfied() {
        for shape in [Fixtures.ProfileShape.enterprise, .development, .adHoc, .appStore] {
            let result = Fixtures.validate(Fixtures.context(profile: Fixtures.profile(shape: shape)))

            XCTAssertEqual(result.profileType, .satisfied, "Unexpected status for \(shape.rawValue)")
        }
    }

    func testUnknownProfileClassIsIndeterminate() {
        let result = Fixtures.validate(Fixtures.context(profile: Fixtures.profile(shape: .undetermined)))

        XCTAssertEqual(result.profileType, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .profileClassUnknown })
    }

    func testEstablishedClassThatIsNotTheIntendedClassIsViolated() {
        let context = Fixtures.context(
            profile: Fixtures.profile(shape: .enterprise),
            signingConfiguration: Fixtures.configuration(intendedProfileClass: .adHoc)
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.profileType, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .profileClassMismatch })
    }

    func testEstablishedClassThatIsTheIntendedClassIsSatisfied() {
        let context = Fixtures.context(
            profile: Fixtures.profile(shape: .development),
            signingConfiguration: Fixtures.configuration(intendedProfileClass: .development)
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.profileType, .satisfied)
    }

    func testIntendedClassThatIsItselfUnknownIsIndeterminate() {
        let context = Fixtures.context(
            profile: Fixtures.profile(shape: .enterprise),
            signingConfiguration: Fixtures.configuration(intendedProfileClass: .unknown)
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.profileType, .indeterminate)
    }

    // MARK: - Bundle identifier

    func testExactBundleIdentifierMatchIsSatisfied() {
        let result = Fixtures.validate(Fixtures.context())

        XCTAssertEqual(result.bundleIdentifier, .satisfied)
        XCTAssertTrue(result.findings.contains { $0.code == .bundleIdentifierExactMatch })
    }

    func testExactBundleIdentifierMismatchIsViolated() {
        let profile = Fixtures.profile(applicationIdentifierComponent: Fixtures.otherBundleIdentifier)
        let result = Fixtures.validate(Fixtures.context(profile: profile))

        XCTAssertEqual(result.bundleIdentifier, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .bundleIdentifierMismatch })
    }

    func testWildcardCompatibleBundleIdentifierIsSatisfied() {
        let profile = Fixtures.profile(applicationIdentifierComponent: "com.example.*")
        let result = Fixtures.validate(Fixtures.context(profile: profile))

        XCTAssertEqual(result.bundleIdentifier, .satisfied)
        XCTAssertTrue(result.findings.contains { $0.code == .bundleIdentifierWildcardMatch })
    }

    func testWildcardIncompatibleBundleIdentifierIsViolated() {
        let profile = Fixtures.profile(applicationIdentifierComponent: "com.other.*")
        let result = Fixtures.validate(Fixtures.context(profile: profile))

        XCTAssertEqual(result.bundleIdentifier, .violated)
    }

    func testMissingApplicationIdentifierIsIndeterminate() {
        let profile = Fixtures.profile(includeApplicationIdentifier: false)
        let result = Fixtures.validate(Fixtures.context(profile: profile))

        XCTAssertEqual(result.bundleIdentifier, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .profileApplicationIdentifierMissing })
    }

    func testMissingBundleIdentifierIsIndeterminate() {
        let context = Fixtures.context(applicationMetadata: nil, bundleIdentifier: nil)
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.bundleIdentifier, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .applicationBundleIdentifierMissing })
    }

    func testExplicitBundleIdentifierTakesPrecedenceOverDeclaredMetadata() {
        let profile = Fixtures.profile(applicationIdentifierComponent: Fixtures.otherBundleIdentifier)
        let context = Fixtures.context(
            profile: profile,
            bundleIdentifier: Fixtures.bundle(Fixtures.otherBundleIdentifier)
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.bundleIdentifier, .satisfied)
    }

    func testIdentifierThatCannotBeSplitIsIndeterminateNotAMismatch() throws {
        let profile = Fixtures.profile(
            entitlements: Fixtures.entitlements(
                applicationIdentifierValue: "TEAM123456.com.example.synthetic",
                getTaskAllow: false
            )
        )
        // The full value differs from the compared bundle identifier: without a
        // declared prefix the rule cannot split the value, so the outcome is
        // indeterminate rather than a mismatch. (Exact text equality without
        // a prefix is an exact match by the documented rule, so an equal
        // value could never exercise this path.)
        let unsplittable = ProvisioningProfile(
            uuid: profile.uuid,
            profileName: profile.profileName,
            creationDate: profile.creationDate,
            expirationDate: profile.expirationDate,
            platforms: profile.platforms,
            applicationIdentifier: try ProvisioningApplicationIdentifier(
                fullValue: Fixtures.otherBundleIdentifier,
                applicationIdentifierPrefix: nil
            ),
            applicationIdentifierPrefixes: nil,
            teamIdentifiers: profile.teamIdentifiers,
            entitlementTeamIdentifier: profile.entitlementTeamIdentifier,
            entitlements: profile.entitlements,
            provisionedDevices: profile.provisionedDevices,
            developerCertificates: profile.developerCertificates,
            getTaskAllow: profile.getTaskAllow,
            betaReportsActive: profile.betaReportsActive,
            provisionsAllDevices: profile.provisionsAllDevices,
            version: profile.version,
            isXcodeManaged: profile.isXcodeManaged
        )
        let result = Fixtures.validate(Fixtures.context(profile: unsplittable))

        XCTAssertEqual(result.bundleIdentifier, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .bundleIdentifierNotComparable })
    }

    func testChangingTheBundleIdentifierCannotTurnAnIncompatibleProfileIntoACompatibleOne() {
        let profile = Fixtures.profile(applicationIdentifierComponent: "com.example.exact")
        let mismatching = Fixtures.validate(
            Fixtures.context(profile: profile, bundleIdentifier: Fixtures.bundle("com.example.other"))
        )
        let matching = Fixtures.validate(
            Fixtures.context(profile: profile, bundleIdentifier: Fixtures.bundle("com.example.exact"))
        )

        XCTAssertEqual(mismatching.bundleIdentifier, .violated)
        XCTAssertEqual(matching.bundleIdentifier, .satisfied)
        XCTAssertNotEqual(mismatching.overall, matching.overall)
    }

    func testWildcardProfileCannotCoverAnIdentifierOutsideItsScope() {
        let profile = Fixtures.profile(applicationIdentifierComponent: "com.example.*")
        let result = Fixtures.validate(
            Fixtures.context(profile: profile, bundleIdentifier: Fixtures.bundle("com.exampleOther.app"))
        )

        XCTAssertEqual(result.bundleIdentifier, .violated)
        XCTAssertEqual(result.overall, .incompatible)
    }

    // MARK: - Team identifier

    func testMatchingTeamClaimAndIdentityAreSatisfied() {
        let context = Fixtures.context(
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: [
                    ProvisioningProfileEntitlementKeys.teamIdentifier: .string(Fixtures.teamIdentifier)
                ])
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.teamIdentifier, .satisfied)
        XCTAssertTrue(result.findings.contains { $0.code == .teamIdentifierClaimMatched })
        XCTAssertTrue(result.findings.contains { $0.code == .teamIdentifierIdentityMatched })
    }

    func testMismatchedTeamClaimIsViolated() {
        let context = Fixtures.context(
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: [
                    ProvisioningProfileEntitlementKeys.teamIdentifier: .string(Fixtures.otherTeamIdentifier)
                ])
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.teamIdentifier, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .teamIdentifierClaimMismatch })
    }

    func testMismatchedIdentityTeamIsViolated() {
        let identity = Fixtures.identityMetadata(organizationalUnits: [Fixtures.otherTeamIdentifier])
        let result = Fixtures.validate(Fixtures.context(signingIdentity: .identity(identity)))

        XCTAssertEqual(result.teamIdentifier, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .teamIdentifierIdentityMismatch })
    }

    func testProfileWithoutTeamInformationIsIndeterminate() {
        let profile = Fixtures.profile(
            teamIdentifiers: nil,
            entitlements: Fixtures.entitlements(teamValue: nil, getTaskAllow: false)
        )
        let result = Fixtures.validate(Fixtures.context(profile: profile))

        XCTAssertEqual(result.teamIdentifier, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .profileTeamIdentifierMissing })
    }

    func testIdentityWithoutAStructuredTeamAttributeIsIndeterminate() {
        let identity = Fixtures.identityMetadata(organizationalUnits: [])
        let result = Fixtures.validate(Fixtures.context(signingIdentity: .identity(identity)))

        XCTAssertEqual(result.teamIdentifier, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .teamIdentifierIdentityNotEstablished })
    }

    func testHumanReadableTeamShapedNamesAreNotUsedForTheIdentityComparison() {
        let identity = Fixtures.identityMetadata(
            organizationalUnits: [],
            commonName: Fixtures.teamIdentifier
        )
        let result = Fixtures.validate(Fixtures.context(signingIdentity: .identity(identity)))

        XCTAssertEqual(result.teamIdentifier, .indeterminate)
        XCTAssertFalse(result.findings.contains { $0.code == .teamIdentifierIdentityMatched })
    }

    func testTeamComparisonWithoutAnIdentityIsIndeterminate() {
        let result = Fixtures.validate(Fixtures.context(signingIdentity: .notProvided))

        XCTAssertEqual(result.teamIdentifier, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .signingIdentityNotProvided })
    }

    func testNonStringTeamClaimIsIndeterminate() {
        let context = Fixtures.context(
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: [
                    ProvisioningProfileEntitlementKeys.teamIdentifier: .integer(7)
                ])
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.teamIdentifier, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .teamIdentifierClaimNotComparable })
    }

    func testTeamIdentifierShapeRuleAcceptsTenUppercaseAlphanumericsOnly() {
        XCTAssertTrue(ProvisioningPolicyValidator.isTeamIdentifierCandidate("TEAM123456"))
        XCTAssertFalse(ProvisioningPolicyValidator.isTeamIdentifierCandidate("TEAM12345"))
        XCTAssertFalse(ProvisioningPolicyValidator.isTeamIdentifierCandidate("team123456"))
        XCTAssertFalse(ProvisioningPolicyValidator.isTeamIdentifierCandidate("TEAM 12345"))
    }

    // MARK: - Certificate

    func testMatchingSigningCertificateIsSatisfied() {
        let result = Fixtures.validate(Fixtures.context())

        XCTAssertEqual(result.certificate, .satisfied)
        XCTAssertTrue(result.findings.contains { $0.code == .signingIdentityCertificateMatched })
        XCTAssertTrue(result.findings.contains { $0.code == .signingIdentityUsableForSigning })
    }

    func testMismatchedSigningCertificateIsViolated() {
        let identity = Fixtures.identityMetadata(fingerprint: Fixtures.unrelatedFingerprint)
        let result = Fixtures.validate(Fixtures.context(signingIdentity: .identity(identity)))

        XCTAssertEqual(result.certificate, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .signingIdentityCertificateMismatch })
        XCTAssertFalse(result.violations.contains { $0.code == .signingKeyUnavailable })
    }

    func testProfileWithoutCertificateReferencesIsIndeterminate() {
        let relationship = Fixtures.relationship(
            profileCertificates: [],
            match: .incomparable,
            signerFingerprint: Fixtures.unrelatedFingerprint
        )
        let result = Fixtures.validate(Fixtures.context(certificateRelationship: relationship))

        XCTAssertEqual(result.certificate, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .profileCarriesNoCertificateReferences })
    }

    func testMissingSigningIdentityIsIndeterminateAndDistinctFromAMismatch() {
        for identity in [
            ProvisioningPolicySigningIdentity.notProvided,
            .noneAvailable,
            .lookupFailed,
        ] {
            let result = Fixtures.validate(Fixtures.context(signingIdentity: identity))

            XCTAssertEqual(result.certificate, .indeterminate)
            XCTAssertFalse(
                result.violations.contains { $0.code == .signingIdentityCertificateMismatch },
                "An absent identity is not a certificate mismatch."
            )
            XCTAssertFalse(
                result.violations.contains { $0.code == .profileDatesMalformed },
                "An absent identity says nothing about the profile."
            )
        }
    }

    func testIdentityLookupFailureIsReportedAsAFailedLookup() {
        let result = Fixtures.validate(Fixtures.context(signingIdentity: .lookupFailed))

        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .signingIdentityLookupFailed })
        XCTAssertEqual(result.profileValidity, .satisfied)
    }

    func testMultipleProfileCertificatesContainingTheIdentityCertificateAreSatisfied() {
        let relationship = Fixtures.relationship(
            profileCertificates: [Fixtures.unrelatedFingerprint, Fixtures.profileCertificateFingerprint]
        )
        let result = Fixtures.validate(Fixtures.context(certificateRelationship: relationship))

        XCTAssertEqual(result.certificate, .satisfied)
    }

    func testProfileReferencesWithoutComparableMetadataAreIndeterminate() {
        let relationship = Fixtures.relationship(profileReferenceWithoutMetadataCount: 1)
        let result = Fixtures.validate(Fixtures.context(certificateRelationship: relationship))

        XCTAssertEqual(result.certificate, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .profileCertificateMetadataUnavailable })
    }

    func testProfileCertificatesWithoutAnyComparableFingerprintAreIndeterminate() {
        let relationship = ProvisioningProfileCertificateRelationship(
            signerCertificateStatus: .extracted,
            signerFingerprint: Fixtures.profileCertificateFingerprint,
            profileCertificateCount: 1,
            profileCertificateFingerprints: [],
            match: .incomparable
        )
        let result = Fixtures.validate(Fixtures.context(certificateRelationship: relationship))

        XCTAssertEqual(result.certificate, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .profileCertificateFingerprintsUnavailable })
    }

    func testMatchingCertificateWithoutAUsableKeyIsIndeterminate() {
        let identity = Fixtures.identityMetadata(keyAvailability: .unavailable)
        let result = Fixtures.validate(Fixtures.context(signingIdentity: .identity(identity)))

        XCTAssertEqual(result.certificate, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .signingKeyUnavailable })
        XCTAssertTrue(result.findings.contains { $0.code == .signingIdentityCertificateMatched })
        XCTAssertFalse(
            result.violations.contains { $0.code == .signingIdentityCertificateMismatch },
            "A missing key must not be reported as a certificate mismatch."
        )
    }

    func testUnreadyCapabilityIsIndeterminate() {
        let identity = Fixtures.identityMetadata(
            association: .unknown,
            capabilityState: .authorizationRequired
        )
        let result = Fixtures.validate(Fixtures.context(signingIdentity: .identity(identity)))

        XCTAssertEqual(result.certificate, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .signingCapabilityNotReady })
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .signingKeyAssociationNotEstablished })
    }

    func testSignerOutsideTheProfileCertificatesIsAnOpenQuestionNotAViolation() {
        let relationship = Fixtures.relationship(match: .mismatched)
        let result = Fixtures.validate(Fixtures.context(certificateRelationship: relationship))

        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .containerSignerNotProfileCertificate })
        XCTAssertFalse(result.violations.contains { $0.code == .containerSignerNotProfileCertificate })
    }

    func testChangingTheSigningCertificateCannotPreserveCompatibility() {
        let compatible = Fixtures.validate(Fixtures.context())
        let incompatible = Fixtures.validate(
            Fixtures.context(signingIdentity: .identity(Fixtures.identityMetadata(fingerprint: Fixtures.unrelatedFingerprint)))
        )

        XCTAssertEqual(compatible.certificate, .satisfied)
        XCTAssertEqual(incompatible.certificate, .violated)
        XCTAssertNotEqual(compatible.overall, incompatible.overall)
    }

    // MARK: - Entitlements

    func testMatchingStringClaimIsSatisfied() {
        let context = Fixtures.context(
            profile: Fixtures.profile(
                entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("value")])
            )
        ,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("value")])
            ))
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .satisfied)
        XCTAssertTrue(result.findings.contains { $0.code == .entitlementAuthorized })
    }

    func testMismatchedStringClaimIsViolated() {
        let context = Fixtures.context(
            profile: Fixtures.profile(
                entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("value")])
            )
        ,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("other")])
            ))
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .entitlementValueConflict })
    }

    func testClaimTheProfileDoesNotCarryIsViolated() {
        let context = Fixtures.context(
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["com.example.extra": .boolean(true)])
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .entitlementNotAuthorized })
    }

    func testBooleanClaimIsComparedLiterally() {
        let profile = Fixtures.profile(
            entitlements: Fixtures.entitlements(additional: ["beta-reports-active": .boolean(true)])
        )
        let matching = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["beta-reports-active": .boolean(true)])
            )
        )
        let conflicting = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["beta-reports-active": .boolean(false)])
            )
        )

        XCTAssertEqual(Fixtures.validate(matching).entitlements, .satisfied)
        XCTAssertEqual(Fixtures.validate(conflicting).entitlements, .violated)
    }

    func testArrayClaimIsComparedByEstablishedBehaviourOnly() {
        let profile = Fixtures.profile(
            entitlements: Fixtures.entitlements(additional: [
                "com.example.groups": .array([.string("one"), .string("two")])
            ])
        )
        let identical = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: [
                    "com.example.groups": .array([.string("one"), .string("two")])
                ])
            )
        )
        let contained = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["com.example.groups": .array([.string("one")])])
            )
        )
        let outside = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: [
                    "com.example.groups": .array([.string("one"), .string("three")])
                ])
            )
        )

        XCTAssertEqual(Fixtures.validate(identical).entitlements, .satisfied)
        XCTAssertEqual(Fixtures.validate(contained).entitlements, .indeterminate)
        XCTAssertEqual(Fixtures.validate(outside).entitlements, .violated)
    }

    func testDictionaryClaimIsComparedByItsClaimedKeys() {
        let profile = Fixtures.profile(
            entitlements: Fixtures.entitlements(additional: [
                "com.example.mode": .dictionary(["mode": .string("production")])
            ])
        )
        let matching = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: [
                    "com.example.mode": .dictionary(["mode": .string("production")])
                ])
            )
        )
        let conflicting = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: [
                    "com.example.mode": .dictionary(["mode": .string("development")])
                ])
            )
        )

        XCTAssertEqual(Fixtures.validate(matching).entitlements, .satisfied)
        XCTAssertEqual(Fixtures.validate(conflicting).entitlements, .violated)
    }

    func testUnsupportedValueFormIsIndeterminate() {
        let context = Fixtures.context(
            profile: Fixtures.profile(
                entitlements: Fixtures.entitlements(additional: ["com.example.blob": .data(Data([0x01]))])
            )
        ,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["com.example.blob": .data(Data([0x01]))])
            ))
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .entitlementValueUnsupported })
    }

    func testClaimSetThatWasNotEstablishedIsIndeterminate() {
        let context = Fixtures.context(signingConfiguration: Fixtures.configuration(entitlements: nil))
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .requestedEntitlementsNotEstablished })
    }

    func testEmptyClaimSetIsSatisfiedWithoutPretendingAComparisonHappened() {
        let result = Fixtures.validate(Fixtures.context())

        XCTAssertEqual(result.entitlements, .satisfied)
        XCTAssertTrue(result.findings.contains { $0.code == .entitlementAuthorized })
    }

    func testProfileWithoutAnAllowlistIsIndeterminate() {
        let profile = Fixtures.profile(includeEntitlements: false)
        let context = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("value")])
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .entitlementValueNotComparable })
    }

    func testProfileAllowlistWithoutAnIdentifierEntitlementIsIndeterminate() {
        let profile = Fixtures.profile(
            entitlements: Fixtures.entitlements(applicationIdentifierValue: nil, getTaskAllow: false)
        )
        let result = Fixtures.validate(Fixtures.context(profile: profile))

        XCTAssertEqual(result.entitlements, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .profileIdentifierEntitlementMissing })
    }

    func testProfileIdentifierEntitlementThatDisagreesWithTheDeclaredIdentifierIsViolated() {
        let profile = Fixtures.profile(
            entitlements: Fixtures.entitlements(
                applicationIdentifierValue: "\(Fixtures.teamIdentifier).\(Fixtures.otherBundleIdentifier)",
                getTaskAllow: false
            )
        )
        let result = Fixtures.validate(Fixtures.context(profile: profile))

        XCTAssertEqual(result.entitlements, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .profileIdentifierEntitlementInconsistent })
    }

    func testIdentifierClaimInsideTheProfileScopeIsSatisfied() {
        let context = Fixtures.context(
            profile: Fixtures.profile(applicationIdentifierComponent: "com.example.*"),
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(
                    applicationIdentifierValue: "\(Fixtures.teamIdentifier).\(Fixtures.bundleIdentifier)"
                )
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .satisfied)
        XCTAssertTrue(result.findings.contains { $0.code == .applicationIdentifierClaimMatched })
    }

    func testIdentifierClaimOutsideTheProfileScopeIsViolated() {
        let context = Fixtures.context(
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(
                    applicationIdentifierValue: "\(Fixtures.teamIdentifier).\(Fixtures.otherBundleIdentifier)"
                )
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .applicationIdentifierClaimMismatch })
    }

    func testIdentifierClaimThatDoesNotDescribeTheApplicationIsViolated() {
        let context = Fixtures.context(
            profile: Fixtures.profile(applicationIdentifierComponent: "com.example.*"),
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(
                    applicationIdentifierValue: "\(Fixtures.teamIdentifier).com.example.somethingelse"
                )
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .applicationIdentifierDoesNotDescribeApplication })
    }

    func testNonStringIdentifierClaimIsIndeterminate() {
        let context = Fixtures.context(
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: [
                    ProvisioningProfileEntitlementKeys.applicationIdentifier: .integer(1)
                ])
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .applicationIdentifierClaimNotComparable })
    }

    func testChangingAnAuthorizedEntitlementToAnIncompatibleValueProducesAFailure() {
        let authorized = Fixtures.profile(
            entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("authorized")])
        )
        let allowed = Fixtures.validate(
            Fixtures.context(
                profile: authorized,
                signingConfiguration: Fixtures.configuration(
                    entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("authorized")])
                )
            )
        )
        let changed = Fixtures.validate(
            Fixtures.context(
                profile: authorized,
                signingConfiguration: Fixtures.configuration(
                    entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("changed")])
                )
            )
        )

        XCTAssertEqual(allowed.entitlements, .satisfied)
        XCTAssertEqual(changed.entitlements, .violated)
        XCTAssertNotEqual(allowed.overall, changed.overall)
    }

    func testEntitlementCompatibilityDoesNotRewriteAnything() {
        let profile = Fixtures.profile(
            entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("authorized")])
        )
        let context = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("changed")])
            )
        )
        let entitlementsBefore = context.profile?.entitlements
        let requestedBefore = context.signingConfiguration.entitlements

        _ = Fixtures.validate(context)

        XCTAssertEqual(context.profile?.entitlements, entitlementsBefore)
        XCTAssertEqual(context.signingConfiguration.entitlements, requestedBefore)
        XCTAssertEqual(
            context.profile?.entitlements?["com.example.claim"],
            .string("authorized"),
            "Policy evaluation must not strip, add, or edit a claim."
        )
    }

    // MARK: - get-task-allow

    func testRequestedDebuggingValueAuthorizedByTheProfileIsSatisfied() {
        let profile = Fixtures.profile(shape: .development)
        let context = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(getTaskAllow: .requested(true))
        )
        let result = Fixtures.validate(context)

        XCTAssertTrue(result.findings.contains { $0.code == .getTaskAllowMatched })
        XCTAssertEqual(result.entitlements, .satisfied)
    }

    func testRequestedDebuggingValueTheProfileForbidsIsViolated() {
        let context = Fixtures.context(signingConfiguration: Fixtures.configuration(getTaskAllow: .requested(true)))
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .getTaskAllowNotAuthorized })
    }

    func testRequestedDebuggingIsDistinguishedFromAnAbsentField() {
        let profile = Fixtures.profile(
            entitlements: Fixtures.entitlements(getTaskAllow: nil, betaReportsActive: true)
        )
        let context = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(getTaskAllow: .requested(true))
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .getTaskAllowAbsentFromProfile })
        XCTAssertFalse(result.violations.contains { $0.code == .getTaskAllowNotAuthorized })
    }

    func testDisclaimedDebuggingValueAgainstAnAuthorizingProfileIsAnOpenQuestion() {
        let profile = Fixtures.profile(shape: .development)
        let context = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(getTaskAllow: .requested(false))
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .getTaskAllowValueNotEstablished })
        XCTAssertFalse(result.violations.contains { $0.category == .entitlements })
    }

    func testDisclaimedDebuggingValueAgainstAPermissiveProfileIsSatisfied() {
        let context = Fixtures.context(signingConfiguration: Fixtures.configuration(getTaskAllow: .requested(false)))
        let result = Fixtures.validate(context)

        XCTAssertTrue(result.findings.contains { $0.code == .getTaskAllowMatched })
        XCTAssertEqual(result.entitlements, .satisfied)
    }

    func testDisclaimedDebuggingValueAgainstAnAbsentFieldStaysOpen() {
        let profile = Fixtures.profile(
            entitlements: Fixtures.entitlements(getTaskAllow: nil, betaReportsActive: true)
        )
        let context = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(getTaskAllow: .requested(false))
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .getTaskAllowAbsentFromProfile })
    }

    func testUnrequestedDebuggingValueIsNotCompared() {
        let result = Fixtures.validate(Fixtures.context())

        XCTAssertFalse(result.findings.contains { $0.category == .entitlements && $0.code == .getTaskAllowMatched })
        XCTAssertFalse(result.findings.contains { $0.code == .getTaskAllowNotAuthorized })
        XCTAssertFalse(result.findings.contains { $0.code == .getTaskAllowValueNotEstablished })
    }

    func testDebuggingClaimOfTheWrongTypeIsNotCompared() {
        let context = Fixtures.context(
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(getTaskAllow: nil, additional: [
                    ProvisioningProfileEntitlementKeys.getTaskAllow: .integer(1)
                ])
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .getTaskAllowNotComparable })
    }

    func testContradictoryDebuggingRequestsAreNotResolved() {
        let context = Fixtures.context(
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(getTaskAllow: false),
                getTaskAllow: .requested(true)
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .getTaskAllowConfigurationAmbiguous })
    }

    func testProfileDebuggingClaimOfTheWrongTypeIsNotCompared() {
        let profile = Fixtures.profile(
            entitlements: Fixtures.entitlements(getTaskAllow: nil, additional: [
                ProvisioningProfileEntitlementKeys.getTaskAllow: .integer(1)
            ])
        )
        let context = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(getTaskAllow: .requested(true))
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .getTaskAllowNotComparable })
    }

    // MARK: - Platform

    func testSupportedPlatformIsSatisfied() {
        let result = Fixtures.validate(Fixtures.context())

        XCTAssertEqual(result.platform, .satisfied)
        XCTAssertTrue(result.findings.contains { $0.code == .platformSupported })
    }

    func testUnsupportedPlatformIsViolated() {
        let context = Fixtures.context(
            profile: Fixtures.profile(platforms: [.macOS]),
            applicationMetadata: Fixtures.applicationMetadata(deviceFamilies: [.phone])
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.platform, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .platformNotSupported })
    }

    func testUnrecognisedPlatformSpellingIsIndeterminate() {
        let context = Fixtures.context(profile: Fixtures.profile(platforms: [.unknown("SomeFutureOS")]))
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.platform, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .platformNotComparable })
    }

    func testProfileWithoutPlatformInformationIsIndeterminate() {
        let result = Fixtures.validate(Fixtures.context(profile: Fixtures.profile(platforms: nil)))

        XCTAssertEqual(result.platform, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .platformNotDeclared })
    }

    func testApplicationPlatformThatIsNotEstablishedIsIndeterminate() {
        let context = Fixtures.context(applicationMetadata: Fixtures.applicationMetadata(deviceFamilies: nil))
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.platform, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .applicationPlatformNotEstablished })
    }

    func testUnrecognisedDeviceFamilyEstablishesNoPlatform() {
        let context = Fixtures.context(applicationMetadata: Fixtures.applicationMetadata(deviceFamilies: [.unknown(99)]))
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.platform, .indeterminate)
    }

    func testPlatformCanBeDerivedFromADeclaredDeviceFamily() {
        let context = Fixtures.context(
            profile: Fixtures.profile(platforms: [.tvOS]),
            applicationMetadata: Fixtures.applicationMetadata(deviceFamilies: [.tv])
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.platform, .satisfied)
        XCTAssertEqual(ProvisioningPolicyPlatformScope.from(deviceFamilies: [.phone, .pad]), .established([.iPhoneOS]))
    }

    func testExplicitlyStatedPlatformsTakePrecedenceOverDeclaredFamilies() {
        let context = Fixtures.context(
            profile: Fixtures.profile(platforms: [.macOS]),
            applicationMetadata: Fixtures.applicationMetadata(deviceFamilies: [.phone]),
            intendedPlatforms: [.macOS]
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.platform, .satisfied)
    }

    // MARK: - Device

    func testProfileWithoutDeviceRestrictionIsSatisfied() {
        let result = Fixtures.validate(Fixtures.context(profile: Fixtures.profile(shape: .enterprise)))

        XCTAssertEqual(result.device, .satisfied)
        XCTAssertTrue(result.findings.contains { $0.code == .deviceRestrictionAbsent })
    }

    func testProvisionedDeviceIsSatisfied() {
        let context = Fixtures.context(
            profile: Fixtures.profile(shape: .adHoc),
            deviceContext: .identified(Fixtures.deviceA)
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.device, .satisfied)
        XCTAssertTrue(result.findings.contains { $0.code == .deviceProvisioned })
    }

    func testUnprovisionedDeviceIsViolated() {
        let context = Fixtures.context(
            profile: Fixtures.profile(shape: .adHoc),
            deviceContext: .identified(Fixtures.deviceB)
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.device, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .deviceNotProvisioned })
    }

    func testDeviceRestrictedProfileWithoutDeviceContextIsDeferred() {
        let context = Fixtures.context(
            profile: Fixtures.profile(shape: .adHoc),
            deviceContext: .unavailable
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.device, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .deviceContextUnavailable })
    }

    func testDeviceListWithProvisionsAllDevicesIsInconsistent() {
        let result = Fixtures.validate(Fixtures.context(profile: Fixtures.profile(shape: .enterpriseWithDeviceList)))

        XCTAssertEqual(result.device, .indeterminate)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .deviceRestrictionInconsistent })
    }

    func testEmptyDeviceListRestrictsToNoDevice() {
        let context = Fixtures.context(
            profile: Fixtures.profile(shape: .adHoc, provisionedDevices: []),
            deviceContext: .identified(Fixtures.deviceA)
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.device, .violated)
        XCTAssertTrue(result.violations.contains { $0.code == .deviceNotProvisioned })
    }

    func testANonEmptyDeviceListIsNotAnAuthorizationForTheRunningDevice() {
        let result = Fixtures.validate(Fixtures.context(profile: Fixtures.profile(shape: .adHoc)))

        XCTAssertEqual(result.device, .indeterminate)
        XCTAssertFalse(result.findings.contains { $0.code == .deviceProvisioned })
    }

    // MARK: - Combined failures and aggregation

    func testEveryMeaningfulFailureIsReportedTogether() {
        let profile = Fixtures.profile(
            shape: .adHoc,
            applicationIdentifierComponent: Fixtures.otherBundleIdentifier,
            entitlements: Fixtures.entitlements(
                applicationIdentifierValue: "\(Fixtures.teamIdentifier).\(Fixtures.otherBundleIdentifier)",
                getTaskAllow: false
            )
        )
        let context = Fixtures.context(
            profile: profile,
            certificateRelationship: Fixtures.relationship(match: .mismatched),
            signingIdentity: .identity(Fixtures.identityMetadata(fingerprint: Fixtures.unrelatedFingerprint)),
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(
                    // No debugging claim: the default `false` would contradict
                    // the requested `true` below, which is ambiguous rather
                    // than unauthorized (see
                    // testContradictoryDebuggingRequestsAreNotResolved).
                    getTaskAllow: nil,
                    additional: ["com.example.unapproved": .string("value")]
                )
            ,
                getTaskAllow: .requested(true)),
            deviceContext: .identified(Fixtures.deviceB)
        )
        let result = Fixtures.validate(context, at: Fixtures.afterExpirationDate)

        XCTAssertEqual(result.overall, .incompatible)
        let violatedCodes = Set(result.violations.map(\.code))
        XCTAssertTrue(violatedCodes.contains(.profileExpired))
        XCTAssertTrue(violatedCodes.contains(.bundleIdentifierMismatch))
        XCTAssertTrue(violatedCodes.contains(.signingIdentityCertificateMismatch))
        XCTAssertTrue(violatedCodes.contains(.getTaskAllowNotAuthorized))
        XCTAssertTrue(violatedCodes.contains(.entitlementNotAuthorized))
        XCTAssertTrue(violatedCodes.contains(.deviceNotProvisioned))
        XCTAssertEqual(result.profileValidity, .violated)
        XCTAssertEqual(result.bundleIdentifier, .violated)
        XCTAssertEqual(result.certificate, .violated)
        XCTAssertEqual(result.entitlements, .violated)
        XCTAssertEqual(result.device, .violated)
    }

    func testAnIndeterminateCategoryPreventsACompatibleOutcome() {
        let result = Fixtures.validate(Fixtures.context(signingIdentity: .notProvided))

        XCTAssertEqual(result.overall, .indeterminate)
        XCTAssertFalse(result.isEligibleForSigning)
        XCTAssertTrue(result.violations.isEmpty)
        XCTAssertFalse(result.indeterminateFindings.isEmpty)
    }

    func testCategoryStatusFollowsItsMostSevereFinding() {
        let category = ProvisioningPolicyCategory.bundleIdentifier

        XCTAssertEqual(ProvisioningPolicyCategoryResult.deriveStatus(from: []), .indeterminate)
        XCTAssertEqual(
            ProvisioningPolicyCategoryResult.deriveStatus(from: [
                ProvisioningPolicyFinding(category: category, status: .satisfied, code: .bundleIdentifierExactMatch, detail: "")
            ]),
            .satisfied
        )
        XCTAssertEqual(
            ProvisioningPolicyCategoryResult.deriveStatus(from: [
                ProvisioningPolicyFinding(category: category, status: .satisfied, code: .bundleIdentifierExactMatch, detail: ""),
                ProvisioningPolicyFinding(category: category, status: .indeterminate, code: .bundleIdentifierNotComparable, detail: ""),
            ]),
            .indeterminate
        )
        XCTAssertEqual(
            ProvisioningPolicyCategoryResult.deriveStatus(from: [
                ProvisioningPolicyFinding(category: category, status: .indeterminate, code: .bundleIdentifierNotComparable, detail: ""),
                ProvisioningPolicyFinding(category: category, status: .violated, code: .bundleIdentifierMismatch, detail: ""),
            ]),
            .violated
        )
    }

    func testResultWithoutAnyCategoryIsIndeterminate() {
        let result = ProvisioningPolicyValidationResult(
            evaluationDate: Fixtures.evaluationDate,
            categories: []
        )

        XCTAssertEqual(result.overall, .indeterminate)
        XCTAssertEqual(result.status(for: .bundleIdentifier), .indeterminate)
    }

    func testEveryCategoryStatusIsDerivedFromFindingsItCarries() {
        let result = Fixtures.validate(
            Fixtures.context(
                profile: Fixtures.profile(shape: .adHoc, applicationIdentifierComponent: "com.other.*"),
                signingIdentity: .lookupFailed,
                deviceContext: .identified(Fixtures.deviceB)
            ),
            at: Fixtures.afterExpirationDate
        )

        for category in result.categories {
            XCTAssertFalse(category.findings.isEmpty, "\(category.category.rawValue) reported no evidence")
            XCTAssertEqual(category.status, ProvisioningPolicyCategoryResult.deriveStatus(from: category.findings))
        }
    }

    // MARK: - Determinism, isolation and redaction

    func testEvaluationIsDeterministicForIdenticalInputs() {
        let context = Fixtures.context()

        XCTAssertEqual(Fixtures.validate(context), Fixtures.validate(context))
    }

    func testEvaluationDoesNotMutateItsInput() {
        let profile = Fixtures.profile(
            entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("authorized")])
        )
        let configuration = Fixtures.configuration(
            entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("changed")])
        )
        let context = Fixtures.context(profile: profile, signingConfiguration: configuration)

        _ = Fixtures.validate(context)

        XCTAssertEqual(context, Fixtures.context(profile: profile, signingConfiguration: configuration))
        XCTAssertEqual(context.profile?.provisionedDevices, profile.provisionedDevices)
        XCTAssertEqual(context.profile?.platforms, profile.platforms)
        XCTAssertEqual(context.profile?.teamIdentifiers, profile.teamIdentifiers)
        XCTAssertEqual(
            context.profile?.entitlements?["com.example.claim"],
            .string("authorized"),
            "The profile's claim must survive evaluation unchanged."
        )
        XCTAssertEqual(
            context.signingConfiguration.entitlements?["com.example.claim"],
            .string("changed"),
            "The requested claim must survive evaluation unchanged."
        )
    }

    func testHostileFieldCombinationsCannotCrashTheValidator() {
        let profile = ProvisioningProfile(
            platforms: [.unknown("")],
            applicationIdentifier: Fixtures.applicationIdentifier(component: "*"),
            teamIdentifiers: [""],
            entitlements: ProvisioningProfileEntitlements(values: [
                ProvisioningProfileEntitlementKeys.applicationIdentifier: .integer(-1),
                ProvisioningProfileEntitlementKeys.getTaskAllow: .array([]),
            ])
        )
        let context = Fixtures.context(
            profile: profile,
            signingConfiguration: Fixtures.configuration(
                entitlements: ProvisioningProfileEntitlements(values: [
                    "": .dictionary([:]),
                    ProvisioningProfileEntitlementKeys.applicationIdentifier: .array([.string("")]),
                ])
            ,
                getTaskAllow: .requested(true))
        )

        let result = Fixtures.validate(context)

        XCTAssertNotEqual(result.overall, .compatible)
        XCTAssertEqual(result.categories.map(\.category), ProvisioningPolicyCategory.allCases)
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .profileIdentifierEntitlementNotComparable })
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .getTaskAllowNotComparable })
        XCTAssertTrue(result.indeterminateFindings.contains { $0.code == .platformNotComparable })
    }

    func testDiagnosticsCarryStatesAndCodesWithoutValuesOrIdentifiers() {
        let profile = Fixtures.profile(applicationIdentifierComponent: Fixtures.otherBundleIdentifier)
        let result = Fixtures.validate(Fixtures.context(profile: profile))
        let diagnostic = result.diagnosticDescription

        XCTAssertTrue(diagnostic.contains("policy.overall(incompatible)"))
        XCTAssertTrue(diagnostic.contains("policy.bundleIdentifier(violated)"))
        XCTAssertTrue(diagnostic.contains("bundleIdentifierMismatch"))
        XCTAssertTrue(diagnostic.contains("policy.trust(notPerformed)"))
        XCTAssertTrue(diagnostic.contains("policy.authorization(notEvaluated)"))
        XCTAssertFalse(diagnostic.contains(Fixtures.bundleIdentifier))
        XCTAssertFalse(diagnostic.contains(Fixtures.otherBundleIdentifier))
        XCTAssertFalse(diagnostic.contains(Fixtures.teamIdentifier))
        XCTAssertFalse(diagnostic.contains(Fixtures.deviceA.rawValue))
        XCTAssertFalse(diagnostic.contains("-----BEGIN"))
    }

    func testFindingsNeverCarryAFullEntitlementValue() {
        let context = Fixtures.context(
            profile: Fixtures.profile(
                entitlements: Fixtures.entitlements(additional: ["com.example.secret": .string("super-secret-value")])
            ),
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["com.example.secret": .string("other-secret-value")])
            )
        )
        let result = Fixtures.validate(context)

        for finding in result.findings {
            XCTAssertFalse(finding.detail.contains("super-secret-value"))
            XCTAssertFalse(finding.detail.contains("other-secret-value"))
        }
    }

    // MARK: - Trust separation

    func testPolicyCompatibilityIsNotTrustAndNotAuthorization() {
        let result = Fixtures.validate(Fixtures.context())

        XCTAssertTrue(result.isEligibleForSigning)
        XCTAssertEqual(result.trustEvaluation, .notPerformed)
        XCTAssertEqual(result.authorization, .notEvaluated)
        XCTAssertFalse(result.diagnosticDescription.contains("trusted"))
        XCTAssertFalse(result.diagnosticDescription.contains("install"))
    }

    func testCertificateMatchDoesNotImplyEntitlementCompatibility() {
        let context = Fixtures.context(
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["com.example.unapproved": .boolean(true)])
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.certificate, .satisfied)
        XCTAssertEqual(result.entitlements, .violated)
        XCTAssertEqual(result.overall, .incompatible)
    }

    func testEntitlementCompatibilityDoesNotImplyInstallationAuthorization() {
        let context = Fixtures.context(
            profile: Fixtures.profile(
                entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("value")])
            ),
            signingConfiguration: Fixtures.configuration(
                entitlements: Fixtures.entitlements(additional: ["com.example.claim": .string("value")])
            )
        )
        let result = Fixtures.validate(context)

        XCTAssertEqual(result.entitlements, .satisfied)
        XCTAssertEqual(result.authorization, .notEvaluated)
        XCTAssertEqual(result.trustEvaluation, .notPerformed)
    }

    func testDegradingAnySingleFactDegradesTheOutcome() {
        let baseline = Fixtures.validate(Fixtures.context())
        XCTAssertEqual(baseline.overall, .compatible)

        let expired = Fixtures.validate(Fixtures.context(), at: Fixtures.afterExpirationDate)
        let wrongBundle = Fixtures.validate(
            Fixtures.context(profile: Fixtures.profile(applicationIdentifierComponent: Fixtures.otherBundleIdentifier))
        )
        let wrongCertificate = Fixtures.validate(
            Fixtures.context(signingIdentity: .identity(Fixtures.identityMetadata(fingerprint: Fixtures.unrelatedFingerprint)))
        )
        let unapprovedClaim = Fixtures.validate(
            Fixtures.context(
                signingConfiguration: Fixtures.configuration(
                    entitlements: Fixtures.entitlements(additional: ["com.example.unapproved": .boolean(true)])
                )
            )
        )

        for result in [expired, wrongBundle, wrongCertificate, unapprovedClaim] {
            XCTAssertNotEqual(result.overall, .compatible)
            XCTAssertFalse(result.isEligibleForSigning)
        }
    }
}
