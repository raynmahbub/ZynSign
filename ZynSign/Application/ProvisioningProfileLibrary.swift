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

    /// Inserts or replaces a profile summary.
    func upsert(_ summary: ProvisioningProfileSummary) async throws

    /// Removes the profile with `id`. No-op when no such profile exists.
    func remove(profileWithID id: ProvisioningProfileIdentifier) async throws

    /// The number of stored profiles. Convenience for "X profiles" UI.
    func count() async throws -> Int
}
