import Foundation

/// Every preference ZynSign keeps for the user, in one value.
///
/// Preferences are configuration, not state: they describe how the user wants
/// ZynSign to behave, they are cheap to read, and they are written whole.
/// `ZynSignPreferences` is the single source of truth the Settings Control
/// Center edits, the composition root reads at launch, and the persistence
/// boundary stores.
///
/// The value is organised into independent groups — general, signing,
/// security, storage, diagnostics, appearance, and advanced — so a later
/// version can add a group, or a setting inside one, without touching the
/// others. Decoding is deliberately forgiving: a group the stored file does
/// not mention falls back to its shipped defaults, and a group written by a
/// newer build is read as far as this build understands it. Adding a setting
/// is therefore never a migration, and a preferences file can never stop the
/// application launching.
///
/// Nothing in this type is secret. It records *references* to signing
/// material — a certificate fingerprint, a profile name — never key bytes,
/// never credential material, and never anything the Keychain holds. The
/// Security group is about how ZynSign guards the interface; it holds no
/// secret of its own.
struct ZynSignPreferences: Equatable, Sendable, Codable {

    /// The schema version this build reads and writes.
    static let schemaVersion = 1

    /// The shipped defaults, used on a fresh install, after a reset, and as
    /// the fallback for any group a stored file does not describe.
    static let shippedDefault = ZynSignPreferences()

    /// The version of the stored document these preferences came from. It is
    /// informational: this build reads older documents group by group and
    /// never refuses a newer one.
    var schemaVersion: Int

    /// Everyday preferences: where ZynSign starts, feedback, and motion.
    var general: GeneralPreferences

    /// Defaults a signing session starts from, overridable per session.
    var signing: SigningPreferences

    /// How ZynSign guards itself and what it shows while guarded.
    var security: SecurityPreferences

    /// How ZynSign manages its own disk usage.
    var storage: StoragePreferences

    /// What ZynSign records and reports about itself.
    var diagnostics: DiagnosticsPreferences

    /// Appearance and accessibility presentation choices.
    var appearance: AppearancePreferences

    /// Options for experienced users, deliberately separated from the rest.
    var advanced: AdvancedPreferences

    init(
        schemaVersion: Int = ZynSignPreferences.schemaVersion,
        general: GeneralPreferences = GeneralPreferences(),
        signing: SigningPreferences = SigningPreferences(),
        security: SecurityPreferences = SecurityPreferences(),
        storage: StoragePreferences = StoragePreferences(),
        diagnostics: DiagnosticsPreferences = DiagnosticsPreferences(),
        appearance: AppearancePreferences = AppearancePreferences(),
        advanced: AdvancedPreferences = AdvancedPreferences()
    ) {
        self.schemaVersion = schemaVersion
        self.general = general
        self.signing = signing
        self.security = security
        self.storage = storage
        self.diagnostics = diagnostics
        self.appearance = appearance
        self.advanced = advanced
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case general
        case signing
        case security
        case storage
        case diagnostics
        case appearance
        case advanced
    }

