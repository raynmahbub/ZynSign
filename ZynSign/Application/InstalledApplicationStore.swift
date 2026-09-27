import Foundation

/// The persistence boundary for the Installed Apps Library.
///
/// The store keeps `InstalledApplicationRecord` values and
/// `PendingInstallationAttempt` values across launches and hands them back
/// unchanged. It is the seam behind which the storage technology lives.
///
/// The port is deliberately small. Records are keyed on `id`; the
/// use case enforces the one-record-per-bundle-identifier rule. Attempts
/// are held beside the records so a relaunch restores them exactly as they
/// were: still pending, never confirmed, never resolved by a timer.
protocol InstalledApplicationStore: Sendable {

    /// Lists every stored record, most recently updated first.
    func allRecords() async throws -> [InstalledApplicationRecord]

    /// Stores a record, replacing any record with the same identifier.
    func write(_ record: InstalledApplicationRecord) async throws

    /// Removes the record with `id`. No-op when no such record exists.
    func remove(recordWithID id: InstalledApplicationIdentifier) async throws

    /// Removes every stored record. Attempts are untouched — resolving an
    /// attempt is always the user's explicit action.
    func removeAllRecords() async throws

    /// Lists every pending attempt, oldest first.
    func allAttempts() async throws -> [PendingInstallationAttempt]

    /// Stores an attempt, replacing any attempt with the same identifier.
    func write(_ attempt: PendingInstallationAttempt) async throws

    /// Removes the attempt with `id`. No-op when no such attempt exists.
    func removeAttempt(withID id: InstallationEventIdentifier) async throws

    /// The maximum number of records the store retains.
    var capacity: Int { get }

    /// The size of the store's own persisted records, in bytes, for the
    /// workspace's storage report. `nil` when the store cannot measure
    /// itself; presentation then omits the row rather than reporting zero.
    func storedByteCount() async -> Int?
}

extension InstalledApplicationStore {

    /// The default when a store cannot measure itself.
    func storedByteCount() async -> Int? { nil }
}

extension Notification.Name {

    /// Posted after the Installed Apps Library changed: a record was
    /// written or removed, the library was cleared, or an attempt changed.
    ///
    /// The workspace's screens re-read the store when this is posted rather
    /// than polling it. The notification carries no payload: observers read
    /// the store itself, so what they show is always what the store holds.
    static let installedApplicationsDidChange = Notification.Name("ZynSignInstalledApplicationsDidChange")
}

/// An installed-applications store that says when it changed.
///
/// Wraps the store port and posts `installedApplicationsDidChange` after
/// every change it completes — whoever made it. Reads pass straight
/// through and post nothing, and a change that throws posts nothing either,
/// because nothing changed.
struct NotifyingInstalledApplicationStore: InstalledApplicationStore {

    private let base: any InstalledApplicationStore

    /// Wraps `base`.
    init(wrapping base: any InstalledApplicationStore) {
        self.base = base
    }

    var capacity: Int { base.capacity }

    func allRecords() async throws -> [InstalledApplicationRecord] {
        try await base.allRecords()
    }

    func write(_ record: InstalledApplicationRecord) async throws {
        try await base.write(record)
        postChange()
    }

    func remove(recordWithID id: InstalledApplicationIdentifier) async throws {
        try await base.remove(recordWithID: id)
        postChange()
    }

    func removeAllRecords() async throws {
        try await base.removeAllRecords()
        postChange()
    }

    func allAttempts() async throws -> [PendingInstallationAttempt] {
        try await base.allAttempts()
    }

    func write(_ attempt: PendingInstallationAttempt) async throws {
        try await base.write(attempt)
        postChange()
    }

    func removeAttempt(withID id: InstallationEventIdentifier) async throws {
        try await base.removeAttempt(withID: id)
        postChange()
    }

    func storedByteCount() async -> Int? {
        await base.storedByteCount()
    }

    private func postChange() {
        NotificationCenter.default.post(name: .installedApplicationsDidChange, object: nil)
    }
}
