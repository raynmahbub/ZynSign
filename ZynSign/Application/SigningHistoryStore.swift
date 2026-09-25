import Foundation

/// The persistence boundary for the on-device signing history journal.
///
/// The store keeps `SigningRecord` values across launches and hands them
/// back unchanged. It is the seam behind which the storage technology
/// lives. The port is deliberately small — append-only with bounded size —
/// and is not a general query abstraction.
protocol SigningHistoryStore: Sendable {

    /// Lists every stored record, most recent first.
    func allRecords() async throws -> [SigningRecord]

    /// Lists records for a given preset, most recent first.
    func records(forPreset presetID: PresetIdentifier) async throws -> [SigningRecord]

    /// Appends a record. The store enforces the journal's size cap,
    /// discarding the oldest records when full.
    func append(_ record: SigningRecord) async throws

    /// Removes the record with `id`. No-op when no such record exists.
    func remove(recordWithID id: SigningRecordIdentifier) async throws

    /// Removes every stored record. Used by the "Clear journal" button in
    /// Settings → Analytics.
    func clear() async throws

    /// The number of stored records. Convenience for "X entries" UI.
    func count() async throws -> Int

    /// The maximum number of records the store will retain.
    var capacity: Int { get }
}
