/// The persistence boundary for application records.
///
/// The store keeps `ApplicationRecord` values across launches and hands them
/// back unchanged. It is the seam behind which the storage technology lives:
/// callers see domain values and typed errors, never a file, a database
/// context, a managed object, or an encoding. The port is deliberately
/// small — the five operations the library lifecycle needs — and is not a
/// general query or database abstraction.
///
/// Semantics every implementation upholds:
///
/// - **Identity is `id`.** `insert` fails when a record with the same
///   identifier exists; `update` fails when none does. An update can
///   therefore never create a second record, and an insert can never
///   silently replace one.
/// - **Listing is deterministic.** `allRecords()` returns records in
///   `ApplicationRecord.libraryOrder`.
/// - **Failures are typed.** Storage that cannot be reached, a catalog that
///   cannot be interpreted, or a schema newer than the build each surface as
///   a distinct `ZynSignError`; a failed operation leaves the previously
///   stored records as they were.
/// - **Deletion is idempotent.** Deleting an identifier no record carries
///   does nothing and does not fail.
///
/// The store holds metadata only. The bytes a record refers to live in
/// artifact storage, reached through `LibraryArtifactStore`; the record
/// carries the reference. Sensitive material — key material, credentials,
/// certificate bodies, profile data — is never a record field and never
/// passes through this port.
protocol ApplicationRecordStore: Sendable {

    /// Creates a record. Fails with a typed error when a record with the
    /// same identifier already exists.
    func insert(_ record: ApplicationRecord) async throws

    /// Replaces the record carrying `record.id`. Fails with a typed error
    /// when no such record exists.
    func update(_ record: ApplicationRecord) async throws

    /// The record carrying `id`, or `nil` when none does.
    func record(withID id: ApplicationRecordIdentifier) async throws -> ApplicationRecord?

    /// Every stored record, in library order.
    func allRecords() async throws -> [ApplicationRecord]

    /// Removes the record carrying `id`, if one exists.
    func delete(recordWithID id: ApplicationRecordIdentifier) async throws
}
