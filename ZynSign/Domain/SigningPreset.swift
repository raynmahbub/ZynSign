import Foundation

/// A reusable signing configuration.
///
/// Users typically want to sign several apps with the same identity and
/// preferences. `SigningPreset` captures that bundle so it can be offered
/// with one tap rather than re-selected every time. Presets are pure
/// values: they reference an identity by SHA-256 fingerprint and a
/// provisioning profile by identifier and name, and they record the signing
/// options chosen. They never hold bytes, keys, passwords, or URLs — those
/// live in the Keychain and the user's file storage respectively.
///
/// The model is the one later versions sync, share, schedule, and automate.
/// Those capabilities are represented by `PresetDistribution` so a future
/// release can fill them in without replacing the preset. This version
/// stores the fields and does not execute them.
struct SigningPreset: Equatable, Hashable, Identifiable, Sendable, Codable {

    /// Which starter the preset was created from. A label for the library,
    /// not a second configuration.
    enum Kind: String, Equatable, Hashable, CaseIterable, Sendable, Codable {
        case personalDevelopment
        case testingDevice
        case enterpriseWorkflow
        case custom

        var displayName: String {
            switch self {
            case .personalDevelopment: return "Personal Development"
            case .testingDevice: return "Testing Device"
            case .enterpriseWorkflow: return "Enterprise Workflow"
            case .custom: return "Custom Preset"
            }
        }
    }

    /// How prominently the interface leads with the verification summary.
    ///
    /// The signing pipeline always runs its verification stage. This
    /// preference never skips that stage; it only decides whether the
    /// summary is the first thing shown after a successful run.
    enum VerificationPreference: String, Equatable, Hashable, CaseIterable, Sendable, Codable {
        case always
        case recommended
        case available

        var displayName: String {
            switch self {
            case .always: return "Always show verification"
            case .recommended: return "Recommend verification"
            case .available: return "Verification available"
            }
        }

        var detail: String {
            switch self {
            case .always:
                return "The verification summary is shown first. The pipeline still verifies every run either way."
            case .recommended:
                return "ZynSign recommends reading the verification summary. The pipeline still verifies every run."
            case .available:
                return "The verification summary stays one tap away. The pipeline still verifies every run."
            }
        }
    }

    /// What to offer after a successful sign. None of these upload or install.
    enum ExportBehavior: String, Equatable, Hashable, CaseIterable, Sendable, Codable {
        case keepInSignedFolder
        case promptToShare
        case promptToDeliver

        var displayName: String {
            switch self {
            case .keepInSignedFolder: return "Keep in Signed"
            case .promptToShare: return "Offer to share"
            case .promptToDeliver: return "Offer to deliver"
            }
        }

        var detail: String {
            switch self {
            case .keepInSignedFolder:
                return "Leave the signed package in Documents/Signed."
            case .promptToShare:
                return "After signing, offer the system share sheet. Sharing still needs your confirmation."
            case .promptToDeliver:
                return "After signing, offer the delivery hand-off. ZynSign still does not install or upload."
            }
        }
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

        /// Whether the signing pipeline should emit the DER entitlements blob.
        var emitsDEREntitlements: Bool { self == .modern }
    }

    /// A stable, opaque identifier (UUID). Distinct from the name, which
    /// is user-editable and therefore non-stable.
    let id: PresetIdentifier

    /// The user-given name. Unique within a user's store, but never
    /// authoritative for identity.
    var name: String

    /// The starter this preset was created from.
    var kind: Kind

    /// The certificate to use, identified by its SHA-256 fingerprint.
    /// Optional because a freshly-created preset may be saved before a
    /// certificate is chosen; the assessment UI surfaces this state.
    var certificateFingerprint: CertificateFingerprint?

    /// The provisioning profile to use, identified by its profile name as
    /// declared in the profile's `Name` key. Optional for the same reason
    /// as the certificate. Kept alongside the identifier so a renamed file
    /// can still be recognised, and so catalogs written before identifiers
    /// were stored remain readable.
    var provisioningProfileName: String?

