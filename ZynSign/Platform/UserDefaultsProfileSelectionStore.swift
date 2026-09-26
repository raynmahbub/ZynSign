import Foundation

/// `UserDefaults`-backed `ProfileSelectionStore`.
///
/// Two keys hold everything: the pinned "Use for Signing" profile and a
/// small application-ID → profile-ID dictionary for per-app overrides. The
/// values are opaque identifiers only — no profile content, no bundle
/// identifiers beyond the application record's own identifier, nothing
/// sensitive. Writes are plain `synchronize`-free `UserDefaults` sets; a
/// stored identifier whose profile or application no longer exists simply
/// reads back as unresolvable and callers fall back to the automatic
/// suggestion.
struct UserDefaultsProfileSelectionStore: ProfileSelectionStore {

    /// The key holding the pinned profile's identifier.
    private static let preferredKey = "zynsign.profileSelection.preferredProfileID"

    /// The key holding the per-application overrides.
    private static let overridesKey = "zynsign.profileSelection.applicationSelections"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func preferredProfileID() -> ProvisioningProfileIdentifier? {
        guard let raw = defaults.string(forKey: Self.preferredKey) else { return nil }
        return ProvisioningProfileIdentifier(rawValue: raw)
    }

    func setPreferredProfile(_ id: ProvisioningProfileIdentifier?) {
        if let id {
            defaults.set(id.rawValue, forKey: Self.preferredKey)
        } else {
            defaults.removeObject(forKey: Self.preferredKey)
        }
    }

    func selection(
        forApplication applicationID: ApplicationRecordIdentifier
    ) -> ProvisioningProfileIdentifier? {
        guard let raw = overrides()[applicationID.rawValue] else { return nil }
        return ProvisioningProfileIdentifier(rawValue: raw)
    }

    func setSelection(
        _ id: ProvisioningProfileIdentifier?,
        forApplication applicationID: ApplicationRecordIdentifier
    ) {
        var selections = overrides()
        if let id {
            selections[applicationID.rawValue] = id.rawValue
        } else {
            selections.removeValue(forKey: applicationID.rawValue)
        }
        defaults.set(selections, forKey: Self.overridesKey)
    }

    private func overrides() -> [String: String] {
        (defaults.dictionary(forKey: Self.overridesKey) as? [String: String]) ?? [:]
    }
}
