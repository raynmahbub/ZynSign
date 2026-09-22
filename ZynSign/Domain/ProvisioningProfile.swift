import Foundation

/// A platform identifier declared by a provisioning profile.
///
/// Known spellings are named for presentation, while an unknown spelling is
/// retained exactly. This is observation of profile data, not a statement that
/// the current device supports or authorizes the platform.
enum ProvisioningProfilePlatform: Equatable, Hashable {

    case iPhoneOS
    case macOS
    case tvOS
    case watchOS
    case visionOS
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "iPhoneOS": self = .iPhoneOS
        case "MacOSX", "macOS": self = .macOS
        case "AppleTVOS", "tvOS": self = .tvOS
        case "WatchOS", "watchOS": self = .watchOS
        case "XROS", "visionOS": self = .visionOS
        default: self = .unknown(rawValue)
        }
    }

    /// The exact value observed in the profile.
    var rawValue: String {
        switch self {
        case .iPhoneOS: return "iPhoneOS"
        case .macOS: return "macOS"
        case .tvOS: return "tvOS"
        case .watchOS: return "watchOS"
        case .visionOS: return "visionOS"
        case .unknown(let value): return value
        }
    }
}

/// The component of an application identifier after a known prefix.
///
/// Exact components reuse the existing `BundleIdentifier` value object. A
/// trailing wildcard is represented separately because `*` is not a valid
/// application bundle identifier character and must not be coerced into one.
enum ProvisioningApplicationIdentifierComponent: Equatable, Hashable {

    case exact(BundleIdentifier)
    case wildcard(prefix: String)

    /// The exact component text, including a trailing wildcard when present.
    var rawValue: String {
        switch self {
        case .exact(let identifier): return identifier.rawValue
        case .wildcard(let prefix): return prefix + "*"
        }
    }

    /// The exact bundle identifier when the component is not a wildcard.
    var bundleIdentifier: BundleIdentifier? {
        if case .exact(let identifier) = self { return identifier }
        return nil
    }

    /// Whether the component is a wildcard pattern.
    var isWildcard: Bool {
        if case .wildcard = self { return true }
        return false
    }
}

/// An application identifier as declared by the profile.
///
/// `fullValue` is always retained exactly. A bundle component is derived only
/// when an explicit application-identifier prefix is available and the full
/// value has that prefix followed by a single delimiter. When the prefix is
/// absent, ZynSign deliberately does not split on the first period or invent
/// a bundle identifier.
struct ProvisioningApplicationIdentifier: Equatable, Hashable {

    /// The full application identifier value.
    let fullValue: String

    /// The explicit prefix used to derive the component, when present.
    let applicationIdentifierPrefix: String?

    /// The exact or wildcard component derived with the explicit prefix.
    let bundleIdentifierComponent: ProvisioningApplicationIdentifierComponent?

    /// Creates an application identifier with conservative, contextual
    /// parsing. The initializer throws a controlled error rather than
    /// guessing at delimiter structure.
    init(fullValue: String, applicationIdentifierPrefix: String?) throws {
        guard Self.isSafeIdentifierText(fullValue) else {
            throw ZynSignError.invalidProvisioningProfileIdentifier(
                diagnosticDetail: "The full application identifier is empty, oversized, or contains a control character."
            )
        }

        if let applicationIdentifierPrefix {
            guard Self.isSafeIdentifierText(applicationIdentifierPrefix),
                  !applicationIdentifierPrefix.contains("*") else {
                throw ZynSignError.invalidProvisioningProfileIdentifier(
                    diagnosticDetail: "The application identifier prefix is not a valid non-wildcard component."
                )
            }
            let boundary = applicationIdentifierPrefix + "."
            guard fullValue.hasPrefix(boundary) else {
                throw ZynSignError.invalidProvisioningProfileIdentifier(
                    diagnosticDetail: "The full application identifier does not contain the declared prefix boundary."
                )
            }
            let componentText = String(fullValue.dropFirst(boundary.count))
            guard let component = Self.parseComponent(componentText) else {
                throw ZynSignError.invalidProvisioningProfileIdentifier(
                    diagnosticDetail: "The bundle identifier component is not a supported exact or trailing-wildcard value."
                )
            }
            self.bundleIdentifierComponent = component
        } else {
            self.bundleIdentifierComponent = nil
        }

        self.fullValue = fullValue
        self.applicationIdentifierPrefix = applicationIdentifierPrefix
    }

