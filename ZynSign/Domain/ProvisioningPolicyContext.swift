import Foundation

/// The debugging claim a caller intends to make when signing.
///
/// `get-task-allow` is an entitlement, so a caller can express it either as a
/// typed preference or as an entry in the claim set. The preference is kept
/// typed because absence, `false`, and "not stated" are three different things
/// and a plain optional boolean cannot represent them.
enum SigningGetTaskAllowPreference: Equatable, Hashable {

    /// The caller did not state a debugging preference, so nothing is compared.
    case unspecified

    /// The caller intends the claim to carry this value.
    case requested(Bool)
}

/// How the requested configuration states `get-task-allow` once the typed
/// preference and the claim dictionary are read together.
enum RequestedGetTaskAllowClaim: Equatable, Hashable {

    /// No preference was stated and no claim was requested.
    case notRequested

    /// Exactly one source requested the value, or both sources agreed on it.
    case requested(Bool)

    /// The typed preference and the claim dictionary disagree. ZynSign does not
    /// choose between two contradictory requests.
    case contradictory

    /// A `get-task-allow` claim was requested with a value that is not a
    /// boolean, so the comparison rules for it cannot be applied.
    case notComparable
}

/// What a caller intends to sign with.
///
/// A signing configuration is a request, not an authorization: it states which
/// entitlement claims the caller wants the signed application to make, which
/// profile class the caller intends to use, and (optionally) the debugging
/// preference. Pointing a configuration at a profile or an identity does not
/// make either one valid, and this type performs no signing.
struct SigningConfiguration: Equatable, Hashable {

    /// The entitlement claims the caller intends the application to make.
    ///
    /// `nil` means the claim set was not established, which is not the same as
    /// an empty claim set: an empty dictionary means the caller intends to sign
    /// with no additional claims, while `nil` means the question was not
    /// answered and the entitlement comparison cannot be performed.
    let entitlements: ProvisioningProfileEntitlements?

    /// The debugging preference.
    let getTaskAllow: SigningGetTaskAllowPreference

    /// The profile class the caller intends to use, when one is established.
    let intendedProfileClass: ProvisioningProfileClassification?

    init(
        entitlements: ProvisioningProfileEntitlements? = nil,
        getTaskAllow: SigningGetTaskAllowPreference = .unspecified,
        intendedProfileClass: ProvisioningProfileClassification? = nil
    ) {
        self.entitlements = entitlements
        self.getTaskAllow = getTaskAllow
        self.intendedProfileClass = intendedProfileClass
    }

    /// A configuration that states nothing.
    static let unspecified = SigningConfiguration()

    /// The debugging claim the two possible sources describe together.
    var requestedGetTaskAllowClaim: RequestedGetTaskAllowClaim {
        let claim = entitlements?[ProvisioningProfileEntitlementKeys.getTaskAllow]
        switch getTaskAllow {
        case .unspecified:
            switch claim {
            case .none:
                return .notRequested
            case .some(.boolean(let value)):
                return .requested(value)
            case .some(_):
                return .notComparable
            }
        case .requested(let preferred):
            switch claim {
            case .none:
                return .requested(preferred)
            case .some(.boolean(let value)):
                return value == preferred ? .requested(preferred) : .contradictory
            case .some(_):
                return .notComparable
            }
        }
    }
}

/// The signing identity a policy evaluation may use.
///
/// The identity is represented by `SigningIdentityMetadata` and by the reason
/// it is absent. No case carries private-key bytes, a key reference, a Keychain
/// record, or a credential: the policy layer never asks for a signing
/// capability and never receives one. "Not provided", "none available", and
/// "the store could not be read" are three different answers and stay
/// distinguishable, so an absent identity can never be reported as a
/// certificate mismatch and a profile can never be reported as malformed
/// because ZynSign could not reach a key store.
enum ProvisioningPolicySigningIdentity: Equatable, Hashable {

    /// No identity was supplied, so the identity questions were not asked.
    case notProvided

    /// An identity store was consulted and listed no identity.
    case noneAvailable

    /// An identity store was consulted and could not be read.
    case lookupFailed

    /// Safe identity metadata, including key availability and capability state
    /// as observed. Availability is a report about a capability, not proof of a
    /// successful signature, certificate validity, or trust.
    case identity(SigningIdentityMetadata)

    /// The metadata, when an identity was supplied.
    var metadata: SigningIdentityMetadata? {
        if case .identity(let metadata) = self { return metadata }
        return nil
    }

    /// Whether the evaluation had an identity to compare against.
    var isProvided: Bool { metadata != nil }
}

/// What ZynSign knows about the device an evaluation concerns.
///
/// ZynSign does not fabricate a device identifier and does not read one from
/// the platform on this path: whether a trustworthy local device identifier can
/// be obtained at all is an open question in the feasibility record, and it is
/// deferred to installation-time evidence. A caller that legitimately holds an
/// identifier supplies it here; every other caller reports unavailability, and
/// the device rule then reports that the question is deferred instead of
/// assuming the running device is authorized because the profile lists devices.
enum ProvisioningDeviceContext: Equatable, Hashable {

    /// No trustworthy device identity is available to ZynSign.
    case unavailable

    /// The exact identifier a trustworthy source reported.
    case identified(ProvisionedDeviceIdentifier)

    /// The exact identifier, when one was reported.
    var identifier: ProvisionedDeviceIdentifier? {
        if case .identified(let identifier) = self { return identifier }
        return nil
    }
}