    /// The stable identifier of the preferred profile, when the library
    /// assigned one. A reference only — not the profile bytes.
    var provisioningProfileID: ProvisioningProfileIdentifier?

    /// The team identifier the preset prefers, copied from the profile or
    /// certificate the user chose. A reference, not a credential.
    var teamIdentifier: String?

    /// The DER entitlements slot preference. Defaults to modern.
    var entitlementsSlot: EntitlementsSlot

    /// Optional saved bundle-identifier override. Stored for a later signing
    /// option. The current pipeline does not apply it, and the interface
    /// says so rather than implying the identifier will change.
    var bundleIdentifierOverride: String?

    /// Optional saved display-name override. Same honesty rule as the
    /// bundle-identifier override.
    var displayNameOverride: String?

    /// How the interface presents verification. Never a way to skip it.
    var verificationPreference: VerificationPreference

    /// What to offer after a successful sign.
    var exportBehavior: ExportBehavior

    /// Whether this preset is the user's default. At most one preset in a
    /// store should be default; the workflow enforces that.
    var isDefault: Bool

    /// Lightweight usage counters. No output paths, no key material.
    var usage: PresetUsage

    /// Reserved distribution, schedule, and automation fields. This version
    /// stores them and does not sync, share, or run them.
    var distribution: PresetDistribution

    /// When the preset was created.
    let createdAt: Date

    /// When the preset was last edited.
    var updatedAt: Date