    /// Decodes group by group, so a document written by another version of
    /// ZynSign still loads: an absent group, or one this build cannot read —
    /// a shape a later version changed, or damage — becomes its shipped
    /// defaults while every other group still loads. An unrecognised key
    /// inside a readable group is ignored by that group's own decoder.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.schemaVersion
        general = Self.decodeGroup(GeneralPreferences.self, from: container, key: .general) ?? GeneralPreferences()
        signing = Self.decodeGroup(SigningPreferences.self, from: container, key: .signing) ?? SigningPreferences()
        security = Self.decodeGroup(SecurityPreferences.self, from: container, key: .security) ?? SecurityPreferences()
        storage = Self.decodeGroup(StoragePreferences.self, from: container, key: .storage) ?? StoragePreferences()
        diagnostics = Self.decodeGroup(DiagnosticsPreferences.self, from: container, key: .diagnostics) ?? DiagnosticsPreferences()
        appearance = Self.decodeGroup(AppearancePreferences.self, from: container, key: .appearance) ?? AppearancePreferences()
        advanced = Self.decodeGroup(AdvancedPreferences.self, from: container, key: .advanced) ?? AdvancedPreferences()
    }

    /// Reads one group from `container`, or `nil` when the document does not
    /// describe it in a shape this build understands. A group is the unit of
    /// tolerance: adding a setting to one group can never cost the user the
    /// settings in another.
    private static func decodeGroup<Group: Decodable>(
        _ type: Group.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Group? {
        try? container.decode(type, forKey: key)
    }

    /// Restores every group to its shipped defaults.
    ///
    /// `preservingOnboardingCompletion` keeps the one preference that is
    /// really a record of something the user already did: resetting
    /// preferences is not a reason to walk a user back through onboarding.
    /// Resetting onboarding is its own explicit action.
    mutating func resetToShippedDefaults(preservingOnboardingCompletion: Bool) {
        let onboardingCompleted = general.onboardingCompleted
        self = ZynSignPreferences.shippedDefault
        if preservingOnboardingCompletion {
            general.onboardingCompleted = onboardingCompleted
        }
    }

    /// A log-safe summary of the preferences: which groups are at their
    /// shipped defaults and which are not. Carries no values, so it is safe
    /// to write into a diagnostic report.
    var changedGroupCount: Int {
        var count = 0
        if general != GeneralPreferences() { count += 1 }
        if signing != SigningPreferences() { count += 1 }
        if security != SecurityPreferences() { count += 1 }
        if storage != StoragePreferences() { count += 1 }
        if diagnostics != DiagnosticsPreferences() { count += 1 }
        if appearance != AppearancePreferences() { count += 1 }
        if advanced != AdvancedPreferences() { count += 1 }
        return count
    }
}

// MARK: - General

/// Everyday preferences: where ZynSign starts, how it responds, and how much
/// it moves.
struct GeneralPreferences: Equatable, Sendable, Codable {

    /// The tab ZynSign opens on launch.
    var landingTab: LandingTab = .home

    /// Whether taps and outcomes produce haptic feedback.
    var hapticFeedbackEnabled: Bool = true

    /// How much ZynSign animates its own transitions.
    var animationPreference: AnimationPreference = .standard

    /// Whether the first-launch onboarding card has been completed. This is
    /// the only preference that records something the user did rather than
    /// something the user wants.
    var onboardingCompleted: Bool = false
}

/// The tab ZynSign opens on launch.
///
/// The values mirror the shell's primary tabs. The mapping to a presentation
/// section lives in the presentation layer, so a change to the shell's tabs
/// does not change the stored preference.
enum LandingTab: String, CaseIterable, Hashable, Sendable, Codable {
    case home
    case library
    case certificates
    case profiles
    case settings

    /// The navigation title of the tab.
    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .certificates: return "Certificates"
        case .profiles: return "Profiles"
        case .settings: return "Settings"
        }
    }
}

/// How much ZynSign animates its own transitions.
///
/// `.standard` follows the system Reduce Motion setting. `.reduced` keeps
/// state changes legible without movement. `.off` removes ZynSign's own
/// animations entirely. The system setting always wins: a user who asked for
/// reduced motion at the system level never gets more motion than `.reduced`.
enum AnimationPreference: String, CaseIterable, Hashable, Sendable, Codable {
    case standard
    case reduced
    case off

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .reduced: return "Reduced"
        case .off: return "Off"
        }
    }

    /// Whether ZynSign's own transitions may animate, given the system's
    /// Reduce Motion setting.
    func permitsAnimation(systemReduceMotion: Bool) -> Bool {
        switch self {
        case .standard: return !systemReduceMotion
        case .reduced, .off: return false
        }
    }
}

// MARK: - Signing

/// The defaults a signing session starts from.
///
/// Every value here is a *starting point*: the signing screen presents it,
/// and the user may choose something else for that session. Nothing in this
/// group overrides an explicit choice, and nothing here holds signing
/// material — an identity is named by its public certificate fingerprint and
/// a profile by the name the profile declares about itself.
struct SigningPreferences: Equatable, Sendable, Codable {

