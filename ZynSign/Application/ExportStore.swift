import Foundation

/// The persistence boundary for the Export Center's records.
///
/// Records describe exported artifacts; they never hold bytes, and the
/// storage that holds the bytes is a separate port. The port is deliberately
/// small — list, append, replace, remove — because the Export Center's own use
/// case owns the ordering and the lifecycle rules, and persistence only has to
/// keep values across launches.
///
/// A record is keyed on its own identifier alone. Writing a record whose
/// identifier is already stored replaces it, so verification results and
/// delivery times update in place rather than accumulating history entries
/// that describe the same artifact.
protocol ExportRecordStore: Sendable {

    /// Every stored record, in the order it is stored (most recent first).
    func allRecords() async throws -> [ExportRecord]

    /// Stores `record`, replacing any stored record with the same identifier.
    func write(_ record: ExportRecord) async throws

    /// Removes the record with `id`. No-op when no such record exists.
    func remove(recordWithID id: ExportIdentifier) async throws

    /// Removes every stored record. Used by the storage screen's cleanup,
    /// which has already confirmed the deletion with the user.
    func clear() async throws
}

/// The size and content fingerprint of one staged artifact, measured from its
/// bytes.
///
/// The measurement streams the file once in bounded chunks. The fingerprint
/// identifies bytes and nothing else: it is not a signature and confers no
/// trust.
struct StagedExportMeasurement: Equatable, Sendable {

    /// The file's size in bytes, as counted while measuring.
    let byteCount: Int

    /// The file's SHA-256 content fingerprint.
    let fingerprint: ArtifactFingerprint
}

/// What a temporary-data cleanup removed.
struct TemporaryStorageCleanup: Equatable, Sendable {

    /// How many files were removed.
    let removedFileCount: Int

    /// How many bytes were freed.
    let freedByteCount: Int

    /// How many entries were left alone because they are still in use, are
    /// not ZynSign's, or are younger than the retention interval.
    let skippedItemCount: Int

    static let none = TemporaryStorageCleanup(removedFileCount: 0, freedByteCount: 0, skippedItemCount: 0)
}

/// The boundary through which ZynSign owns the signed artifacts it produced.
///
/// This port is the export counterpart of `LibraryArtifactStore`, and the two
/// are deliberately separate: an exported artifact is not a library artifact,
/// it lives in its own directory under its own predictable name, and removing
/// one never reaches the other. The lifecycle it supports:
///
/// - **Measure** a staged artifact: its size and SHA-256 fingerprint, read in
///   bounded chunks without holding the file in memory.
/// - **Commit** a staged artifact under its chosen name. The name is
///   predictable, chosen by `ExportNamingPolicy`; an existing file is
///   refused, never overwritten, so a stale name can never destroy bytes.
/// - **Observe** an artifact: whether export storage holds it and how large it
///   is. Observation never creates, repairs, or replaces anything.
/// - **Remove** an artifact. Idempotent, and confined to export storage.
/// - **Clean** temporary data left behind by operations that finished or were
///   interrupted, leaving anything an operation still owns alone.
/// - **Enumerate** the file names export storage holds, so a name can be
///   chosen that nothing uses.
///
/// Every file name this port writes is either an identifier ZynSign minted or
/// a name the naming policy derived from declarations; no user-selected
/// document's name reaches the file system through it, and no stored name is
/// trusted as a path.
protocol ExportArtifactStore: Sendable {

    /// The directory exported artifacts are kept in.
    var exportsDirectory: URL { get }

    /// The file names export storage currently holds, for collision-free
    /// naming. Names that are not this store's own convention are not
    /// reported: a file this store did not write is left out of naming rather
    /// than treated as one of its artifacts.
    func heldFileNames() throws -> Set<String>

    /// The location the artifact with `fileName` occupies, or would occupy.
    /// Throws when `fileName` is not a name this store may hold: a stored
    /// name is data, never a path.
    func artifactLocation(forFileName fileName: String) throws -> URL

    /// Measures the staged file at `location`: its size and content
    /// fingerprint, read in bounded chunks.
    func measure(_ location: URL) throws -> StagedExportMeasurement

    /// Moves a staged file into export storage under `fileName`.
    ///
    /// - Returns: The artifact's location in export storage.
    /// - Throws: A typed error when `fileName` is unsafe, when a file already
    ///   occupies the name — which is never overwritten — or when the move
    ///   fails.
    @discardableResult
    func commit(_ location: URL, as fileName: String) throws -> URL

    /// What export storage currently holds under `fileName`.
    func observeArtifact(named fileName: String) -> StoredExportObservation

    /// Removes the artifact named `fileName` from export storage.
    ///
    /// - Returns: The bytes freed; zero when nothing was held.
    @discardableResult
    func removeArtifact(named fileName: String) throws -> Int

}

/// The boundary through which ZynSign removes the temporary data its
/// operations leave behind.
///
/// Temporary storage holds staging copies, extracted working copies, and the
/// containers operations were still writing when they were interrupted.
/// Cleanup is age-based on purpose: anything younger than the retention
/// interval may belong to an operation that is running right now, so it is
/// left alone and counted as skipped rather than removed. Only names ZynSign
/// recognises are candidates at all — the cleaner never removes an entry it
/// cannot attribute to ZynSign's own work.
protocol TemporaryDataCleaning: Sendable {

    /// Removes temporary data older than `olderThan`.
    func removeTemporaryData(olderThan: Date) throws -> TemporaryStorageCleanup

    /// How much temporary storage currently holds, and how many files that is.
    func temporaryDataUsage() throws -> (byteCount: Int, fileCount: Int)
}

/// Whether the device can hold a signing operation's working data.
///
/// The probe is a port because free space is a platform fact: the
/// implementation reads the volume's own accounting, and a test supplies a
/// number. A probe that cannot measure reports `nil`, and a run then proceeds
/// rather than refusing on a guess — an unmeasurable device is not evidence of
/// insufficient space.
protocol StorageCapacityProbing: Sendable {

    /// The bytes available for ZynSign's own storage, or `nil` when the
    /// platform cannot report it.
    func availableByteCount() throws -> Int?
}

/// The boundary through which the storage screen reads what ZynSign is using.
///
/// The footprint is measured from the storage that holds the bytes, in the
/// categories `StorageFootprint` names. The only category the implementation
/// must never include in a cleanup is imported applications — and this port
/// only reports: removal is requested through the ports that own each kind of
/// storage, so no reporting path can delete anything.
protocol StorageFootprintReporting: Sendable {

    /// Measures every category.
    func footprint() throws -> StorageFootprint
}