    /// Records a preset from its stored parts. Used both when a preset is
    /// first saved and when it is rehydrated from disk.
    init(
        id: PresetIdentifier = PresetIdentifier(),
        name: String,
        kind: Kind = .custom,
        certificateFingerprint: CertificateFingerprint? = nil,
        provisioningProfileName: String? = nil,
        provisioningProfileID: ProvisioningProfileIdentifier? = nil,
        teamIdentifier: String? = nil,
        entitlementsSlot: EntitlementsSlot = .modern,
        bundleIdentifierOverride: String? = nil,
        displayNameOverride: String? = nil,
        verificationPreference: VerificationPreference = .always,
        exportBehavior: ExportBehavior = .keepInSignedFolder,
        isDefault: Bool = false,
        usage: PresetUsage = .empty,
        distribution: PresetDistribution = .local,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.certificateFingerprint = certificateFingerprint
        self.provisioningProfileName = provisioningProfileName
        self.provisioningProfileID = provisioningProfileID
        self.teamIdentifier = Self.normalizedTeam(teamIdentifier)
        self.entitlementsSlot = entitlementsSlot
        self.bundleIdentifierOverride = bundleIdentifierOverride
        self.displayNameOverride = displayNameOverride
        self.verificationPreference = verificationPreference
        self.exportBehavior = exportBehavior
        self.isDefault = isDefault
        self.usage = usage
        self.distribution = distribution
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Whether this preset has enough references to attempt signing.
    /// A preset missing a certificate or a provisioning profile is a draft.
    /// Completeness is not compatibility: the certificate may be gone and
    /// the profile may be expired. Live compatibility answers that.
    var isComplete: Bool {
        certificateFingerprint != nil
            && (provisioningProfileName != nil || provisioningProfileID != nil)
    }

    /// The canonical sort key — most recently edited first, then by name.
    static func sortByRecencyThenName(_ lhs: SigningPreset, _ rhs: SigningPreset) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    /// Library order: the default first, then most recently used, then name.
    static func sortForLibrary(_ lhs: SigningPreset, _ rhs: SigningPreset) -> Bool {
        if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
        let lhsUsed = lhs.usage.lastUsedAt ?? lhs.updatedAt
        let rhsUsed = rhs.usage.lastUsedAt ?? rhs.updatedAt
        if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    /// A copy with edited content, the original identifier and creation
    /// date, and the original distribution scope. Revision increments so a
    /// future sync engine can tell edits apart. Schedule and automation
    /// labels are preserved, not cleared, so this version does not destroy
    /// fields it does not yet run.
    func edited(
        name: String,
        kind: Kind,
        certificateFingerprint: CertificateFingerprint?,
        provisioningProfileName: String?,
        provisioningProfileID: ProvisioningProfileIdentifier?,
        teamIdentifier: String?,
        entitlementsSlot: EntitlementsSlot,
        bundleIdentifierOverride: String?,
        displayNameOverride: String?,
        verificationPreference: VerificationPreference,
        exportBehavior: ExportBehavior,
        isDefault: Bool,
        at date: Date
    ) -> SigningPreset {
        SigningPreset(
            id: id,
            name: name,
            kind: kind,
            certificateFingerprint: certificateFingerprint,
            provisioningProfileName: provisioningProfileName,
            provisioningProfileID: provisioningProfileID,
            teamIdentifier: teamIdentifier,
            entitlementsSlot: entitlementsSlot,
            bundleIdentifierOverride: bundleIdentifierOverride,
            displayNameOverride: displayNameOverride,
            verificationPreference: verificationPreference,
            exportBehavior: exportBehavior,
            isDefault: isDefault,
            usage: usage,
            distribution: distribution.incrementedRevision(),
            createdAt: createdAt,
            updatedAt: date
        )
    }

    /// Applies one finished use. Cancelled runs update "last used" and do
    /// not count as failures.
    func recording(_ outcome: PresetUseOutcome) -> SigningPreset {
        var copy = self
        var usage = copy.usage
        usage.lastUsedAt = outcome.at
        switch outcome.result {
        case .succeeded:
            usage.successfulUses += 1
            usage.lastSuccessfulBundleIdentifier = outcome.bundleIdentifier
            usage.lastSuccessfulDisplayName = outcome.displayName
        case .failed:
            usage.failedUses += 1
        case .cancelled:
            break
        }
        copy.usage = usage
        copy.updatedAt = outcome.at
        copy.distribution = copy.distribution.incrementedRevision()
        return copy
    }

    /// Normalises a team identifier for comparison. Empty becomes nil.
    static func normalizedTeam(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.uppercased()
    }

    // MARK: - Codable

    /// Decodes catalogs written before the workflow fields existed. Missing
    /// keys become the same defaults a new preset uses, so a version-1
    /// catalog remains readable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.decodeIdentifier(from: container)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .custom
        certificateFingerprint = Self.decodeFingerprint(from: container)
        provisioningProfileName = try container.decodeIfPresent(String.self, forKey: .provisioningProfileName)
        provisioningProfileID = try container.decodeIfPresent(ProvisioningProfileIdentifier.self, forKey: .provisioningProfileID)
        teamIdentifier = Self.normalizedTeam(try container.decodeIfPresent(String.self, forKey: .teamIdentifier))
        entitlementsSlot = try container.decodeIfPresent(EntitlementsSlot.self, forKey: .entitlementsSlot) ?? .modern
        bundleIdentifierOverride = try container.decodeIfPresent(String.self, forKey: .bundleIdentifierOverride)
        displayNameOverride = try container.decodeIfPresent(String.self, forKey: .displayNameOverride)
        verificationPreference = try container.decodeIfPresent(VerificationPreference.self, forKey: .verificationPreference) ?? .always
        exportBehavior = try container.decodeIfPresent(ExportBehavior.self, forKey: .exportBehavior) ?? .keepInSignedFolder
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        usage = try container.decodeIfPresent(PresetUsage.self, forKey: .usage) ?? .empty
        distribution = try container.decodeIfPresent(PresetDistribution.self, forKey: .distribution) ?? .local
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        if let certificateFingerprint {
            try container.encode(
                FingerprintWire(algorithm: certificateFingerprint.algorithm.rawValue, hexDigest: certificateFingerprint.hexDigest),
                forKey: .certificateFingerprint
            )
        }
        try container.encodeIfPresent(provisioningProfileName, forKey: .provisioningProfileName)
        try container.encodeIfPresent(provisioningProfileID, forKey: .provisioningProfileID)
        try container.encodeIfPresent(teamIdentifier, forKey: .teamIdentifier)
        try container.encode(entitlementsSlot, forKey: .entitlementsSlot)
        try container.encodeIfPresent(bundleIdentifierOverride, forKey: .bundleIdentifierOverride)
        try container.encodeIfPresent(displayNameOverride, forKey: .displayNameOverride)
        try container.encode(verificationPreference, forKey: .verificationPreference)
        try container.encode(exportBehavior, forKey: .exportBehavior)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encode(usage, forKey: .usage)
        try container.encode(distribution, forKey: .distribution)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case certificateFingerprint
        case provisioningProfileName
        case provisioningProfileID
        case teamIdentifier
        case entitlementsSlot
        case bundleIdentifierOverride
        case displayNameOverride
        case verificationPreference
        case exportBehavior
        case isDefault
        case usage
        case distribution
        case createdAt
        case updatedAt
    }

    private struct FingerprintWire: Codable {
        var algorithm: String?
        var hexDigest: String
    }

    private static func decodeIdentifier(from container: KeyedDecodingContainer<CodingKeys>) throws -> PresetIdentifier {
        if let identifier = try? container.decode(PresetIdentifier.self, forKey: .id) {
            return identifier
        }
        if let raw = try? container.decode(String.self, forKey: .id) {
            return PresetIdentifier(rawValue: raw)
        }
        throw DecodingError.dataCorruptedError(
            forKey: .id,
            in: container,
            debugDescription: "Preset identifier was missing."
        )
    }

    private static func decodeFingerprint(from container: KeyedDecodingContainer<CodingKeys>) -> CertificateFingerprint? {
        if let wire = try? container.decodeIfPresent(FingerprintWire.self, forKey: .certificateFingerprint) {
            return CertificateFingerprint(algorithm: .sha256, hexDigest: wire.hexDigest)
        }
        if let hex = try? container.decodeIfPresent(String.self, forKey: .certificateFingerprint) {
            return CertificateFingerprint(algorithm: .sha256, hexDigest: hex)
        }
        return nil
    }
}

/// Lightweight counters for one preset. The signing journal remains the
/// detailed record; this is what a library card can show without joining it.
/// The last successful app is a display name and bundle identifier — the
/// same facts the library already keeps — and nothing else.
struct PresetUsage: Equatable, Hashable, Sendable, Codable {
    var lastUsedAt: Date?
    var successfulUses: Int
    var failedUses: Int
    var lastSuccessfulBundleIdentifier: String?
    var lastSuccessfulDisplayName: String?