    /// The exact bundle identifier when the application identifier carries an
    /// explicit, non-wildcard component.
    var bundleIdentifier: BundleIdentifier? {
        bundleIdentifierComponent?.bundleIdentifier
    }

    private static func parseComponent(
        _ component: String
    ) -> ProvisioningApplicationIdentifierComponent? {
        guard !component.isEmpty, !component.contains(where: { $0.isControl }) else {
            return nil
        }
        if component == "*" {
            return .wildcard(prefix: "")
        }
        guard component.firstIndex(of: "*") == component.index(before: component.endIndex),
              component.filter({ $0 == "*" }).count == 1 else {
            return BundleIdentifier(rawValue: component).map(ProvisioningApplicationIdentifierComponent.exact)
        }
        let prefixWithDelimiter = String(component.dropLast())
        guard prefixWithDelimiter.hasSuffix(".") else { return nil }
        let prefix = String(prefixWithDelimiter.dropLast())
        guard BundleIdentifier(rawValue: prefix) != nil else { return nil }
        return .wildcard(prefix: prefixWithDelimiter)
    }

    private static func isSafeIdentifierText(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return !value.contains(where: { $0.isControl || $0.isWhitespace })
    }
}

/// One exact, unnormalised device identifier from `ProvisionedDevices`.
///
/// The parser applies only a conservative hexadecimal syntax and length bound;
/// it does not uppercase, lowercase, trim, hash, compare, install, or match
/// the value against a device. A parsed value is not proof of authorization.
struct ProvisionedDeviceIdentifier: Equatable, Hashable {

    /// The exact identifier text from the profile.
    let rawValue: String

    /// The policy ceiling for a device identifier's UTF-8 length.
    static let maximumLength = 128

    init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= Self.maximumLength,
              rawValue.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// A developer certificate entry from the profile's property-list view.
///
/// The profile may carry full certificate bytes. They remain untrusted public
/// data and are not logged or persisted by this pipeline. When a
/// `CertificateParser` is supplied, the existing certificate metadata model
/// is attached; that metadata still says nothing about private-key possession,
/// trust, or signing authorization.
struct ProvisioningProfileCertificateReference: Equatable, Hashable {

    /// The exact certificate bytes as carried by the profile.
    let certificateData: Data

    /// Parsed certificate metadata, when a certificate parser was supplied.
    let metadata: CertificateMetadata?

    init(certificateData: Data, metadata: CertificateMetadata? = nil) {
        self.certificateData = certificateData
        self.metadata = metadata
    }

    /// The certificate fingerprint when metadata was attached.
    var fingerprint: CertificateFingerprint? { metadata?.sha256Fingerprint }
}

/// A conservative classification derived from multiple profile fields.
///
/// `unknown` is the correct result when evidence conflicts or is insufficient;
/// classification never establishes CMS authenticity or platform acceptance.
enum ProvisioningProfileClassification: String, CaseIterable, Equatable, Hashable {

    case development
    case adHoc
    case appStore
    case enterprise
    case unknown
}

/// The typed profile metadata extracted from a decoded property-list payload.
///
/// Optional fields are intentional: profile variants and the property-list
/// view have changed over time. A non-nil value means that the corresponding
/// field was present and structurally represented, not that it was trusted or
/// authorized. Required-field and cross-field checks are performed by
/// `ProvisioningProfileValidator`.
struct ProvisioningProfile: Equatable, Hashable {

    let uuid: UUID?
    let profileName: String?
    let creationDate: Date?
    let expirationDate: Date?
    let platforms: [ProvisioningProfilePlatform]?
    let applicationIdentifier: ProvisioningApplicationIdentifier?
    let applicationIdentifierPrefixes: [String]?
    let teamIdentifiers: [String]?
    let entitlementTeamIdentifier: String?
    let entitlements: ProvisioningProfileEntitlements?
    let provisionedDevices: [ProvisionedDeviceIdentifier]?
    let developerCertificates: [ProvisioningProfileCertificateReference]?
    let getTaskAllow: Bool?
    let betaReportsActive: Bool?
    let provisionsAllDevices: Bool?
    let version: Int64?
    let isXcodeManaged: Bool?

