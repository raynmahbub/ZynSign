import Foundation

/// The file-backed implementation of `SigningQueueStore`: a versioned
/// snapshot document plus a directory of queue-owned profile copies, inside
/// the user's application container.
///
/// Behaviour mirrors `FileSigningHistoryStore`. The snapshot is replaced
/// atomically on every save, and saves carry a revision the store enforces:
/// a snapshot older than the one on disk is refused, so out-of-order writes
/// from a busy queue can never resurrect stale state. Profile copies are
/// named by their job's identifier, so a copy can never collide with — or
/// be mistaken for — another job's, and recovery can tell an orphan from a
/// reference by name alone.
///
/// Everything here is private to the application container and never leaves
/// the device. The store holds no private key material — identities stay in
/// the Keychain — and the profile copies it holds exist exactly as long as
/// the queue's list says they should: recovery removes every copy the
/// restored queue does not reference.
actor FileSigningQueueStore: SigningQueueStore {

    /// The schema version this build reads and writes.
    static let currentSchemaVersion = 1

    /// The file extension a queue-owned profile copy is held under.
    static let profileFileExtension = "mobileprovision"

    /// The directory holding the snapshot document and the profile copies.
    let queueDirectory: URL

    /// The root of the per-run signing working directories. Swept during
    /// recovery: a working directory that survives a launch belongs to a
    /// dead process, and the pipeline creates a fresh unique directory per
    /// run anyway.
    let workingDirectoryRoot: URL

    /// The highest revision written or read, so a stale save is refused.
    private var knownRevision: Int?

    /// When this store — and therefore this process's queue — came into
    /// being. Recovery removes only working directories created before
    /// this instant: those belong to an earlier process, while anything
    /// newer belongs to a run of this one and is never touched.
    private let sessionStartedAt: Date

    init(queueDirectory: URL, workingDirectoryRoot: URL, sessionStartedAt: Date = Date()) {
        self.queueDirectory = queueDirectory
        self.workingDirectoryRoot = workingDirectoryRoot
        self.sessionStartedAt = sessionStartedAt
    }

    private var snapshotLocation: URL {
        queueDirectory.appendingPathComponent("queue.json", isDirectory: false)
    }

    private var profilesDirectory: URL {
        queueDirectory.appendingPathComponent("Profiles", isDirectory: true)
    }

    // MARK: - Snapshot

    func load() async throws -> SigningQueueSnapshot? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: snapshotLocation.path, isDirectory: &isDirectory) else {
            return nil
        }
        guard !isDirectory.boolValue else {
            throw ZynSignError.signingQueueSnapshotUnreadable(
                diagnosticDetail: "The signing queue location is a directory rather than a file."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: snapshotLocation)
        } catch {
            throw ZynSignError.signingQueueStorageFailure(
                diagnosticDetail: "The signing queue snapshot could not be read.",
                underlyingError: error
            )
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ZynSignError.signingQueueSnapshotUnreadable(
                diagnosticDetail: "The signing queue snapshot is not a document this build recognises.",
                underlyingError: error
            )
        }
        guard envelope.schemaVersion <= Self.currentSchemaVersion else {
            throw ZynSignError.signingQueueSnapshotUnreadable(
                diagnosticDetail: "The signing queue snapshot declares schema version \(envelope.schemaVersion); this build reads up to version \(Self.currentSchemaVersion)."
            )
        }
        // Verify uniqueness of job identifiers within the snapshot.
        var seen = Set<String>()
        for job in envelope.snapshot.jobs {
            guard seen.insert(job.id).inserted else {
                throw ZynSignError.signingQueueSnapshotUnreadable(
                    diagnosticDetail: "The signing queue snapshot lists job '\(job.id)' more than once."
                )
            }
        }
        knownRevision = max(knownRevision ?? 0, envelope.snapshot.revision)
        return envelope.snapshot
    }

    func save(_ snapshot: SigningQueueSnapshot) async throws {
        if let knownRevision, snapshot.revision <= knownRevision {
            // A stale save: the queue has already written a newer snapshot.
            // Refusing is what keeps out-of-order writes from rewinding the
            // persisted queue.
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: queueDirectory,
                withIntermediateDirectories: true
            )
            let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, snapshot: snapshot)
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: snapshotLocation, options: [.atomic])
            knownRevision = snapshot.revision
        } catch {
            throw ZynSignError.signingQueueStorageFailure(
                diagnosticDetail: "The signing queue snapshot could not be written.",
                underlyingError: error
            )
        }
    }

    // MARK: - Profile copies

    func storeProfile(_ data: Data, jobID: SigningJobIdentifier) async throws -> String {
        let fileName = "\(jobID.rawValue).\(Self.profileFileExtension)"
        do {
            try FileManager.default.createDirectory(
                at: profilesDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: profilesDirectory.appendingPathComponent(fileName), options: [.atomic])
        } catch {
            throw ZynSignError.signingQueueStorageFailure(
                diagnosticDetail: "The signing job's profile copy could not be stored.",
                underlyingError: error
            )
        }
        return fileName
    }

    func loadProfile(fileName: String) async throws -> Data? {
        guard let url = confinedProfileURL(fileName: fileName) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ZynSignError.signingQueueStorageFailure(
                diagnosticDetail: "The signing job's profile copy could not be read.",
                underlyingError: error
            )
        }
    }

    func removeProfile(fileName: String) async throws {
        guard let url = confinedProfileURL(fileName: fileName) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone; removal is idempotent.
        } catch {
            throw ZynSignError.signingQueueStorageFailure(
                diagnosticDetail: "The signing job's profile copy could not be removed.",
                underlyingError: error
            )
        }
    }

    // MARK: - Recovery

    func recoverWorkspace(referencedProfileFileNames: Set<String>) async throws {
        let fileManager = FileManager.default

        // Sweep profile copies the restored queue does not reference. Only
        // regular files directly inside the profiles directory are touched;
        // anything unexpected is left for inspection rather than deleted.
        if let profileFiles = try? fileManager.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in profileFiles {
                let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                guard isRegularFile else { continue }
                guard !referencedProfileFileNames.contains(fileURL.lastPathComponent) else { continue }
                try? fileManager.removeItem(at: fileURL)
            }
        }

        // Sweep stale per-run working directories. A working directory
        // created before this session belongs to a dead process — its run
        // can never be resumed, and every new run creates its own fresh
        // directory — so it is removed. Directories created during this
        // session belong to live runs (every signing operation shares the
        // root, queued or not) and are left alone.
        if let runDirectories = try? fileManager.contentsOfDirectory(
            at: workingDirectoryRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: []
        ) {
            for directory in runDirectories {
                let created = (try? directory.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    ?? .distantPast
                guard created < sessionStartedAt else { continue }
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    // MARK: - Helpers

    /// Confines a profile file name to the profiles directory. The names
    /// the store mints are single path components, so anything carrying a
    /// separator or a parent reference is not a name this store produced
    /// and is refused rather than resolved.
    private func confinedProfileURL(fileName: String) -> URL? {
        guard !fileName.isEmpty,
              fileName == (fileName as NSString).lastPathComponent,
              !fileName.contains("..") else {
            return nil
        }
        return profilesDirectory.appendingPathComponent(fileName)
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var snapshot: SigningQueueSnapshot
    }
}
