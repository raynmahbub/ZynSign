import Foundation

/// What one export removal did.
struct ExportRemoval: Equatable, Sendable {

    /// The record that was removed.
    let identifier: ExportIdentifier

    /// The file name the artifact carried.
    let fileName: String

    /// The bytes freed by removing the artifact; zero when nothing was held.
    let freedByteCount: Int
}

/// The export use case: it owns the relationship between export records and
/// the artifacts those records describe.
///
/// The center composes two ports and owns the rules between them. `records`
/// holds what persistence keeps; `artifacts` holds the bytes. Neither port
/// knows about the other, and nothing below this type sequences the two.
///
/// **Availability.** Listing derives each record's availability from export
/// storage at the time of the call. A record whose artifact is missing or was
/// changed is listed as such, with its metadata intact: it is never repaired,
/// recreated, or reported as available, and it is never silently removed. The
/// file URL an entry carries is present exactly when the artifact is
/// available, so a view cannot offer a share action it cannot honour.
///
/// **Removal order.** Removing an export removes the artifact first and the
/// record second — deliberately the opposite of the library's order. A record
/// whose artifact is missing is a supported, visible state here, so an
/// interruption leaves a listed entry marked unavailable rather than a file
/// nothing describes.
///
/// **Scope.** Nothing here can reach a library artifact. The only storage this
/// type removes from is export storage, addressed by the file name the record
/// holds, so deleting signed output can never delete the application it was
/// signed from.
///
/// The center is an actor so that naming, recording, and removal see one
/// consistent view of the catalog while several operations — a signing run, a
/// verification, a cleanup — run concurrently.
actor ExportCenter {

    private let records: any ExportRecordStore
    private let artifacts: any ExportArtifactStore
    private let now: @Sendable () -> Date

    init(
        records: any ExportRecordStore,
        artifacts: any ExportArtifactStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.records = records
        self.artifacts = artifacts
        self.now = now
    }

    // MARK: - Listing

    /// Every export, most recent first, each with its artifact's current
    /// availability.
    func entries() async throws -> [ExportEntry] {
        let stored = try await records.allRecords()
        return stored
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.rawValue < rhs.id.rawValue
            }
            .map(entry(for:))
    }

    /// One export, with its artifact's current availability.
    func entry(withID id: ExportIdentifier) async throws -> ExportEntry? {
        guard let record = try await records.allRecords().first(where: { $0.id == id }) else {
            return nil
        }
        return entry(for: record)
    }

    /// The entry for an export identifier that was stored as text — used to
    /// link a signing-history record to the artifact it produced. Returns
    /// `nil` for an absent or unparseable identifier, and for an export whose
    /// record was removed by cleanup: a removed artifact is reported as
    /// absent, never as an error.
    func entry(forStoredIdentifier raw: String?) async -> ExportEntry? {
        guard let raw, !raw.isEmpty else { return nil }
        return try? await entry(withID: ExportIdentifier(rawValue: raw))
    }

    /// Derives one record's entry: its availability and, when the artifact is
    /// held, its location.
    func entry(for record: ExportRecord) -> ExportEntry {
        let observation = artifacts.observeArtifact(named: record.fileName)
        let availability = ExportAvailability.derive(
            from: observation,
            recordedByteCount: record.byteCount
        )
        let fileURL = availability.isAvailable ? try? artifacts.artifactLocation(forFileName: record.fileName) : nil
        return ExportEntry(record: record, availability: availability, fileURL: fileURL)
    }

    /// The location of an export's artifact, for the system share sheet and
    /// for "reveal". Throws when the artifact is not held.
    func fileURL(for record: ExportRecord) throws -> URL {
        guard artifacts.observeArtifact(named: record.fileName).isPresent else {
            throw ZynSignError.exportArtifactUnavailable(
                diagnosticDetail: "Export storage holds no artifact for export '\(record.id.rawValue)'."
            )
        }
        return try artifacts.artifactLocation(forFileName: record.fileName)
    }

    // MARK: - Recording

    /// Stores a new export, or replaces the stored record with the same
    /// identifier.
    func write(_ record: ExportRecord) async throws {
        try await records.write(record)
    }

    /// Rolls back a committed artifact when its durable record cannot be
    /// written. This keeps export storage transactional from the caller's
    /// perspective: an artifact is never left behind without a record that
    /// describes it.
    func rollbackCommittedArtifact(fileName: String) async throws {
        _ = try artifacts.removeArtifact(named: fileName)
    }

    /// Removes a record during rollback of a partially completed export.
    func removeRecord(_ id: ExportIdentifier) async throws {
        try await records.remove(recordWithID: id)
    }

    /// Records what independent verification concluded about one export.
    ///
    /// - Returns: The updated record.
    /// - Throws: A typed error when no record carries the identifier, so a
    ///   verification result is never stored for an artifact nothing
    ///   describes.
    @discardableResult
    func recordVerification(_ report: ArtifactVerificationReport, for id: ExportIdentifier) async throws -> ExportRecord {
        guard let existing = try await records.allRecords().first(where: { $0.id == id }) else {
            throw ZynSignError.exportRecordNotFound(
                diagnosticDetail: "No export record carries identifier '\(id.rawValue)'."
            )
        }
        let updated = existing.recordingVerification(report)
        try await records.write(updated)
        return updated
    }

    /// Records that the artifact was shared, saved, or opened out of ZynSign.
    ///
    /// - Returns: The updated record.
    /// - Throws: A typed error when no record carries the identifier.
    @discardableResult
    func recordDelivery(for id: ExportIdentifier, at instant: Date? = nil) async throws -> ExportRecord {
        guard let existing = try await records.allRecords().first(where: { $0.id == id }) else {
            throw ZynSignError.exportRecordNotFound(
                diagnosticDetail: "No export record carries identifier '\(id.rawValue)'."
            )
        }
        let updated = existing.recordingDelivery(at: instant ?? now())
        try await records.write(updated)
        return updated
    }

    // MARK: - Measuring

    /// Measures a staged artifact: its size and content fingerprint, read in
    /// bounded chunks without holding the file in memory.
    func measure(_ location: URL) throws -> StagedExportMeasurement {
        try artifacts.measure(location)
    }

    // MARK: - Naming

    /// An unused file name for `base`, derived by the naming policy from the
    /// names export storage currently holds.
    func fileName(forBase base: String) throws -> String {
        ExportNamingPolicy.fileName(base: base, existing: try artifacts.heldFileNames())
    }

    /// The names export storage currently holds.
    func heldFileNames() throws -> Set<String> {
        try artifacts.heldFileNames()
    }

    /// The location a name occupies, or would occupy.
    func artifactLocation(forFileName fileName: String) throws -> URL {
        try artifacts.artifactLocation(forFileName: fileName)
    }

    /// Moves a measured artifact into export storage.
    ///
    /// Naming is resolved here, against the names storage holds at this
    /// instant, and storage refuses to overwrite regardless: a name that
    /// appeared in between produces a typed error rather than a lost file, and
    /// the caller retries with the next candidate.
    @discardableResult
    func commit(_ location: URL, base: String) throws -> (fileName: String, url: URL) {
        let fileName = ExportNamingPolicy.fileName(base: base, existing: try artifacts.heldFileNames())
        let url = try artifacts.commit(location, as: fileName)
        return (fileName, url)
    }

    // MARK: - Removal

    /// Removes one export: its artifact first, then the record that describes
    /// it. The library's artifacts, the signing history, and every other
    /// export are untouched.
    @discardableResult
    func remove(_ id: ExportIdentifier) async throws -> ExportRemoval {
        guard let record = try await records.allRecords().first(where: { $0.id == id }) else {
            throw ZynSignError.exportRecordNotFound(
                diagnosticDetail: "No export record carries identifier '\(id.rawValue)'."
            )
        }
        let freed = (try? artifacts.removeArtifact(named: record.fileName)) ?? 0
        try await records.remove(recordWithID: id)
        return ExportRemoval(identifier: id, fileName: record.fileName, freedByteCount: freed)
    }

    /// Removes every exported artifact and the records that describe them.
    ///
    /// This is what the storage screen's "Remove Exported Artifacts" action
    /// runs after its confirmation. Imported applications are not touched, and
    /// neither is the signing history: the history records stay, and the
    /// detail screen reads the artifact as no longer held rather than
    /// pretending it is there.
    func removeAllArtifacts() async throws -> StorageCleanupReport {
        let stored = try await records.allRecords()
        var removedArtifacts = 0
        var freed = 0
        var skipped = 0
        for record in stored {
            do {
                let bytes = try artifacts.removeArtifact(named: record.fileName)
                try await records.remove(recordWithID: record.id)
                removedArtifacts += 1
                freed += bytes
            } catch {
                skipped += 1
            }
        }
        return StorageCleanupReport(
            kind: .exportedArtifacts,
            removedArtifactCount: removedArtifacts,
            freedByteCount: freed,
            skippedItemCount: skipped
        )
    }

}

private extension StoredExportObservation {

    /// Whether a regular file is held.
    var isPresent: Bool {
        if case .present = self { return true }
        return false
    }
}
