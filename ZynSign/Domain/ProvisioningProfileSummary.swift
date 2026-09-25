import Foundation

/// A summary of a `.mobileprovision` file the user has imported.
///
/// ZynSign keeps a small library of provisioning profiles so the user
/// can pick one for a signing operation without re-importing the file
/// each time. The summary holds the profile's own declarations — name,
/// team identifier, expiration, allowed bundle identifiers, devices —
/// and never any sensitive material. The profile bytes themselves live
/// in the user's file storage, referenced by file name.
struct ProvisioningProfileSummary: Equatable, Hashable, Identifiable, Sendable, Codable {

    /// Stable identifier.
    let id: ProvisioningProfileIdentifier

    /// The profile's declared `Name`.
    let name: String

    /// The profile's team identifier (`TeamIdentifier.*` from the
    /// profile's plist).
    let teamIdentifier: String?

    /// A display-only rendering of the parsed `application-identifier` App ID
    /// scope. Actual signing always checks the authenticated stored bytes;
    /// this summary is not authorization evidence.
    let bundleIdentifierPatterns: [String]

    /// The profile's expiration date.
    let expirationDate: Date

    /// The profile's declared capabilities (entitlements keys).
    let entitlementsKeys: [String]

    /// Whether the profile allows debug or release builds. A profile
    /// marked `get-task-allow` is for debug.
    let allowsDebug: Bool

    /// The location of the original `.mobileprovision` file the user
    /// imported, relative to the user's provisioning profile directory.
    /// The file's content is held there unchanged.
    let sourceFileName: String

    /// When the profile was imported into the summary library.
    let importedAt: Date

    // MARK: - Recorded at import (added for the Provisioning Profile Manager)

    /// The profile's declared `UUID`, as text. Optional so catalogs written
    /// before this field existed keep decoding under the same schema.
    let uuid: String?

    /// The profile's declared `TeamName` — the human name behind the team
    /// identifier.
    let teamName: String?

    /// The profile's declared `CreationDate`.
    let creationDate: Date?

    /// The distribution type derived from the profile's own fields
    /// (Development / Ad Hoc / App Store / Enterprise / Unknown).
    let profileType: ProvisioningProfileClassification?

    /// How many devices the profile provisions, when it declares a device
    /// list. `nil` for profiles that name no devices (App Store profiles)
    /// or that provision all devices (Enterprise).
    let deviceCount: Int?

    /// The full `application-identifier` entitlement value, e.g.
    /// `TEAMID.com.example.app` — the profile's App ID.
    let applicationIdentifier: String?

    /// The explicit bundle identifier when the App ID is exact; `nil` for
    /// wildcard profiles (see `isWildcard`).
    let bundleIdentifier: String?

    /// SHA-256 fingerprints (lowercase hex) of the certificates the profile
    /// embeds, when they could be read. Empty or `nil` means "not recorded";
    /// Refresh Validation re-reads the stored file to fill them in.
    let certificateFingerprints: [String]?

    init(
        id: ProvisioningProfileIdentifier = ProvisioningProfileIdentifier(),
        name: String,
        teamIdentifier: String?,
        bundleIdentifierPatterns: [String],
        expirationDate: Date,
        entitlementsKeys: [String],
        allowsDebug: Bool,
        sourceFileName: String,
        importedAt: Date,
        uuid: String? = nil,
        teamName: String? = nil,
        creationDate: Date? = nil,
        profileType: ProvisioningProfileClassification? = nil,
        deviceCount: Int? = nil,
        applicationIdentifier: String? = nil,
        bundleIdentifier: String? = nil,
        certificateFingerprints: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifierPatterns = bundleIdentifierPatterns
        self.expirationDate = expirationDate
        self.entitlementsKeys = entitlementsKeys
        self.allowsDebug = allowsDebug
        self.sourceFileName = sourceFileName
        self.importedAt = importedAt
        self.uuid = uuid
        self.teamName = teamName
        self.creationDate = creationDate
        self.profileType = profileType
        self.deviceCount = deviceCount
        self.applicationIdentifier = applicationIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.certificateFingerprints = certificateFingerprints
    }

    /// The distribution type to display: `Unknown` for catalogs written
    /// before the type was recorded.
    var resolvedProfileType: ProvisioningProfileClassification {
        profileType ?? .unknown
    }

    /// Whether the profile's App ID is a wildcard pattern rather than an
    /// explicit bundle identifier.
    var isWildcard: Bool {
        if bundleIdentifier != nil { return false }
        if applicationIdentifier?.hasSuffix("*") == true { return true }
        return bundleIdentifierPatterns.contains { $0.hasSuffix("*") }
    }

    /// The certificate fingerprints to compare, normalised to lowercase
    /// hex; empty when none were recorded.
    var resolvedCertificateFingerprints: [String] {
        (certificateFingerprints ?? []).map { $0.lowercased() }
    }

    /// A user-presentable device description: the count when the profile
    /// names devices, "All devices" for enterprise profiles, or `nil` when
    /// the profile declares no device list (App Store profiles).
    var deviceCountDescription: String? {
        if let deviceCount { return "\(deviceCount)" }
        if resolvedProfileType == .enterprise { return "All devices" }
        return nil
    }

    /// Whether this profile is past its expiration date.
    func isExpired(referenceDate: Date = Date()) -> Bool {
        referenceDate >= expirationDate
    }

    /// Days remaining until expiration; negative when past.
    func daysUntilExpiration(referenceDate: Date = Date()) -> Int {
        let interval = expirationDate.timeIntervalSince(referenceDate)
        return Int((interval / 86400).rounded(.toNearestOrEven))
    }

    /// Whether this profile's declared bundle identifier patterns cover
    /// the given bundle identifier. Wildcard suffixes (`com.example.*`)
    /// are matched.
    func covers(bundleIdentifier: String) -> Bool {
        for pattern in bundleIdentifierPatterns {
            if matches(pattern: pattern, value: bundleIdentifier) { return true }
        }
        return false
    }

    private func matches(pattern: String, value: String) -> Bool {
        // A team-wide profile covers any nonempty bundle identifier.
        if pattern == "*" { return !value.isEmpty }
        if pattern.hasSuffix(".*") {
            // Keep the same component-boundary rule as the policy validator:
            // com.example.* does not also cover the exact com.example ID.
            return value.hasPrefix(String(pattern.dropLast()))
        }
        return pattern == value
    }

    /// Sort: soonest-to-expire first; expired profiles sink to the end.
    static func sortByExpiration(_ lhs: ProvisioningProfileSummary, _ rhs: ProvisioningProfileSummary) -> Bool {
        let lhsExpired = lhs.isExpired()
        let rhsExpired = rhs.isExpired()
        if lhsExpired != rhsExpired { return !lhsExpired }
        return lhs.expirationDate < rhs.expirationDate
    }
}

/// A provisioning profile identifier — opaque and stable.
struct ProvisioningProfileIdentifier: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String
    init() { self.rawValue = UUID().uuidString }
    init(rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}
