import Foundation

/// The platform implementation of `ArtifactIntake`.
///
/// This type owns every platform concern the import flow depends on:
///
/// - **Security-scoped access.** Access to the selected document is acquired
///   immediately before it is read and released as soon as staging ends,
///   whatever the outcome. The grant is never held across operations, never
///   persisted, and never leaves this type. A document that needs no scope
///   is handled identically, because the platform reports the grant as not
///   required.
/// - **Selection triage.** The selected location must exist and must be a
///   regular file. The file-type policy was applied before staging; this
///   check is about what the provider actually produced, not about names.
/// - **Staging.** The document is copied in bounded chunks — the whole file
///   is never held in memory — into a unique application-owned location
///   named only by the artifact's identifier. The identifier is a freshly
///   minted UUID ZynSign generates, so the name is collision-free,
///   unpredictable, and carries nothing the package could influence; no
///   part of a selected document's name or content reaches the file system
///   through this type.
/// - **Cleanup.** A failed or cancelled staging removes the partial copy on
///   its way out. Before the first staging of a process, files left by a
///   previous process are cleared, so nothing large is left in temporary
///   storage indefinitely.
///
/// Staging is transient by design. An accepted package is moved out of the
/// staging directory by the library's artifact store when the library adopts
/// it; every other outcome discards the staged copy. The staging directory
/// therefore never holds anything a record depends on, and clearing it is
/// always safe.
///
/// The staging directory is written only by this type: the composition root
/// binds the archive-reader provider and the library's artifact store to the
/// same directory and the same file-extension convention, so a staged
/// archive is discoverable by the artifact's identifier alone. No domain or
/// application type sees a URL.
///
/// Imports are not concurrent by design — the import use case is the only
/// caller, and the presentation layer serializes imports — so the type is
/// not internally synchronized.
final class SecurityScopedArtifactIntake: ArtifactIntake {

    /// The application-owned directory staged archives are copied into.
    /// Written only by this type and created on first use; the library's
    /// artifact store moves adopted archives out of it.
    let directory: URL

    /// The file extension a staged archive carries. The composition root
    /// binds this to the same convention the archive-reader provider uses to
    /// find an artifact's archive.
    let fileExtension: String

    /// How many bytes one copy step moves. Bounded so that staging never
    /// holds more than a chunk of the package in memory, whatever its size.
    let copyChunkSize: Int

    /// Whether the stale-import clear has already run in this process.
    private var hasClearedStaleImports = false

    /// Creates an intake over `directory`, which need not exist yet.
    init(
        directory: URL,
        fileExtension: String = "ipa",
        copyChunkSize: Int = 1_048_576
    ) {
        self.directory = directory
        self.fileExtension = fileExtension
        self.copyChunkSize = max(1, copyChunkSize)
    }

    // MARK: - ArtifactIntake

    func stageDocument(at source: URL, as artifact: ArtifactIdentifier) throws {
        if Task.isCancelled {
            throw ZynSignError.importCancelled()
        }
        clearStaleImportsIfNeeded()

        let destination = location(for: artifact)
        // Fresh identifiers never collide, but a stale file must never be
        // appended to, so the destination starts empty.
        try? FileManager.default.removeItem(at: destination)

        let scopeAcquired = source.startAccessingSecurityScopedResource()
        defer {
            if scopeAcquired {
                source.stopAccessingSecurityScopedResource()
            }
        }

        try verifySelectedDocument(source)
        try prepareDirectory()
        do {
            try streamCopy(from: source, to: destination)
        } catch {
            // Nothing partial survives a failed or cancelled staging.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func discardStagedDocument(for artifact: ArtifactIdentifier) {
        try? FileManager.default.removeItem(at: location(for: artifact))
    }

    // MARK: - Selection triage

    /// Checks what the file provider actually produced before anything is
    /// read: the location must exist and must not be a directory. Read
    /// failures and access refusals are mapped where they occur, during the
    /// copy itself.
    private func verifySelectedDocument(_ source: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw ZynSignError.selectedFileUnavailable(
                diagnosticDetail: "The selected document no longer exists."
            )
        }
        guard !isDirectory.boolValue else {
            throw ZynSignError.unsupportedImportFile(
                diagnosticDetail: "The selected document is a directory, not a regular file."
            )
        }
    }

    // MARK: - Staging

    private func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ZynSignError.importTemporaryStorageFailure(underlyingError: error)
        }
    }

    /// Copies the document to `destination` in bounded chunks.
    ///
    /// Cancellation is checked on every chunk, so a cancelled import stops
    /// early instead of finishing a copy nobody asked for. Read and write
    /// failures are mapped onto typed errors whose rendering is free of the
    /// selected document's location.
    private func streamCopy(from source: URL, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ZynSignError.importTemporaryStorageFailure(
                diagnosticDetail: "The staged archive could not be created."
            )
        }

        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: source)
        } catch {
            throw Self.mapOpenFailure(error)
        }
        defer { try? reader.close() }

        let writer: FileHandle
        do {
            writer = try FileHandle(forWritingTo: destination)
        } catch {
            throw ZynSignError.importTemporaryStorageFailure(underlyingError: error)
        }
        defer { try? writer.close() }

        do {
            while true {
                if Task.isCancelled {
                    throw ZynSignError.importCancelled()
                }
                guard let chunk = try reader.read(upToCount: copyChunkSize) else { break }
                if chunk.isEmpty { break }
                try writer.write(contentsOf: chunk)
            }
        } catch let zynSignError as ZynSignError {
            throw zynSignError
        } catch {
            throw ZynSignError.importCopyFailure(underlyingError: error)
        }
    }

    /// Maps a failure to open the selected document onto the honest
    /// distinction between "gone", "refused", and "could not be read".
    private static func mapOpenFailure(_ error: any Error) -> ZynSignError {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain {
            switch Int32(failure.code) {
            case ENOENT:
                return ZynSignError.selectedFileUnavailable(underlyingError: error)
            case EACCES, EPERM:
                return ZynSignError.selectedFileAccessDenied(underlyingError: error)
            default:
                break
            }
        }
        return ZynSignError.importCopyFailure(underlyingError: error)
    }

    // MARK: - Leftover lifecycle

    /// Clears, once per process, everything a previous process left in the
    /// staging directory. Staged archives are session-scoped: an accepted
    /// package is moved out of staging when the library adopts it and every
    /// other outcome discards the staged copy, so any pre-existing file is a
    /// leftover whose owner is gone and which no record refers to. Failure
    /// to clear is not allowed to block an import — the destination is
    /// emptied regardless — and nothing here runs automatically at launch.
    private func clearStaleImportsIfNeeded() {
        guard !hasClearedStaleImports else { return }
        hasClearedStaleImports = true

        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for leftover in leftovers {
            try? FileManager.default.removeItem(at: leftover)
        }
    }

    /// Resolves where an artifact's staged archive is kept.
    ///
    /// The file name is the artifact's own identifier — an opaque, freshly
    /// minted value ZynSign generates and never derives from package
    /// content — carrying the staged-archive extension. This mirrors the
    /// archive storage convention of `DirectoryArtifactArchiveReaderProvider`
    /// and `FileLibraryArtifactStore`; the composition root binds all three
    /// to the same directory and extension.
    private func location(for artifact: ArtifactIdentifier) -> URL {
        directory
            .appendingPathComponent(artifact.rawValue, isDirectory: false)
            .appendingPathExtension(fileExtension)
    }
}
