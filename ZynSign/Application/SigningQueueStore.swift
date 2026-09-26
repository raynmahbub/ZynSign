import Foundation

/// The persistence boundary for the signing queue.
///
/// The store keeps the queue's snapshot and its queue-owned profile copies
/// across launches, and recovers the temporary state an interruption left
/// behind. It is the seam behind which the storage technology lives:
/// callers see snapshot values and typed errors, never a file or a
/// directory context. The port is deliberately small — load, save, and the
/// profile-copy lifecycle — and is not a general query abstraction.
///
/// The store never decides what a snapshot *means*: whether a waiting job
/// can run again, whether a running job is an interrupted failure, and
/// which profile copies are orphaned are the queue's and the recovery
/// call's questions, answered from the snapshot's own content.
protocol SigningQueueStore: Sendable {

    /// Reads the persisted snapshot, or `nil` when none exists. A snapshot
    /// this build cannot interpret throws rather than being discarded
    /// silently; the queue treats the throw as "start empty" and reports
    /// the degradation.
    func load() async throws -> SigningQueueSnapshot?

    /// Writes the snapshot. The store refuses a snapshot whose revision is
    /// older than the one it holds, so out-of-order saves cannot resurrect
    /// stale queue state.
    func save(_ snapshot: SigningQueueSnapshot) async throws

    /// Stores a job's profile copy and returns the file name it is held
    /// under. The copy lives beside the snapshot, private to the
    /// application container, and is removed when the job is removed or
    /// when recovery finds it orphaned.
    func storeProfile(_ data: Data, jobID: SigningJobIdentifier) async throws -> String

    /// Reads back a profile copy by the file name `storeProfile` returned,
    /// or `nil` when the copy is gone.
    func loadProfile(fileName: String) async throws -> Data?

    /// Removes a profile copy. No-op when no such copy exists.
    func removeProfile(fileName: String) async throws

    /// Recovers the temporary state an interruption left behind: profile
    /// copies not referenced by `referencedProfileFileNames` are removed,
    /// and stale per-run working directories under the store's working
    /// root are swept. Called once, during restoration, before any job
    /// runs — no live run can exist at that point.
    func recoverWorkspace(referencedProfileFileNames: Set<String>) async throws
}