    static let empty = PresetUsage(
        lastUsedAt: nil,
        successfulUses: 0,
        failedUses: 0,
        lastSuccessfulBundleIdentifier: nil,
        lastSuccessfulDisplayName: nil
    )

    init(
        lastUsedAt: Date? = nil,
        successfulUses: Int = 0,
        failedUses: Int = 0,
        lastSuccessfulBundleIdentifier: String? = nil,
        lastSuccessfulDisplayName: String? = nil
    ) {
        self.lastUsedAt = lastUsedAt
        self.successfulUses = successfulUses
        self.failedUses = failedUses
        self.lastSuccessfulBundleIdentifier = lastSuccessfulBundleIdentifier
        self.lastSuccessfulDisplayName = lastSuccessfulDisplayName
    }

    var lastSuccessfulAppLabel: String? {
        if let lastSuccessfulDisplayName, !lastSuccessfulDisplayName.isEmpty {
            return lastSuccessfulDisplayName
        }
        return lastSuccessfulBundleIdentifier
    }
}

/// Fields a later version can use for sync, sharing, schedules, and
/// enterprise automation without a new preset type.
///
/// This version writes `scope == .local`, leaves `schedule` and
/// `automationLabel` nil on presets it creates, and never starts work
/// because a schedule is enabled. Values already stored are preserved.
struct PresetDistribution: Equatable, Hashable, Sendable, Codable {
    enum Scope: String, Equatable, Hashable, CaseIterable, Sendable, Codable {
        case local
        case personalCloud
        case team
        case shared

