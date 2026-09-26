import Foundation

/// Persistence for the user's profile choices: which profile "Use for
/// Signing" pinned, and which profile each app's detail screen shows when
/// the user overrode the automatic suggestion.
///
/// The store is a preference, not an authorization: callers always re-check
/// that the stored profile still exists in the library and is still
/// eligible before acting on it. A profile that was removed simply reads
/// back as no selection.
///
/// The port lives in Application so the presentation layer depends on the
/// abstraction; the `UserDefaults`-backed implementation lives in Platform
/// and is supplied by the composition root.
protocol ProfileSelectionStore: Sendable {

    /// The profile pinned by "Use for Signing", if any.
    func preferredProfileID() -> ProvisioningProfileIdentifier?

    /// Pins (or, with `nil`, unpins) the profile "Use for Signing" refers to.
    func setPreferredProfile(_ id: ProvisioningProfileIdentifier?)

    /// The user's manual override for one application, if any.
    func selection(
        forApplication applicationID: ApplicationRecordIdentifier
    ) -> ProvisioningProfileIdentifier?

    /// Sets (or, with `nil`, clears) the manual override for one
    /// application.
    func setSelection(
        _ id: ProvisioningProfileIdentifier?,
        forApplication applicationID: ApplicationRecordIdentifier
    )
}
