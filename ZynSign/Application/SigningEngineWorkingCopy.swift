import Foundation

/// What the original container looked like when a signing run read it.
///
/// The fingerprint exists so the run can *establish* that the original it
/// imported was not modified: the same values are re-measured after the run,
/// and a difference is reported rather than assumed away. The digest is
/// SHA-256 of the container's exact bytes; the modification date is recorded
/// as the file system reported it and is never written back.
struct SigningSourceFingerprint: Equatable, Sendable {

    /// The container's size in bytes.
    let byteCount: Int

    /// The container's SHA-256 digest, as lowercase hexadecimal text.
    let digestHex: String

    /// The container's modification date, as observed.
    let modificationDate: Date?

    /// Measures one container.
    ///
    /// - Throws: A typed `ZynSignError` when the container cannot be read; the
    ///   caller reports that as an unavailable input rather than as a signing
    ///   failure.
    init(containerURL: URL, digest: any MessageDigest, fileManager: FileManager = .default) throws {
        let bytes: Data
        do {
            bytes = try Data(contentsOf: containerURL, options: .mappedIfSafe)
        } catch {
            throw ZynSignError.artifactNotAvailable(
                diagnosticDetail: "The source container could not be read for fingerprinting.",
                underlyingError: error
            )
        }
        let measured = try digest.digest(bytes, algorithm: .sha256)
        self.byteCount = bytes.count
        self.digestHex = measured.hexString
        self.modificationDate = (try? fileManager.attributesOfItem(atPath: containerURL.path))?[.modificationDate] as? Date
    }

    /// Whether two fingerprints describe the same container.
    func matches(_ other: SigningSourceFingerprint) -> Bool {
        byteCount == other.byteCount && digestHex == other.digestHex
    }
}

/// What discarding a working copy reclaimed.
struct SigningWorkingCopyReport: Equatable, Sendable {

    /// Whether the working copy's own directory was removed.
    let discarded: Bool

    /// How many files and directories were removed with it.
    let reclaimedItemCount: Int

    /// How many bytes of working-copy content were removed.
    let reclaimedByteCount: Int

    /// Whether the original container was re-measured after the run and found
    /// byte-identical to what the run read.
    let originalUnchanged: Bool
}

/// The isolated working copy one signing run performs all of its writes in.
///
/// The original container is read-only for the whole run: it is never
/// extracted into place, never written beside, and never renamed. Everything
/// the run modifies happens under this copy's own directory, which is named
/// with a fresh UUID under the caller's root (the system temporary directory
/// by default) and removed when the run ends, whether it succeeded or failed.
///
/// The working copy also owns the evidence that the original survived: the
/// fingerprint taken when the copy was created, and the re-measurement that
/// produces `SigningWorkingCopyReport.originalUnchanged`.
struct SigningWorkingCopy {

    /// The directory the whole run owns. Removed by `discard()`.
    let root: URL

    /// The directory the container is extracted into.
    let workDirectory: URL

    /// The original container, read but never modified.
    let sourceURL: URL

    /// The original's fingerprint, measured when the copy was created.
    let sourceFingerprint: SigningSourceFingerprint

    private let digest: any MessageDigest
    private let fileManager: FileManager

    /// Creates an isolated working copy for one container.
    ///
    /// - Parameters:
    ///   - sourceURL: The container the run signs. Read-only to the run.
    ///   - digest: The digest mechanism used to fingerprint the original.
    ///   - rootDirectory: Where the copy's own directory is created; the
    ///     system temporary directory by default.
    ///   - fileManager: The file manager used for every filesystem operation.
    /// - Throws: A typed `ZynSignError` when the copy cannot be created. The
    ///   original container is not touched on any path.
    init(
        sourceURL: URL,
        digest: any MessageDigest,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let root = (rootDirectory ?? fileManager.temporaryDirectory)
            .appendingPathComponent("ZynSignSigning-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        do {
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw ZynSignError.artifactStorageFailure(
                diagnosticDetail: "The signing working copy could not be created.",
                underlyingError: error
            )
        }
        self.root = root
        self.workDirectory = work
        self.sourceURL = sourceURL
        self.digest = digest
        self.fileManager = fileManager
        do {
            self.sourceFingerprint = try SigningSourceFingerprint(
                containerURL: sourceURL,
                digest: digest,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    /// Re-measures the original container.
    ///
    /// - Returns: The fingerprint as it is now, or `nil` when the container
    ///   can no longer be read — a state the caller reports honestly rather
    ///   than reading as "unchanged".
    func measureSource() -> SigningSourceFingerprint? {
        try? SigningSourceFingerprint(containerURL: sourceURL, digest: digest, fileManager: fileManager)
    }

    /// Whether the original container is byte-identical to what the run read.
    func isSourceUnchanged() -> Bool {
        guard let current = measureSource() else { return false }
        return sourceFingerprint.matches(current)
    }

    /// Removes the working copy and reports what was reclaimed, together with
    /// the original's preservation evidence.
    ///
    /// Discarding is idempotent: a directory that is already gone reports a
    /// successful discard with nothing reclaimed. The original's fingerprint
    /// is measured before the copy is removed, so the evidence describes the
    /// state the run left behind.
    func discard() -> SigningWorkingCopyReport {
        let originalUnchanged = isSourceUnchanged()
        var itemCount = 0
        var byteCount = 0
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) {
            for case let url as URL in enumerator {
                itemCount += 1
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory != true {
                    byteCount += values?.fileSize ?? 0
                }
            }
        }
        let discarded: Bool
        do {
            if fileManager.fileExists(atPath: root.path) {
                try fileManager.removeItem(at: root)
            }
            discarded = !fileManager.fileExists(atPath: root.path)
        } catch {
            discarded = false
        }
        return SigningWorkingCopyReport(
            discarded: discarded,
            reclaimedItemCount: discarded ? itemCount : 0,
            reclaimedByteCount: discarded ? byteCount : 0,
            originalUnchanged: originalUnchanged
        )
    }

    /// A path inside the working copy's root, for run-owned scratch content.
    func scratchURL(named name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: false)
    }
}