        var displayName: String {
            switch self {
            case .local: return "On this device"
            case .personalCloud: return "Personal cloud"
            case .team: return "Team"
            case .shared: return "Shared"
            }
        }
    }

    var scope: Scope
    var revision: Int
    var schedule: PresetSchedule?
    var automationLabel: String?

    static let local = PresetDistribution(scope: .local, revision: 1, schedule: nil, automationLabel: nil)

    init(scope: Scope, revision: Int, schedule: PresetSchedule?, automationLabel: String?) {
        self.scope = scope
        self.revision = max(revision, 1)
        self.schedule = schedule
        self.automationLabel = automationLabel
    }

    func incrementedRevision() -> PresetDistribution {
        PresetDistribution(
            scope: scope,
            revision: revision + 1,
            schedule: schedule,
            automationLabel: automationLabel
        )
    }

    /// Whether this version will run the stored schedule or automation hook.
    /// Always false: the fields exist so a later version can, not so this
    /// one starts unattended signing.
    var willExecuteAutomatically: Bool { false }
}

/// A reserved schedule. Stored, never run by this version.
struct PresetSchedule: Equatable, Hashable, Sendable, Codable {
    var isEnabled: Bool
    var hour: Int?
    var minute: Int?
    var weekday: Int?
    var note: String?
}

/// The outcome of one use of a preset. Passed back into the preset so the
/// card can show last used, successes, failures, and the last successful
/// app without reading the journal.
struct PresetUseOutcome: Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case succeeded
        case failed
        case cancelled
    }

    let presetID: PresetIdentifier
    let result: Result
    let bundleIdentifier: String?
    let displayName: String?
    let at: Date
}

/// Explicit acknowledgement required before a preset may sign.
///
/// Offering a preset and signing with it are different steps. `acknowledged`
/// is true only after the user confirms the summary. Preflight must also
/// have passed; a confirmation of an incompatible preset is still refused.
struct PresetSignConfirmation: Equatable, Sendable {
    let presetID: PresetIdentifier
    let bundleIdentifier: String
    let passesPreflight: Bool
    let acknowledged: Bool

    var mayExecute: Bool { acknowledged && passesPreflight }
}

/// The gate one-tap signing calls before the pipeline. It does not sign.
enum PresetSignConfirmationGate {
    static func validate(_ confirmation: PresetSignConfirmation) throws {
        guard confirmation.acknowledged else {
            throw ZynSignError.presetConfirmationRequired(
                diagnosticDetail: "Signing was offered without the final confirmation."
            )
        }
        guard confirmation.passesPreflight else {
            throw ZynSignError.presetNotReady(
                userMessage: "That preset does not pass preflight for this app, so it was not signed.",
                diagnosticDetail: "Confirmation was recorded for a preset that did not pass preflight."
            )
        }
    }
}

/// Whether a stored schedule should start work. This version never does.
enum PresetAutomation {
    static func shouldRun(schedule: PresetSchedule?, at date: Date) -> Bool {
        _ = date
        _ = schedule?.isEnabled
        return false
    }
}

/// Starter templates. They fill a name and preferences. They never fill a
/// certificate or a profile — those are references the user chooses.
enum PresetTemplate: String, CaseIterable, Identifiable, Sendable {
    case personalDevelopment
    case testingDevice
    case enterpriseWorkflow
    case custom

    var id: String { rawValue }

    var kind: SigningPreset.Kind {
        switch self {
        case .personalDevelopment: return .personalDevelopment
        case .testingDevice: return .testingDevice
        case .enterpriseWorkflow: return .enterpriseWorkflow
        case .custom: return .custom
        }
    }

    var suggestedName: String { kind.displayName }

    var summary: String {
        switch self {
        case .personalDevelopment:
            return "A development certificate and profile, modern entitlements, verification shown first."
        case .testingDevice:
            return "A profile that covers the apps you install on a testing device, with sharing offered after signing."
        case .enterpriseWorkflow:
            return "A team profile for repeated internal signing, with the delivery hand-off offered afterwards."
        case .custom:
            return "Start from an empty preset and choose every option yourself."
        }
    }

