import Foundation

/// The persistence boundary for the user's preferences.
///
/// The store owns the stored document and nothing else: it loads the whole
/// `ZynSignPreferences` value once, hands it back unchanged, and replaces it
/// atomically when the user changes something. It is deliberately *not* a
/// per-key accessor — preferences are read as one value, so the presentation
/// layer never has a stale half of them, and a change is one write rather
/// than a scatter of writes.
///
/// The port is isolated to the main actor because it is a presentation-facing
/// dependency: the Settings Control Center reads and writes it while the user
/// is looking at it, and the composition root reads it once during launch.
@MainActor
protocol PreferencesStore: AnyObject {

    /// The preferences as currently stored, falling back to shipped defaults
    /// when nothing is stored yet. Always available: a store never throws on
    /// read, because an unreadable document becomes defaults.
    var snapshot: ZynSignPreferences { get }

    /// Whether the stored document was seeded from the values an earlier
    /// version of ZynSign kept in `UserDefaults`. Reported once, so the
    /// Settings area can say the migration happened.
    var didMigrateLegacyValues: Bool { get }

    /// Stores `preferences`, replacing whatever was stored before.
    func save(_ preferences: ZynSignPreferences) throws

    /// Restores the shipped defaults.
    func reset() throws
}

/// The values an earlier version of ZynSign kept in `UserDefaults`.
///
/// Reading them is a migration concern and lives at the store boundary, where
/// the legacy keys are known. Only keys whose settings surface this version
/// owns are migrated — an archive option the Archive screen still reads stays
/// where it is, so there is never a second source of truth for one setting.
struct LegacyPreferenceValues: Equatable, Sendable {

    /// The legacy appearance override: 0 system, 1 light, 2 dark.
    var appearanceRawValue: Int?

    /// Whether first-launch onboarding had been completed.
    var onboardingCompleted: Bool?

    /// Reads the legacy values from `defaults`.
    init(defaults: UserDefaults) {
        appearanceRawValue = defaults.object(forKey: Self.appearanceKey) as? Int
        onboardingCompleted = defaults.object(forKey: Self.onboardingKey) as? Bool
    }

    /// The legacy keys, named here so the migration and the cleanup that
    /// follows it cannot disagree.
    static let appearanceKey = "zynsign.appearance.colorScheme"
    static let onboardingKey = "zynsign.onboarding.completed"

    /// Whether there is anything to migrate.
    var isEmpty: Bool { appearanceRawValue == nil && onboardingCompleted == nil }

    /// The appearance the legacy override described, or `nil` when the stored
    /// value is not one this build understands.
    var appearanceMode: AppearanceMode? {
        switch appearanceRawValue {
        case 0: return .system
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }
}

extension ZynSignPreferences {

    /// Seeds preferences from the values an earlier version kept in
    /// `UserDefaults`, leaving every other group at its shipped defaults.
    ///
    /// Migration is additive and lossless in the only direction that matters:
    /// a user who had already chosen a light interface and finished
    /// onboarding keeps both. An unrecognised legacy value is ignored rather
    /// than guessed at.
    static func migrated(from legacy: LegacyPreferenceValues) -> ZynSignPreferences {
        var preferences = ZynSignPreferences.shippedDefault
        if let appearanceMode = legacy.appearanceMode {
            preferences.appearance.appearanceMode = appearanceMode
        }
        if let onboardingCompleted = legacy.onboardingCompleted {
            preferences.general.onboardingCompleted = onboardingCompleted
        }
        return preferences
    }
}
