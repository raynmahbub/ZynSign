import Foundation

/// The persistence boundary for the user's library of imported
/// provisioning profiles.
///
/// Profiles are kept as a flat list of `ProvisioningProfileSummary`
/// values. The original `.mobileprovision` file lives in the user's file
/// storage, referenced by file name. The summary carries the profile's
/// declared metadata — name, team, expiration, allowed bundle
/// identifiers — which is all the picker UI needs.
protocol ProvisioningProfileLibrary: Sendable {

    /// Lists every stored profile, soonest-to-expire first; expired
    /// profiles sink to the end.
    func allProfiles() async throws -> [ProvisioningProfileSummary]

    /// Retrieves the profile with `id`, or `nil` when none exists.
    func profile(withID id: ProvisioningProfileIdentifier) async throws -> ProvisioningProfileSummary?

    /// The original bytes of a stored profile, bounded to the CMS input
    /// limit, or nil if the record was removed. Used for explicit selection
    /// on the signing screen; the UI never constructs a storage path from a
    /// profile's name and never treats a summary as verification evidence.
    func profileBytes(withID id: ProvisioningProfileIdentifier) async throws -> Data?

    /// Inserts or replaces a profile summary.
    func upsert(_ summary: ProvisioningProfileSummary) async throws

    /// Removes the profile with `id`. No-op when no such profile exists.
    func remove(profileWithID id: ProvisioningProfileIdentifier) async throws

    /// The number of stored profiles. Convenience for "X profiles" UI.
    func count() async throws -> Int
}

extension ProvisioningProfileLibrary {
    /// Existing test doubles that hold summaries only have no stored bytes.
    /// A signing screen treats nil as unavailable, never as an empty profile.
    func profileBytes(withID id: ProvisioningProfileIdentifier) async throws -> Data? { nil }
}