    /// The certificate fingerprint of the identity a signing session starts
    /// with. `nil` means no preference has been recorded.
    var preferredIdentityFingerprint: String? = nil

    /// The declared name of the provisioning profile a signing session
    /// starts with. `nil` means no preference has been recorded.
    var preferredProfileName: String? = nil

    /// Whether the identity and profile chosen for one session are remembered
    /// as the starting point for the next.
    var rememberSelections: Bool = true

    /// Whether ZynSign runs its pre-sign compatibility assessment
    /// automatically when a signing screen opens.
    var automaticCompatibilityAnalysis: Bool = true
}

// MARK: - Security

/// How ZynSign guards itself and what it shows while guarded.
///
/// This group holds no secret. Face ID and Touch ID are asked for at the
/// moment they are needed; private keys stay in the Keychain with
/// non-extractable protection and are never readable through this boundary,
/// through Settings, or through any export.
struct SecurityPreferences: Equatable, Sendable, Codable {

    /// Whether Face ID or Touch ID guards the application. When off, the
    /// application opens unlocked and no authentication is requested.
    var biometricLockEnabled: Bool = false

    /// Whether sensitive actions — signing, resetting, exporting a
    /// diagnostic report — ask for authentication even while unlocked.
    var requireAuthenticationForSensitiveActions: Bool = true

    /// Whether certificate and profile details are masked while the
    /// application is locked.
    var hideSensitiveInformationWhenLocked: Bool = true

    /// How long the application stays unlocked while unused.
    var sessionTimeout: SessionTimeout = .oneMinute

    /// How certificate and profile identifiers are shown at all.
    var sensitiveDataVisibility: SensitiveDataVisibility = .masked
}

/// How long ZynSign stays unlocked while it is not being used.
enum SessionTimeout: String, CaseIterable, Hashable, Sendable, Codable {
    case immediately
    case oneMinute
    case fiveMinutes
    case fifteenMinutes

    var displayName: String {
        switch self {
        case .immediately: return "Immediately"
        case .oneMinute: return "After 1 minute"
        case .fiveMinutes: return "After 5 minutes"
        case .fifteenMinutes: return "After 15 minutes"
        }
    }

    /// How long the unlocked session lasts, or `nil` when it never lapses.
    var seconds: TimeInterval? {
        switch self {
        case .immediately: return 0
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        }
    }
}

/// How certificate and profile identifiers are shown.
enum SensitiveDataVisibility: String, CaseIterable, Hashable, Sendable, Codable {
    /// Never shown: rows that would display them are replaced by a note.
    case hidden
    /// Shown as masked characters until the user reveals them.
    case masked
    /// Shown in full.
    case visible

    var displayName: String {
        switch self {
        case .hidden: return "Hidden"
        case .masked: return "Masked"
        case .visible: return "Visible"
        }
    }

    /// Whether a value may be shown at all.
    var showsValues: Bool { self != .hidden }
}

// MARK: - Storage

/// How ZynSign manages its own disk usage.
struct StoragePreferences: Equatable, Sendable, Codable {

    /// Whether ZynSign clears its temporary workspace itself when the
    /// cleanup policy says so, rather than waiting to be asked.
    var automaticTemporaryCleanup: Bool = true
}

// MARK: - Diagnostics

/// What ZynSign records and reports about itself.
///
/// Detailed technical logging is opt-in and off by default. Everything this
/// group controls stays on the device: there is no sender, no endpoint, and
/// no sync anywhere in ZynSign.
struct DiagnosticsPreferences: Equatable, Sendable, Codable {

    /// Whether diagnostic history is kept between launches.
    var keepDiagnosticHistory: Bool = true

    /// Whether the technical log records entries at all. Off by default.
    var detailedTechnicalLogs: Bool = false

    /// Whether developer-facing detail — raw categories, storage counts,
    /// schema versions — is shown in the Diagnostics area. Off by default.
    var developerDiagnostics: Bool = false
}

// MARK: - Appearance

