import Foundation

/// The library use case: it turns accepted imports into durable records,
/// lists what the library holds, and removes entries.
///
/// The library composes two ports and owns the relationship between them.
/// `ApplicationRecordStore` holds records; `LibraryArtifactStore` holds the
/// bytes records refer to. Neither port knows about the other, and nothing
/// below this type sequences the two. The rules the library enforces:
///
/// **Admission.** An accepted import is described (size and fingerprint),
/// evaluated against the existing records by the duplicate policy, and then
/// either recognised as content the library already holds — in which case
/// nothing is created and nothing moves — or adopted into artifact storage
/// and recorded. The order is artifact first, record second: a record is
/// never written for bytes the library does not hold. Only records whose
/// artifacts are available count as holding content, so a record whose
/// artifact went missing never blocks the same bytes from being imported
/// again; it stays listed as missing until it is removed.
///
/// **Consistency on failure.** If the record cannot be written after the
/// artifact was adopted, the adopted artifact is removed again, so a failed
/// admission leaves neither a record nor an artifact behind. This is a
/// cleanup step, not a transaction: the two stores are independent, and no
/// transactional guarantee across them is claimed. Should the cleanup itself
/// fail, or the process end between the two steps, the artifact is left
/// without a record — an *orphan* — which `orphanedArtifacts()` detects and
/// `removeOrphanedArtifacts()` clears on request. Orphans are never removed
/// implicitly.
///
/// **Removal.** Removing an entry deletes the record first and then the
/// artifact, so an interruption can leave an orphaned artifact but never a
/// record pointing at bytes the library has already discarded.
///
/// **Missing artifacts.** Listing derives each record's artifact
/// availability from storage at the time of the call. A record whose
/// artifact is missing or inconsistent is listed as such, with its metadata
/// intact; it is not repaired, recreated, or reported as available.
///
/// The library is an actor so that admission, removal, and orphan handling
/// are serialised and the in-flight adoption set is never shared mutable
/// state. Persistence and file work therefore run on the actor's executor,
/// never on the main actor. Imports themselves are serialised by their
/// caller; two admissions of the same content that overlap in time would
/// each be recorded, since the duplicate check precedes adoption.
actor ApplicationLibrary {

    private let records: any ApplicationRecordStore
    private let artifacts: any LibraryArtifactStore
    private let now: @Sendable () -> Date

    /// Artifacts adopted by an admission whose record has not been written
    /// yet. Excluded from orphan detection so that an admission in progress
    /// cannot be mistaken for a leftover.
    private var adoptionsInProgress: Set<ArtifactIdentifier> = []

    /// Creates the library over the record and artifact stores the
    /// composition root selected. `now` supplies record timestamps and is
    /// injectable for deterministic tests.
    init(
        records: any ApplicationRecordStore,
        artifacts: any LibraryArtifactStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.records = records
        self.artifacts = artifacts
        self.now = now
    }

    // MARK: - Admission

    /// Offers an accepted import to the library.
    ///
    /// The artifact must have passed inspection and must still be staged;
    /// the staged archive is described and, unless the library already holds
    /// identical content, adopted. Cancellation is honoured before anything
    /// is committed and not afterwards: once adoption begins, the admission
    /// runs to completion so that storage is never left half-changed by a
    /// cancelled task.
    ///
    /// On `.recorded`, the staged archive has been moved into library
    /// storage. On `.alreadyRecorded`, and on every thrown error, the staged
    /// archive is left for its owner — the import flow — to discard; if an
    /// adopted artifact had to be removed again, the identifier is simply no
    /// longer held anywhere, and discarding it is a no-op.
    func admit(_ artifact: IPAArtifact) async throws -> LibraryAdmission {
        try Task.checkCancellation()

        guard artifact.permitsLaterStages, let metadata = artifact.metadata else {
            throw ZynSignError.unrecordableArtifact(
                diagnosticDetail: "Artifact '\(artifact.id.rawValue)' was offered to the library without passing inspection."
            )
        }

        let reference = try artifacts.describeStagedArtifact(artifact.id)
        let existing = try await records.allRecords()

        switch ApplicationRecordDuplicatePolicy.evaluate(
            candidate: reference,
            identity: metadata.identity,
            against: existing,
            holding: { availability(of: $0).isAvailable }
        ) {
        case .identical(let existingRecord):
            return .alreadyRecorded(existing: existingRecord)

        case .distinct(let relation):
            let record = try ApplicationRecord(
                admitting: artifact,
                reference: reference,
                importedAt: now()
            )

            adoptionsInProgress.insert(artifact.id)
            defer { adoptionsInProgress.remove(artifact.id) }

            try artifacts.adoptStagedArtifact(artifact.id)
            do {
                try await records.insert(record)
            } catch {
                // The artifact was adopted but its record could not be
                // written. Remove the artifact again so nothing is left
                // behind; if even that fails, the artifact is an orphan that
                // `orphanedArtifacts()` will report.
                try? artifacts.removeArtifact(artifact.id)
                throw error
            }
            return .recorded(record, relation: relation)
        }
    }

    // MARK: - Reading

    /// Every library entry in library order, each with its artifact's
    /// current availability.
    func entries() async throws -> [LibraryEntry] {
        let stored = try await records.allRecords()
        return stored.map { entry(for: $0) }
    }

    /// The entry for `id`, or `nil` when the library holds no such record.
    func entry(withID id: ApplicationRecordIdentifier) async throws -> LibraryEntry? {
        guard let record = try await records.record(withID: id) else {
            return nil
        }
        return entry(for: record)
    }

    private func entry(for record: ApplicationRecord) -> LibraryEntry {
        LibraryEntry(record: record, artifactAvailability: availability(of: record))
    }

    /// The current availability of a record's artifact, observed from
    /// storage now.
    private func availability(of record: ApplicationRecord) -> ArtifactAvailability {
        ArtifactAvailability.derive(
            from: artifacts.observeArtifact(record.artifact.artifactID),
            expecting: record.artifact
        )
    }

    // MARK: - Favourites

    /// Sets whether the record carrying `id` is marked as a favourite.
    ///
    /// The change touches the record only — never the artifact — and keeps
    /// the import time, so listing by recency is unaffected. Setting the
    /// mark a record already carries does nothing, so repeated requests
    /// cannot churn the change time. Fails with a typed error when no such
    /// record exists.
    func setFavorite(_ isFavorite: Bool, recordWithID id: ApplicationRecordIdentifier) async throws {
        guard let record = try await records.record(withID: id) else {
            throw ZynSignError.libraryRecordNotFound(
                diagnosticDetail: "No library record carries identifier '\(id.rawValue)'."
            )
        }
        guard record.isFavorite != isFavorite else { return }
        try await records.update(record.with(isFavorite: isFavorite, updatedAt: now()))
    }

    // MARK: - Removal

    /// Removes the record carrying `id` and the artifact it refers to.
    ///
    /// The record is deleted first and the artifact second. Fails with a
    /// typed error when no such record exists, or when the artifact could
    /// not be removed after the record was deleted — in which case the
    /// artifact is an orphan and is reported by `orphanedArtifacts()`.
    func remove(recordWithID id: ApplicationRecordIdentifier) async throws {
        guard let record = try await records.record(withID: id) else {
            throw ZynSignError.libraryRecordNotFound(
                diagnosticDetail: "No library record carries identifier '\(id.rawValue)'."
            )
        }
        try await records.delete(recordWithID: id)
        try artifacts.removeArtifact(record.artifact.artifactID)
    }

    // MARK: - Orphaned artifacts

    /// The artifacts library storage holds that no record refers to and no
    /// admission is currently adopting. Detection only; nothing is removed.
    func orphanedArtifacts() async throws -> Set<ArtifactIdentifier> {
        let held = try artifacts.heldArtifactIdentifiers()
        let referenced = Set(try await records.allRecords().map { $0.artifact.artifactID })
        return held.subtracting(referenced).subtracting(adoptionsInProgress)
    }

    /// Removes every orphaned artifact and returns the identifiers removed.
    /// Explicit by design: the library never clears orphans on its own.
    @discardableResult
    func removeOrphanedArtifacts() async throws -> Set<ArtifactIdentifier> {
        let orphans = try await orphanedArtifacts()
        var removed: Set<ArtifactIdentifier> = []
        for orphan in orphans {
            try artifacts.removeArtifact(orphan)
            removed.insert(orphan)
        }
        return removed
    }
}
