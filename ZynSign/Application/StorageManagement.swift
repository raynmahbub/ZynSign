import Foundation

/// The storage use case: it measures what ZynSign uses and removes only what
/// the user asked for.
///
/// Reporting and removal are separate on purpose. The footprint is read from
/// the storage that holds the bytes; removal goes through the port that owns
/// each kind of storage, so no measuring path can delete anything and no
/// cleanup path can reach a category it was not asked about.
///
/// What cleanup can and cannot touch:
///
/// - **Exported artifacts** — removed through the Export Center, together with
///   the records that describe them. The library's own artifacts and the
///   signing history are untouched.
/// - **Temporary files** — removed through the temporary-data boundary, which
///   only removes entries older than the retention interval and only entries
///   whose names it recognises as ZynSign's own work.
/// - **Old history records** — removed through the signing journal, oldest
///   first, keeping the most recent records whatever their age.
/// - **Imported applications** — never removed here. The only way an imported
///   application is deleted is the Library's own delete, one entry at a time,
///   with its own confirmation. This type has no code path that can reach it.
struct StorageManagement {

    private let reporting: any StorageFootprintReporting
    private let temporaryData: (any TemporaryDataCleaning)?
    private let exports: ExportCenter
    private let history: any SigningHistoryStore
    private let now: @Sendable () -> Date

    init(
        reporting: any StorageFootprintReporting,
        temporaryData: (any TemporaryDataCleaning)? = nil,
        exports: ExportCenter,
        history: any SigningHistoryStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reporting = reporting
        self.temporaryData = temporaryData
        self.exports = exports
        self.history = history
        self.now = now
    }

    /// What ZynSign is using right now.
    ///
    /// The byte counts are measured by storage. The item count for the history
    /// is the number of records the journal holds, because records are what the
    /// history's cleanup removes; a journal that cannot be read keeps the
    /// measured file count rather than reporting zero records.
    func footprint() async throws -> StorageFootprint {
        let measured = try reporting.footprint()
        guard let recordCount = try? await history.count() else { return measured }
        var usages = measured.usages
        if let index = usages.firstIndex(where: { $0.category == .history }) {
            usages[index] = StorageCategoryUsage(
                category: .history,
                byteCount: usages[index].byteCount,
                itemCount: recordCount
            )
        }
        return StorageFootprint(usages: usages)
    }

    /// Runs one cleanup, reporting exactly what it removed and what it left
    /// alone.
    ///
    /// A cleanup never throws for an item it could not remove: it counts the
    /// item as skipped and finishes, so one unremovable file cannot leave the
    /// rest of the work undone. It throws only when the storage it needs cannot
    /// be read at all.
    func cleanup(_ kind: StorageCleanupKind) async throws -> StorageCleanupReport {
        switch kind {
        case .exportedArtifacts:
            return try await exports.removeAllArtifacts()

        case .temporaryFiles:
            guard let temporaryData else {
                return StorageCleanupReport(kind: .temporaryFiles)
            }
            let cleanup = try temporaryData.removeTemporaryData(
                olderThan: StorageCleanupPolicy.temporaryDataCutoff(now: now())
            )
            return StorageCleanupReport(
                kind: .temporaryFiles,
                removedTemporaryFileCount: cleanup.removedFileCount,
                freedByteCount: cleanup.freedByteCount,
                skippedItemCount: cleanup.skippedItemCount
            )

        case .oldHistoryRecords:
            let records = try await history.allRecords()
            let identifiers = StorageCleanupPolicy.historyRecordIdentifiersToRemove(
                from: records,
                now: now()
            )
            var removed = 0
            var skipped = 0
            for identifier in identifiers {
                do {
                    try await history.remove(recordWithID: identifier)
                    removed += 1
                } catch {
                    skipped += 1
                }
            }
            return StorageCleanupReport(
                kind: .oldHistoryRecords,
                removedHistoryRecordCount: removed,
                skippedItemCount: skipped
            )
        }
    }

    /// How much temporary storage holds, for the recovery message.
    func temporaryDataUsage() -> (byteCount: Int, fileCount: Int)? {
        temporaryData.flatMap { try? $0.temporaryDataUsage() }
    }

    /// Removes temporary data left behind by operations that are no longer
    /// running — the recovery path run when the Export Center appears.
    ///
    /// The cleanup is age-based, so an operation running right now is never a
    /// candidate: its working directory is younger than the retention
    /// interval.
    @discardableResult
    func recoverTemporaryData() -> TemporaryStorageCleanup {
        guard let temporaryData else { return .none }
        return (try? temporaryData.removeTemporaryData(
            olderThan: StorageCleanupPolicy.temporaryDataCutoff(now: now())
        )) ?? .none
    }
}