/// Appearance and accessibility presentation choices.
///
/// Only the default theme ships in this version. The stored `themeIdentifier`
/// exists so a later theme adds a choice rather than a migration.
struct AppearancePreferences: Equatable, Sendable, Codable {

    /// Light, dark, or whatever the system is set to.
    var appearanceMode: AppearanceMode = .system

    /// Whether the interface asks the system for increased contrast.
    var increaseContrast: Bool = false

    /// Whether the interface follows the system text size. Dynamic Type is
    /// supported throughout; this records the choice so a future per-app text
    /// size has somewhere to live.
    var respectsSystemTextSize: Bool = true

    /// The theme in use. Only `ZynSignTheme.defaultIdentifier` ships today.
    var themeIdentifier: String = ZynSignTheme.defaultIdentifier
}

/// Light, dark, or the system setting.
enum AppearanceMode: String, CaseIterable, Hashable, Sendable, Codable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// The themes ZynSign ships.
///
/// One theme, deliberately: a second theme is a design decision, not a
/// setting, and an invented palette is worse than none. The identifier is
/// stored so adding a theme is an additive change.
enum ZynSignTheme: String, CaseIterable, Hashable, Sendable, Codable {
    case zynSign = "zynsign.default"

    static let defaultIdentifier = ZynSignTheme.zynSign.rawValue

    var displayName: String {
        switch self {
        case .zynSign: return "ZynSign"
        }
    }
}

// MARK: - Advanced

/// Options for experienced users.
///
/// These change where ZynSign works and how strictly it reads its own
/// results. They are deliberately separated from everyday settings, they are
/// all reversible, and none of them can lose an imported application.
struct AdvancedPreferences: Equatable, Sendable, Codable {

    /// Where ZynSign stages work in progress.
    var workingDirectoryBehavior: WorkingDirectoryBehavior = .temporary

    /// When ZynSign clears its temporary workspace.
    var temporaryCleanupPolicy: TemporaryCleanupPolicy = .onExit

    /// How strictly ZynSign reads verification results.
    var verificationStrictness: VerificationStrictness = .standard

    /// Experimental features the user has switched on. Empty by default, and
    /// only ever populated by features that are already implemented — see
    /// `ExperimentalFeature`.
    var experimentalFeatures: Set<ExperimentalFeature> = []
}

/// Where ZynSign stages work in progress.
enum WorkingDirectoryBehavior: String, CaseIterable, Hashable, Sendable, Codable {
    /// The system temporary directory: reclaimable, cleared by the cleanup
    /// policy, and not part of any backup.
    case temporary
    /// A durable workspace under Application Support: survives longer, and
    /// the user's to clean.
    case applicationSupport

    var displayName: String {
        switch self {
        case .temporary: return "System temporary"
        case .applicationSupport: return "Application Support workspace"
        }
    }
}

/// When ZynSign clears its temporary workspace.
enum TemporaryCleanupPolicy: String, CaseIterable, Hashable, Sendable, Codable {
    /// When ZynSign quits.
    case onExit
    /// When ZynSign launches, for anything older than a day.
    case onLaunch
    /// Only when asked from Storage.
    case manual

    var displayName: String {
        switch self {
        case .onExit: return "When ZynSign quits"
        case .onLaunch: return "When ZynSign launches"
        case .manual: return "Only when I ask"
        }
    }
}

/// How strictly ZynSign reads verification results.
enum VerificationStrictness: String, CaseIterable, Hashable, Sendable, Codable {
    /// Report every finding and let the user decide.
    case standard
    /// Ask for confirmation before acting on a result that carries any
    /// finding, including informational ones.
    case strict

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .strict: return "Strict"
        }
    }
}

/// Experimental features.
///
/// A case exists here only once the feature behind it is implemented and
/// reachable, because this list is the only place the Settings interface
/// looks for something to offer. There are no cases today, so the Advanced
/// section says exactly that instead of listing flags that do nothing.
///
/// Adding a feature is therefore one case plus the surface it switches on —
/// no restructuring of the settings system, and no row that lies.
enum ExperimentalFeature: String, CaseIterable, Hashable, Sendable, Codable {
    // No experimental features are implemented in this version.
}
