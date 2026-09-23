import Foundation

/// One safe, non-sensitive reason behind a policy status.
///
/// This is the shape intended for presentation if a screen ever needs to
/// explain a policy result: a category, a stable code, the status, and one
/// sentence of already-redacted text. It carries no identifiers, no certificate
/// bodies, no profile bytes, and no keys.
struct ProvisioningPolicySummaryReason: Equatable, Hashable {

    let category: ProvisioningPolicyCategory
    let code: ProvisioningPolicyFindingCode
    let status: ProvisioningPolicyStatus
    let text: String
}

/// A presentation-safe rendering of one policy evaluation.
///
/// The summary is derived from the result's own findings and adds no claim the
/// result does not make. There is deliberately no signed, installable, or
/// trusted flag here, and no action.
struct ProvisioningPolicyValidationSummary: Equatable, Hashable {

    /// The overall outcome.
    let overall: ProvisioningPolicyOutcome

    /// The status of each category.
    let profileAuthenticity: ProvisioningPolicyStatus
    let profileValidity: ProvisioningPolicyStatus
    let profileType: ProvisioningPolicyStatus
    let bundleIdentifier: ProvisioningPolicyStatus
    let teamIdentifier: ProvisioningPolicyStatus
    let certificate: ProvisioningPolicyStatus
    let entitlements: ProvisioningPolicyStatus
    let platform: ProvisioningPolicyStatus
    let device: ProvisioningPolicyStatus

    /// Trust evaluation state, always `notPerformed` on this path.
    let trustEvaluation: CMSTrustEvaluationStatus

    /// Platform authorization state, always `notEvaluated` on this path.
    let authorization: ProvisioningProfileAuthorizationStatus

    /// The reasons behind every category that was not satisfied, in category
    /// order, and nothing else.
    let reasons: [ProvisioningPolicySummaryReason]
}

/// What a caller must supply to have one signing configuration evaluated.
///
/// The request carries evidence that already exists — the staged verification
/// result, the application's declared metadata, the identifier being signed, an
/// optional identity identifier, the requested configuration, and whatever
/// device and platform context the caller has established. It carries no key
/// material, no raw profile bytes, and no interface state.
struct ValidateProvisioningConfigurationRequest: Equatable, Hashable {

    /// The staged result of verifying one provisioning profile. The use case
    /// reads its parsed profile, its authenticity state, and its certificate
    /// relationship; it never re-verifies the container.
    let verification: ProvisioningProfileVerification

    /// What the application declares about itself, when it is known.
    let applicationMetadata: ApplicationMetadata?

    /// The bundle identifier actually being signed, when it differs from the
    /// application's declared identifier.
    let bundleIdentifier: BundleIdentifier?

    /// The identity to evaluate, when the caller has one. The use case resolves
    /// its metadata through the identity store read-only.
    let signingIdentityID: SigningIdentityIdentifier?

    /// What the caller intends to sign with.
    let signingConfiguration: SigningConfiguration

    /// What the caller knows about the device this evaluation concerns.
    let deviceContext: ProvisioningDeviceContext

    /// The platforms the application is intended for, when the caller
    /// established them explicitly.
    let intendedPlatforms: [ProvisioningProfilePlatform]?

    init(
        verification: ProvisioningProfileVerification,
        applicationMetadata: ApplicationMetadata? = nil,
        bundleIdentifier: BundleIdentifier? = nil,
        signingIdentityID: SigningIdentityIdentifier? = nil,
        signingConfiguration: SigningConfiguration = SigningConfiguration(),
        deviceContext: ProvisioningDeviceContext = .unavailable,
        intendedPlatforms: [ProvisioningProfilePlatform]? = nil
    ) {
        self.verification = verification
        self.applicationMetadata = applicationMetadata
        self.bundleIdentifier = bundleIdentifier
        self.signingIdentityID = signingIdentityID
        self.signingConfiguration = signingConfiguration
        self.deviceContext = deviceContext
        self.intendedPlatforms = intendedPlatforms
    }
}

