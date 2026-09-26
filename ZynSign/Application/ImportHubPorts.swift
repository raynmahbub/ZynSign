import Foundation

// The platform capabilities the Import Hub depends on, beyond the one-shot
// intake. Each is implemented in the platform layer and chosen by the
// composition root; the hub itself never touches the filesystem, UIKit, or
// the system's background-task API directly.

/// The intake's working-copy area, as the Import Hub needs it.
protocol ImportStagingArea: AnyObject {

    /// Extracts one package from an archive whose working copy is already
    /// staged as `container`, into a new working copy named `artifact`.
    ///
    /// The entry is streamed, bounded by the sizes the archive declares,
    /// and verified against the archive's checksum. Nothing partial
    /// survives a failure or a cancellation.
    func stageArchiveEntry(
        _ candidate: NestedPackageCandidate,
        from container: ArtifactIdentifier,
        as artifact: ArtifactIdentifier,
        reporting progress: (any ImportProgressReporting)?
    ) throws

    /// The size of the working copy staged as `artifact`, or `nil` when
    /// there is none.
    func stagedByteCount(for artifact: ArtifactIdentifier) -> Int?

    /// Removes every working copy except `artifacts` — the leftovers of a
    /// previous run that nothing will resume.
    func sweepStagedDocuments(keeping artifacts: Set<ArtifactIdentifier>)
}

/// Reports the free space available for working copies.
protocol StorageCapacityProbe: Sendable {

    /// The free space, in bytes, for storage the user asked for, or `nil`
    /// when the platform cannot say.
    func availableCapacity() -> Int?
}

/// A span of extra execution time requested from the system.
struct ImportBackgroundActivity: Hashable, Sendable {
    let rawValue: Int
}

/// Asks the system to let running imports finish after ZynSign leaves the
/// foreground.
///
/// This is the *only* background execution the Import Hub uses, and it is
/// finite: the system grants a short, unspecified amount of time and may
/// grant none. When the time runs out the hub pauses, keeps its working
/// copies, and resumes when ZynSign is active again. Nothing here keeps
/// importing while ZynSign is suspended or closed, and the interface never
/// says otherwise.
@MainActor
protocol ImportBackgroundExecution: AnyObject {

    /// Begins a span of extra execution time. `expiration` is called on the
    /// main actor if the system is about to end it.
    func beginBackgroundWork(expiration: @escaping @MainActor () -> Void) -> ImportBackgroundActivity?

    /// Ends a span of extra execution time.
    func endBackgroundWork(_ activity: ImportBackgroundActivity)
}

/// Keeps the lightweight import history.
protocol ImportHistoryStore: Sendable {

    /// Every entry, newest first.
    func allEntries() async throws -> [ImportHistoryEntry]

    /// Records an entry, replacing any entry with the same identifier —
    /// a batch that is retried is recorded again when it finishes again.
    func record(_ entry: ImportHistoryEntry) async throws

    /// Removes one entry.
    func remove(entryWithID id: ImportBatchIdentifier) async throws

    /// Removes every entry.
    func clear() async throws
}

/// One unfinished Import Hub item, as the interrupted-import journal keeps
/// it.
///
/// The journal never stores a file location, a bookmark, or a security
/// scope: an interrupted import can resume only from ZynSign's own working
/// copy. When that copy did not survive, the user is told to add the file
/// again.
struct ImportRecoveryRecord: Equatable, Hashable, Sendable, Codable {

    let itemID: UUID
    let batchID: UUID
    let fileName: String
    let origin: ImportOrigin
    let enqueuedAt: Date

    /// The item's working copy, once one exists.
    let stagedArtifactID: String?

    /// The archive a package was extracted from, for display.
    let containerFileName: String?
}

/// Keeps the interrupted-import journal.
protocol ImportRecoveryJournal: Sendable {

    /// The items that were unfinished when the journal was last written.
    func pendingRecords() async throws -> [ImportRecoveryRecord]

    /// Replaces the journal's content with `records`.
    func replace(with records: [ImportRecoveryRecord]) async throws
}

/// What receiving a drop produced.
struct DroppedFileReception: Equatable, Sendable {

    /// ZynSign-owned copies of the dropped files, ready to import.
    let urls: [URL]

    /// How many dropped items could not be received as files.
    let failedCount: Int
}

/// Receives files dropped onto ZynSign.
///
/// A dragged file is only readable while the drop is being handled, so the
/// receiver copies it into a ZynSign-owned inbox first. The inbox copies are
/// ZynSign's, not the user's: they are released once imported, and swept at
/// the next launch. The dragged original is never modified.
protocol DroppedFileReceiving: AnyObject, Sendable {

    /// Copies the files behind `providers` into the inbox.
    func receive(_ providers: [NSItemProvider]) async -> DroppedFileReception

    /// Removes an inbox copy. URLs outside the inbox are never touched.
    func release(_ url: URL)

    /// Removes every inbox copy.
    func sweep()
}