/// The platforms an application is intended to run on, as far as ZynSign can
/// establish them.
///
/// The declared device families of an application's metadata (`UIDeviceFamily`)
/// are the platform evidence ZynSign's application model already has. The
/// mapping from a declared family to the platform spelling a profile uses is
/// **inferred** from the family values the platform documents; it is not a
/// verified statement of Apple policy, and a family ZynSign does not recognise
/// establishes nothing.
enum ProvisioningPolicyPlatformScope: Equatable, Hashable {

    /// No platform the evaluator can compare against was established.
    case notEstablished

    /// The platforms the application is intended for.
    case established([ProvisioningProfilePlatform])

    /// The platforms, when established.
    var platforms: [ProvisioningProfilePlatform]? {
        if case .established(let platforms) = self { return platforms }
        return nil
    }

    /// Derives the intended platform set from an application's declared device
    /// families. An empty or wholly unrecognised declaration establishes
    /// nothing.
    static func from(deviceFamilies: [ApplicationDeviceFamily]) -> ProvisioningPolicyPlatformScope {
        var platforms: [ProvisioningProfilePlatform] = []
        for family in deviceFamilies {
            let platform: ProvisioningProfilePlatform
            switch family {
            case .phone, .pad: platform = .iPhoneOS
            case .tv: platform = .tvOS
            case .watch: platform = .watchOS
            case .visionOS: platform = .visionOS
            case .unknown: continue
            }
            if !platforms.contains(platform) {
                platforms.append(platform)
            }
        }
        return platforms.isEmpty ? .notEstablished : .established(platforms)
    }
}

/// The facts one provisioning-policy evaluation may see.
///
/// The context is the whole input of `ProvisioningPolicyValidator`. It is a
/// pure domain value assembled by the application layer from data that already
/// exists:
///
///     Application metadata and bundle identifier
///             +
///     Authenticated provisioning profile
///             +
///     Signing identity metadata
///             +
///     Requested signing configuration and device/platform context
///             ↓
///     ProvisioningPolicyValidationContext
///
/// What the context deliberately does not carry:
///
/// - no private-key bytes, key references, Keychain records, passwords, or
///   PKCS#12 material of any kind. An identity arrives as
///   `SigningIdentityMetadata` plus a reported capability state;
/// - no platform objects, no `SecKey`, no `SecCertificate`, no file handle, and
///   no raw profile or certificate bytes;
/// - no interface or presentation state. A view model is not an input to the
///   policy layer.
struct ProvisioningPolicyValidationContext: Equatable, Hashable {

    /// The parsed profile, when the pipeline produced one.
    let profile: ProvisioningProfile?

    /// The authenticity state established for the profile's payload by the CMS
    /// boundary. Policy rules are applied only to an authenticated payload.
    let profileAuthenticity: ProvisioningProfileAuthenticityStatus

    /// The certificate relationships the CMS boundary established. Reused
    /// rather than recomputed: policy evaluation does not re-verify a container.
    let certificateRelationship: ProvisioningProfileCertificateRelationship

    /// What the application declares about itself, when it is known.
    let applicationMetadata: ApplicationMetadata?

    /// The bundle identifier actually being signed, when it differs from the
    /// identifier the application's metadata declares, for example for a nested
    /// bundle that carries its own identifier.
    let bundleIdentifier: BundleIdentifier?

    /// The signing identity, or the reason it is unavailable.
    let signingIdentity: ProvisioningPolicySigningIdentity

    /// What the caller intends to sign with.
    let signingConfiguration: SigningConfiguration

    /// What is known about the device this evaluation concerns.
    let deviceContext: ProvisioningDeviceContext

    /// The platforms the application is intended for, when the caller
    /// established them explicitly. When this is `nil`, the application's
    /// declared device families are used instead.
    let intendedPlatforms: [ProvisioningProfilePlatform]?

    init(
        profile: ProvisioningProfile? = nil,
        profileAuthenticity: ProvisioningProfileAuthenticityStatus = .notEvaluated,
        certificateRelationship: ProvisioningProfileCertificateRelationship = ProvisioningProfileCertificateRelationship(
            signerCertificateStatus: .notSought
        ),
        applicationMetadata: ApplicationMetadata? = nil,
        bundleIdentifier: BundleIdentifier? = nil,
        signingIdentity: ProvisioningPolicySigningIdentity = .notProvided,
        signingConfiguration: SigningConfiguration = SigningConfiguration(),
        deviceContext: ProvisioningDeviceContext = .unavailable,
        intendedPlatforms: [ProvisioningProfilePlatform]? = nil
    ) {
        self.profile = profile
        self.profileAuthenticity = profileAuthenticity
        self.certificateRelationship = certificateRelationship
        self.applicationMetadata = applicationMetadata
        self.bundleIdentifier = bundleIdentifier
        self.signingIdentity = signingIdentity
        self.signingConfiguration = signingConfiguration
        self.deviceContext = deviceContext
        self.intendedPlatforms = intendedPlatforms
    }

    /// The bundle identifier the bundle-identifier rule compares: the explicit
    /// value when the caller supplied one, otherwise the identifier the
    /// application's own metadata declares.
    var resolvedBundleIdentifier: BundleIdentifier? {
        bundleIdentifier ?? applicationMetadata?.identity.bundleIdentifier
    }

    /// The platform scope the platform rule compares: an explicit caller
    /// statement wins, and the application's declared device families are the
    /// fallback.
    var resolvedPlatformScope: ProvisioningPolicyPlatformScope {
        if let intendedPlatforms, !intendedPlatforms.isEmpty {
            return .established(intendedPlatforms)
        }
        guard let deviceFamily = applicationMetadata?.deviceFamily else { return .notEstablished }
        return ProvisioningPolicyPlatformScope.from(deviceFamilies: deviceFamily)
    }
}
