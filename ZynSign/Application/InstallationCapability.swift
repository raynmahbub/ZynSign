import Foundation

/// The evidence the installation assessment reads.
///
/// Every field is established elsewhere and passed in: the staged pipeline's
/// status, whether the target device is authorized, and whether the platform
/// is supported. Nothing here is inferred, and a missing fact stays missing
/// rather than defaulting in either direction.
struct InstallationEvidence: Equatable {

    /// The integrated provisioning-pipeline status for the artifact.
    let profileStatus: ProvisioningProfilePipelineStatus

    /// Whether the target device is authorized for the artifact, or `nil`
    /// when no trustworthy device evidence was supplied.
    let deviceAuthorized: Bool?

    /// Whether the target platform accepts the artifact's requirements, or
    /// `nil` when platform support was not established.
    let platformSupported: Bool?

    init(
        profileStatus: ProvisioningProfilePipelineStatus,
        deviceAuthorized: Bool? = nil,
        platformSupported: Bool? = nil
    ) {
        self.profileStatus = profileStatus
        self.deviceAuthorized = deviceAuthorized
        self.platformSupported = platformSupported
    }
}

/// One reason installation of an artifact is not established.
///
/// Limitations are stable, redacted facts for presentation and diagnostics.
/// They carry no identifiers, no profile content, and no device data.
enum InstallationLimitation: String, Hashable, CaseIterable {

    /// No supported mechanism can deliver the package from ZynSign to a
    /// device. This limitation is always present: no public
    /// application-facing installation API exists on the platform.
    case noDeliveryMechanism

    /// The provisioning pipeline did not reach a fully established result
    /// for the artifact, identity, and configuration.
    case profileNotCompatible

    /// No trustworthy device evidence was supplied, so authorization of the
    /// target device is unknown.
    case deviceAuthorizationUnknown

    /// The target device is not authorized for the artifact.
    case deviceNotAuthorized

    /// Platform support for the artifact was not established.
    case platformSupportUnknown

    /// The target platform does not support the artifact.
    case platformUnsupported

    /// One honest sentence for presentation. Fixed text, free of detail.
    var message: String {
        switch self {
        case .noDeliveryMechanism:
            return "No supported installation mechanism is available."
        case .profileNotCompatible:
            return "The provisioning profile is not established as compatible."
        case .deviceAuthorizationUnknown:
            return "Target-device authorization is unknown."
        case .deviceNotAuthorized:
            return "The target device is not authorized."
        case .platformSupportUnknown:
            return "Platform support is unknown."
        case .platformUnsupported:
            return "The target platform is not supported."
        }
    }
}

/// What assessment established about installing one artifact.
///
/// `supported` answers one question: may ZynSign proceed to install this
/// artifact? It is `false` on every path today, because no supported
/// delivery mechanism exists on the platform — the gate is a platform fact,
/// not a verdict about any artifact. Extending this type with a supported
/// outcome requires a demonstrated mechanism; until then the limitations
/// explain exactly what is missing, in deterministic order.
struct InstallationAssessment: Equatable {

    /// Whether installation may proceed. Always `false` until a supported
    /// delivery mechanism is demonstrated and composed here.
    let supported: Bool

    /// What stands between the artifact and installation, in deterministic
    /// order. Empty exactly when installation is supported; otherwise the
    /// absent mechanism is always reported first.
    let limitations: [InstallationLimitation]

    /// One presentation-safe sentence summarizing the assessment. Fixed
    /// text, free of identifiers and detail.
    let summary: String
}

/// Assesses whether one artifact can be installed, and says why not.
///
/// The assessment is pure: it reads `InstallationEvidence` and applies the
/// platform fact that no in-app delivery mechanism exists. It performs no
/// installation, requests no authorization, persists nothing, and never
/// reports an artifact as installable on ZynSign's own authority.
enum InstallationCapabilityAssessment {

    /// Whether a supported delivery mechanism is available to ZynSign.
    /// Always `false`: no public application-facing installation API
    /// exists on iOS or iPadOS, and no managed-device, over-the-air, or
    /// host-based mechanism is composed into the product. This constant is
    /// the single gate a future mechanism must open, with its own
    /// feasibility evidence, before any assessment can report support.
    private static let deliveryMechanismAvailable = false

    /// Assesses installation for one artifact's evidence.
    static func assess(_ evidence: InstallationEvidence) -> InstallationAssessment {
        var limitations: [InstallationLimitation] = []
        if !deliveryMechanismAvailable {
            limitations.append(.noDeliveryMechanism)
        }
        if !evidence.profileStatus.isFullyEstablished {
            limitations.append(.profileNotCompatible)
        }
        switch evidence.deviceAuthorized {
        case .none:
            limitations.append(.deviceAuthorizationUnknown)
        case .some(true):
            break
        case .some(false):
            limitations.append(.deviceNotAuthorized)
        }
        switch evidence.platformSupported {
        case .none:
            limitations.append(.platformSupportUnknown)
        case .some(true):
            break
        case .some(false):
            limitations.append(.platformUnsupported)
        }
        let supported = deliveryMechanismAvailable && limitations.isEmpty
        let summary: String
        if supported {
            summary = "Installation is available."
        } else if let first = limitations.first {
            summary = "Installation is not available: \(first.message)"
        } else {
            summary = "Installation is not available."
        }
        return InstallationAssessment(
            supported: supported,
            limitations: limitations,
            summary: summary
        )
    }
}