/// Evaluates whether an authenticated provisioning profile may be used with an
/// application, a signing identity, and a requested signing configuration,
/// under the policy rules ZynSign implements.
///
/// The use case orchestrates and nothing else:
///
///     Application metadata and bundle identifier
///             +
///     Authenticated provisioning profile and certificate relationship
///             +
///     Signing identity metadata
///             +
///     Requested signing configuration, device and platform context
///             ↓
///     ProvisioningPolicyValidator (Domain)
///             ↓
///     ProvisioningPolicyValidationResult
///
/// It keeps all policy logic in the domain, reads an identity store for
/// metadata only, and performs no signing. It does not modify a profile, an
/// entitlement, an `Info.plist`, a bundle identifier, a certificate, or a
/// Keychain item; it does not sign, repackage, install, or persist anything.
/// The result is derived from the profile, the application, the identity, the
/// configuration, and the current time, so it is not stored anywhere: a caller
/// that keeps it must define its own invalidation.
struct ValidateProvisioningConfigurationUseCase {

    private let policyValidator: ProvisioningPolicyValidator
    private let identityStore: (any IdentityStore)?

    init(
        policyValidator: ProvisioningPolicyValidator = ProvisioningPolicyValidator(clock: SystemEvaluationClock()),
        identityStore: (any IdentityStore)? = nil
    ) {
        self.policyValidator = policyValidator
        self.identityStore = identityStore
    }

    /// Evaluates one request.
    ///
    /// Nothing here throws. A profile whose container did not verify, and a
    /// profile that was never parsed, both produce a structured result whose
    /// non-authenticity categories are indeterminate, because "this payload is
    /// not authenticated" is a result and not an error in the caller's request.
    func validate(_ request: ValidateProvisioningConfigurationRequest) -> ProvisioningPolicyValidationResult {
        let context = ProvisioningPolicyValidationContext(
            profile: request.verification.profile,
            profileAuthenticity: request.verification.authenticity,
            certificateRelationship: request.verification.certificateRelationship,
            applicationMetadata: request.applicationMetadata,
            bundleIdentifier: request.bundleIdentifier,
            signingIdentity: signingIdentity(for: request.signingIdentityID),
            signingConfiguration: request.signingConfiguration,
            deviceContext: request.deviceContext,
            intendedPlatforms: request.intendedPlatforms
        )
        return policyValidator.validate(context)
    }

    /// Resolves identity metadata read-only.
    ///
    /// Metadata is the only thing requested: no signing capability is asked
    /// for, no key handle is resolved, and no signature is produced to prove
    /// possession. A store that cannot be read is recorded as a failed lookup
    /// rather than as an absent identity, because those are different facts and
    /// neither says anything about the profile.
    private func signingIdentity(for id: SigningIdentityIdentifier?) -> ProvisioningPolicySigningIdentity {
        guard let id else { return .notProvided }
        guard let identityStore else { return .notProvided }
        do {
            guard let metadata = try identityStore.metadata(for: id) else { return .noneAvailable }
            return .identity(metadata)
        } catch {
            return .lookupFailed
        }
    }
}

extension ProvisioningPolicyValidationResult {

    /// The presentation-safe rendering of this result.
    var summary: ProvisioningPolicyValidationSummary {
        ProvisioningPolicyValidationSummary(
            overall: overall,
            profileAuthenticity: profileAuthenticity,
            profileValidity: profileValidity,
            profileType: profileType,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            certificate: certificate,
            entitlements: entitlements,
            platform: platform,
            device: device,
            trustEvaluation: trustEvaluation,
            authorization: authorization,
            reasons: findings.compactMap { finding in
                guard finding.status != .satisfied else { return nil }
                return ProvisioningPolicySummaryReason(
                    category: finding.category,
                    code: finding.code,
                    status: finding.status,
                    text: finding.detail
                )
            }
        )
    }
}
