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

    /// The profile's bundle-identifier patterns (`Entitlements` →
    /// `com.apple.developer.entitlements` or `ProvisionedDevices` /
    /// `application-identifier` prefix).
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

    init(
        id: ProvisioningProfileIdentifier = ProvisioningProfileIdentifier(),
        name: String,
        teamIdentifier: String?,
        bundleIdentifierPatterns: [String],
        expirationDate: Date,
        entitlementsKeys: [String],
        allowsDebug: Bool,
        sourceFileName: String,
        importedAt: Date
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
        bundleIdentifierPatterns.contains { pattern in
            Self.pattern(pattern, covers: bundleIdentifier)
        }
    }

    /// Whether one declared pattern covers `bundleIdentifier`.
    ///
    /// A trailing `.*` covers the prefix itself and any single-or-deeper
    /// suffix (`com.example` and `com.example.app`). Anything else is an
    /// exact match. This is the same rule `covers(bundleIdentifier:)` uses,
    /// exposed so preset matching cannot drift from the profile summary.
    static func pattern(_ pattern: String, covers bundleIdentifier: String) -> Bool {
        if pattern.hasSuffix(".*") {
            let prefix = String(pattern.dropLast(2))
            return bundleIdentifier == prefix || bundleIdentifier.hasPrefix(prefix + ".")
        }
        return pattern == bundleIdentifier
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