    var symbolName: String {
        switch self {
        case .personalDevelopment: return "person.crop.circle"
        case .testingDevice: return "iphone"
        case .enterpriseWorkflow: return "building.2"
        case .custom: return "slider.horizontal.3"
        }
    }

    func makeDraft(now: Date = Date()) -> SigningPreset {
        let verification: SigningPreset.VerificationPreference
        let export: SigningPreset.ExportBehavior
        let slot: SigningPreset.EntitlementsSlot
        switch self {
        case .personalDevelopment:
            verification = .always
            export = .keepInSignedFolder
            slot = .modern
        case .testingDevice:
            verification = .recommended
            export = .promptToShare
            slot = .modern
        case .enterpriseWorkflow:
            verification = .always
            export = .promptToDeliver
            slot = .modern
        case .custom:
            verification = .always
            export = .keepInSignedFolder
            slot = .modern
        }
        return SigningPreset(
            name: suggestedName,
            kind: kind,
            entitlementsSlot: slot,
            verificationPreference: verification,
            exportBehavior: export,
            createdAt: now,
            updatedAt: now
        )
    }
}

/// Name, duplicate, and default rules for a set of presets. Pure: the store
/// is applied by the workflow, not here.
enum SigningPresetCatalog {
    static let maximumNameLength = 80

    static func normalizedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the stored form of `raw`, or throws when it is empty, too
    /// long, contains a control character, or collides with another preset.
    static func validateName(
        _ raw: String,
        existing: [SigningPreset],
        excluding: PresetIdentifier? = nil
    ) throws -> String {
        let name = normalizedName(raw)
        guard !name.isEmpty, name.count <= maximumNameLength else {
            throw ZynSignError.presetNameInvalid(
                diagnosticDetail: "Preset names must be between 1 and \(maximumNameLength) characters."
            )
        }
        guard !name.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw ZynSignError.presetNameInvalid(
                diagnosticDetail: "Preset names cannot contain control characters."
            )
        }
        let clash = existing.contains { other in
            other.id != excluding && other.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if clash {
            throw ZynSignError.presetConflict(
                diagnosticDetail: "Another preset already uses that name."
            )
        }
        return name
    }

    /// A new preset with the same references and a fresh identity, usage,
    /// and default flag. The name is unique against `existing`.
    static func duplicate(
        _ preset: SigningPreset,
        existing: [SigningPreset],
        now: Date
    ) -> SigningPreset {
        let base = "\(preset.name) Copy"
        var candidate = base
        var suffix = 2
        let taken = Set(existing.map { $0.name.lowercased() })
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return SigningPreset(
            name: candidate,
            kind: preset.kind,
            certificateFingerprint: preset.certificateFingerprint,
            provisioningProfileName: preset.provisioningProfileName,
            provisioningProfileID: preset.provisioningProfileID,
            teamIdentifier: preset.teamIdentifier,
            entitlementsSlot: preset.entitlementsSlot,
            bundleIdentifierOverride: preset.bundleIdentifierOverride,
            displayNameOverride: preset.displayNameOverride,
            verificationPreference: preset.verificationPreference,
            exportBehavior: preset.exportBehavior,
            isDefault: false,
            usage: .empty,
            distribution: .local,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Returns the set with `id` as the only default. Presets whose flag
    /// changed get `now` as their update time.
    static func settingDefault(
        _ presets: [SigningPreset],
        id: PresetIdentifier,
        now: Date
    ) -> [SigningPreset] {
        presets.map { preset in
            let shouldDefault = preset.id == id
            guard preset.isDefault != shouldDefault else { return preset }
            var copy = preset
            copy.isDefault = shouldDefault
            copy.updatedAt = now
            return copy
        }
    }
}

/// A preset identifier — opaque and stable across launches.
struct PresetIdentifier: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String
    init() { self.rawValue = UUID().uuidString }
    init(rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}
