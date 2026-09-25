import Foundation

/// A reusable signing configuration.
///
/// Users typically want to sign several apps with the same identity and
/// preferences. `SigningPreset` captures that bundle so it can be invoked
/// with one tap rather than re-selected every time. Presets are pure
/// values: they reference an identity by SHA-256 fingerprint and a
/// provisioning profile by file name, and they record the signing options
/// chosen. They never hold bytes, keys, or URLs — those live in the
/// Keychain and the user's file storage respectively.
struct SigningPreset: Equatable, Hashable, Identifiable, Sendable, Codable {

    /// A stable, opaque identifier (UUID). Distinct from the name, which
    /// is user-editable and therefore non-stable.
    let id: PresetIdentifier

    /// The user-given name. Unique within a user's store, but never
    /// authoritative for identity.
    var name: String

    /// The certificate to use, identified by its SHA-256 fingerprint.
    /// Optional because a freshly-created preset may be saved before a
    /// certificate is chosen; the assessment UI surfaces this state.
    var certificateFingerprint: CertificateFingerprint?

    /// The provisioning profile to use, identified by its profile name as
    /// declared in the profile's `Name` key. Optional for the same reason
    /// as the certificate.
    var provisioningProfileName: String?

    /// The DER entitlements slot preference — slot 5 (legacy) or slot 5+7
    /// (modern). Defaults to modern.
    var entitlementsSlot: EntitlementsSlot

    /// Optional saved bundle-identifier override; used when the user wants
    /// to re-sign with a different bundle identifier than the original.
    var bundleIdentifierOverride: String?

    /// Optional saved display-name override; same use case as the bundle
    /// identifier.
    var displayNameOverride: String?

    /// When the preset was created.
    let createdAt: Date

    /// When the preset was last edited.
    var updatedAt: Date

    /// Records a preset from its stored parts. Used both when a preset is
    /// first saved and when it is rehydrated from disk.
    init(
        id: PresetIdentifier = PresetIdentifier(),
        name: String,
        certificateFingerprint: String? = nil,
        provisioningProfileName: String? = nil,
        entitlementsSlot: EntitlementsSlot = .modern,
        bundleIdentifierOverride: String? = nil,
        displayNameOverride: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.certificateFingerprint = certificateFingerprint
        self.provisioningProfileName = provisioningProfileName
        self.entitlementsSlot = entitlementsSlot
        self.bundleIdentifierOverride = bundleIdentifierOverride
        self.displayNameOverride = displayNameOverride
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Which DER entitlements slot layout to use.
    enum EntitlementsSlot: String, Equatable, Hashable, CaseIterable, Sendable, Codable {
        case legacy   // 0x20200 (slot 5)
        case modern   // 0x20400 (slot 5+7)

        var displayName: String {
            switch self {
            case .legacy: return "DER 0x20200 (slot 5)"
            case .modern: return "DER 0x20400 (slot 5 + 7)"
            }
        }
    }

    /// Whether this preset has enough information to actually sign with.
    /// A preset missing a certificate or a provisioning profile is a draft.
    var isComplete: Bool {
        certificateFingerprint != nil && provisioningProfileName != nil
    }

    /// The canonical sort key — most recently used first, then by name.
    static func sortByRecencyThenName(_ lhs: SigningPreset, _ rhs: SigningPreset) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

/// A preset identifier — opaque and stable across launches.
struct PresetIdentifier: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String
    init() { self.rawValue = UUID().uuidString }
    init(rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}