    init(
        uuid: UUID? = nil,
        profileName: String? = nil,
        creationDate: Date? = nil,
        expirationDate: Date? = nil,
        platforms: [ProvisioningProfilePlatform]? = nil,
        applicationIdentifier: ProvisioningApplicationIdentifier? = nil,
        applicationIdentifierPrefixes: [String]? = nil,
        teamIdentifiers: [String]? = nil,
        entitlementTeamIdentifier: String? = nil,
        entitlements: ProvisioningProfileEntitlements? = nil,
        provisionedDevices: [ProvisionedDeviceIdentifier]? = nil,
        developerCertificates: [ProvisioningProfileCertificateReference]? = nil,
        getTaskAllow: Bool? = nil,
        betaReportsActive: Bool? = nil,
        provisionsAllDevices: Bool? = nil,
        version: Int64? = nil,
        isXcodeManaged: Bool? = nil
    ) {
        self.uuid = uuid
        self.profileName = profileName
        self.creationDate = creationDate
        self.expirationDate = expirationDate
        self.platforms = platforms
        self.applicationIdentifier = applicationIdentifier
        self.applicationIdentifierPrefixes = applicationIdentifierPrefixes
        self.teamIdentifiers = teamIdentifiers
        self.entitlementTeamIdentifier = entitlementTeamIdentifier
        self.entitlements = entitlements
        self.provisionedDevices = provisionedDevices
        self.developerCertificates = developerCertificates
        self.getTaskAllow = getTaskAllow
        self.betaReportsActive = betaReportsActive
        self.provisionsAllDevices = provisionsAllDevices
        self.version = version
        self.isXcodeManaged = isXcodeManaged
    }

    /// The first explicit application-identifier prefix, when present.
    var applicationIdentifierPrefix: String? { applicationIdentifierPrefixes?.first }

    /// The first root team identifier, falling back to the entitlement's team
    /// identifier only as an observed convenience, not as an authorization
    /// decision.
    var teamIdentifier: String? {
        teamIdentifiers?.first ?? entitlementTeamIdentifier
    }

    /// The exact bundle identifier for an exact application-id component.
    var bundleIdentifier: BundleIdentifier? {
        applicationIdentifier?.bundleIdentifier
    }

    /// The device identifiers under the longer descriptive name used by
    /// later device-policy code.
    var provisionedDeviceIdentifiers: [ProvisionedDeviceIdentifier]? {
        provisionedDevices
    }

    /// The certificate references under the longer descriptive name used by
    /// later identity-policy code.
    var developerCertificateReferences: [ProvisioningProfileCertificateReference]? {
        developerCertificates
    }

    /// A safe classification from the observed field combination.
    var classification: ProvisioningProfileClassification {
        Self.classify(
            getTaskAllow: getTaskAllow,
            betaReportsActive: betaReportsActive,
            provisionedDevices: provisionedDevices,
            provisionsAllDevices: provisionsAllDevices,
            developerCertificates: developerCertificates
        )
    }

    /// Alias used by callers that speak in terms of profile type.
    var profileType: ProvisioningProfileClassification { classification }

    private static func classify(
        getTaskAllow: Bool?,
        betaReportsActive: Bool?,
        provisionedDevices: [ProvisionedDeviceIdentifier]?,
        provisionsAllDevices: Bool?,
        developerCertificates: [ProvisioningProfileCertificateReference]?
    ) -> ProvisioningProfileClassification {
        let hasDevices = provisionedDevices?.isEmpty == false
        let hasCertificates = developerCertificates?.isEmpty == false
        let allDevices = provisionsAllDevices == true

        if allDevices {
            guard getTaskAllow == false, !hasDevices else { return .unknown }
            return .enterprise
        }
        if hasDevices {
            guard let getTaskAllow else { return .unknown }
            return getTaskAllow ? (hasCertificates ? .development : .unknown) : .adHoc
        }
        if betaReportsActive == true, getTaskAllow == false {
            return .appStore
        }
        return .unknown
    }
}
