/// The persistence boundary for the library's organization: collections
/// and usage.
///
/// The store keeps one `LibraryOrganization` value across launches and
/// hands it back unchanged. It is a document store — read the whole value,
/// replace the whole value — because the organization is small and every
/// change to it is a change to the whole arrangement. The operations are
/// synchronous on purpose: the organizer that owns the store is an actor,
/// and a store without suspension points means a read-modify-write on the
/// organizer can never interleave with another one.
///
/// A missing document is an empty organization. A document that cannot be
/// interpreted, or that a newer build wrote, fails with a typed error and
/// is left in place; the store never resets it.
///
/// The port is declared here, by the layer that consumes it, and
/// implemented in the platform layer.
protocol LibraryOrganizationStore: Sendable {

    /// Reads the stored organization. Fails with a typed error when the
    /// document exists but cannot be read or interpreted.
    func loadOrganization() throws -> LibraryOrganization

    /// Replaces the stored organization with `organization`. On a thrown
    /// error the stored document is unchanged.
    func saveOrganization(_ organization: LibraryOrganization) throws
}
