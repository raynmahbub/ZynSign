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
/// - **Description.** The selected document is examined — reachable, a
///   regular file rather than a directory, its size, and whether it begins
///   the way a ZIP container begins — without copying any of it, so the
///   pre-import checks can refuse a selection before ZynSign spends storage
///   on it. The description is an observation, never a verdict.
/// - **Staging.** The document is copied in bounded chunks — the whole file
///   is never held in memory — into a unique application-owned location
///   named only by the artifact's identifier. The identifier is a freshly
///   minted UUID ZynSign generates, so the name is collision-free,
///   unpredictable, and carries nothing the package could influence; no
///   part of a selected document's name or content reaches the file system
///   through this type.
/// - **Progress.** Each copied chunk is reported through the caller's
///   receiver with the byte count moved so far. Reporting is advisory: it
///   never changes what is written, and a receiver that drops reports
///   changes nothing but what the interface shows.
/// - **Cleanup.** A failed or cancelled staging removes the partial copy on
///   its way out. Files left by a previous process are removed by
///   `sweepStagedDocuments(keeping:)`, which the Import Hub calls once at
///   launch after deciding which interrupted imports can resume from their
///   working copies, so nothing large is left in temporary storage
///   indefinitely and nothing resumable is lost.
/// - **Archive entries.** A package inside a staged ZIP is streamed into its
///   own working copy by `stageArchiveEntry(_:from:as:reporting:)`, under a
///   fresh identifier — never under the name the archive gives it.
///
/// **The selected document is read, never written.** This type opens the
/// source for reading, copies through it, and closes it; it never opens the
/// source for writing, moves it, renames it, changes its attributes, or
/// deletes it. Staging a document twice — or a hundred times — leaves it
/// byte-identical, with its name and timestamps untouched, whatever the
/// outcome of the imports.
///
/// Staging is transient by design. An accepted package is moved out of the
/// staging directory by the library's artifact store when the library adopts
/// it; every other outcome discards the staged copy. The staging directory
/// therefore never holds anything a record depends on; the only thing worth
/// keeping in it is the working copy of an interrupted import, and the
/// sweep is told which those are.
///
/// The staging directory is written only by this type: the composition root
/// binds the archive-reader provider and the library's artifact store to the
/// same directory and the same file-extension convention, so a staged
/// archive is discoverable by the artifact's identifier alone. No domain or
/// application type sees a URL.
///
/// The type holds no mutable state: every operation works on its own
/// uniquely named file, so the Import Hub's concurrent items may share one
/// intake safely.
final class SecurityScopedArtifactIntake: ArtifactIntake, ImportStagingArea {

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

    func describeDocument(at source: URL) throws -> ImportSourceDescription {
        if Task.isCancelled {
            throw ZynSignError.importCancelled()
        }

        let scopeAcquired = source.startAccessingSecurityScopedResource()
        defer {
            if scopeAcquired {
                source.stopAccessingSecurityScopedResource()
            }
        }

        try verifySelectedDocument(source)

        var kind = ImportSourceDescription.Kind.unknown
        var byteCount: Int?
        if let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) {
            if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .regularFile
            }
            byteCount = values.fileSize
        }
        if byteCount == nil, let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
           let size = attributes[.size] as? NSNumber {
            byteCount = size.intValue
        }

        return ImportSourceDescription(
            fileName: source.lastPathComponent,
            byteCount: byteCount,
            kind: kind,
            beginsWithArchiveSignature: archiveSignatureMarker(at: source)
        )
    }

    func stageDocument(
        at source: URL,
        as artifact: ArtifactIdentifier,
        reporting progress: (any ImportProgressReporting)?
    ) throws {
        if Task.isCancelled {
            throw ZynSignError.importCancelled()
        }

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
            try streamCopy(
                from: source,
                to: destination,
                totalByteCount: byteCount(of: source),
                reporting: progress
            )
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
    /// read: the location must be reachable and must not be a directory.
    /// Uses resource-values rather than only `fileExists(atPath:)` so that
    /// coordinated / iCloud / Files-provider URLs that are not simple
    /// POSIX paths are still recognised, and so the check does not swallow
    /// the provider's own error.
    private func verifySelectedDocument(_ source: URL) throws {
        // `checkResourceIsReachable` reports the provider's truth; a plain
        // `fileExists` can return false for a not-yet-downloaded ubiquitous
        // item that the picker still offered.
        if (try? source.checkResourceIsReachable()) == false {
            // Try to trigger a download for ubiquitous items.
            try? FileManager.default.startDownloadingUbiquitousItem(at: source)
            // Re-check after the attempt; if still unreachable, fail with the
            // honest unavailable error rather than falling through to open.
            if (try? source.checkResourceIsReachable()) == false {
                throw ZynSignError.selectedFileUnavailable(
                    diagnosticDetail: "The selected document could not be reached at the URL the picker returned."
                )
            }
        }
        // Prefer resource-values (works with file coordinators / providers),
        // fall back to fileExists for plain temp URLs produced by fileImporter.
        if let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) {
            if values.isDirectory == true {
                throw ZynSignError.unsupportedImportFile(
                    diagnosticDetail: "The selected document is a directory, not a regular file."
                )
            }
            if values.isRegularFile == false {
                // Not explicitly a regular file (could be symbolic link,
                // package, or provider placeholder) — let the open attempt
                // decide and map the error honestly.
                return
            }
            return
        }
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
    ///
    /// The read is coordinated through `NSFileCoordinator` when the source
    /// is a coordinated URL (Files providers, iCloud). For plain temp URLs
    /// produced by `fileImporter`, coordination is a no-op and the direct
    /// `FileHandle` path is used.
    private func streamCopy(
        from source: URL,
        to destination: URL,
        totalByteCount: Int?,
        reporting progress: (any ImportProgressReporting)?
    ) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ZynSignError.importTemporaryStorageFailure(
                diagnosticDetail: "The staged archive could not be created."
            )
        }

        // Try coordinated read first — required for some Files providers that
        // vend security-scoped URLs outside the sandbox. If coordination
        // reports the file not yet downloaded, trigger a download and retry
        // once with a short wait.
        var coordinationError: NSError?
        var stagedError: (any Error)?
        var didCoordinate = false

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinatedURL in
            didCoordinate = true
            do {
                try self.chunkedCopy(
                    from: coordinatedURL,
                    to: destination,
                    totalByteCount: totalByteCount,
                    reporting: progress
                )
            } catch {
                stagedError = error
            }
        }
        if let error = stagedError {
            throw error
        }
        if didCoordinate {
            if let error = coordinationError {
                throw Self.mapCoordinationFailure(error)
            }
            // Coordination succeeded and the copy was performed inside the
            // accessor — verify the destination has content. An empty
            // destination means nothing was copied and we should fall back
            // to the direct path rather than leave an empty file behind.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
               let size = attrs[.size] as? NSNumber, size.intValue > 0 {
                return
            }
            // If coordination produced an empty file, remove it and fall
            // through to the direct FileHandle path so the honest copy
            // logic can surface a proper error.
            try? FileManager.default.removeItem(at: destination)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw ZynSignError.importTemporaryStorageFailure(
                    diagnosticDetail: "The staged archive could not be recreated after coordination."
                )
            }
        }
        // Direct path — for fileImporter temp copies and any provider where
        // coordination did not already succeed.
        try chunkedCopy(
            from: source,
            to: destination,
            totalByteCount: totalByteCount,
            reporting: progress
        )
    }

    /// The bounded chunked copy used both inside and outside coordination.
    ///
    /// Reports one progress observation per chunk, with the byte count moved
    /// so far. The total is reported as reported by the platform and never
    /// guessed: when it is unknown the copy reports an indeterminate stage
    /// instead of inventing a fraction. Reporting is the only thing the
    /// progress receiver can influence here.
    private func chunkedCopy(
        from source: URL,
        to destination: URL,
        totalByteCount: Int?,
        reporting progress: (any ImportProgressReporting)?
    ) throws {
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

        let total = max(0, totalByteCount ?? 0)
        var written = 0
        progress?.report(ImportProgress(stage: .copying, completedUnitCount: 0, totalUnitCount: total))

        do {
            while true {
                if Task.isCancelled {
                    throw ZynSignError.importCancelled()
                }
                guard let chunk = try reader.read(upToCount: copyChunkSize) else { break }
                if chunk.isEmpty { break }
                try writer.write(contentsOf: chunk)
                written += chunk.count
                progress?.report(
                    ImportProgress(stage: .copying, completedUnitCount: written, totalUnitCount: total)
                )
            }
        } catch let zynSignError as ZynSignError {
            throw zynSignError
        } catch {
            throw ZynSignError.importCopyFailure(underlyingError: error)
        }
    }

    /// Maps an NSFileCoordinator error onto the honest import error.
    private static func mapCoordinationFailure(_ error: NSError) -> ZynSignError {
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return ZynSignError.selectedFileUnavailable(underlyingError: error)
            case NSFileReadNoPermissionError:
                return ZynSignError.selectedFileAccessDenied(underlyingError: error)
            default:
                break
            }
        }
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
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

    // MARK: - Description helpers

    /// The document's size in bytes, when the platform reports one.
    ///
    /// Advisory: it is used for the copy's progress denominator and nothing
    /// else, so an unreadable size produces an indeterminate report rather
    /// than a refusal. The copy itself is the authority on how many bytes
    /// there are.
    private func byteCount(of source: URL) -> Int? {
        if let values = try? source.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
            return size
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
           let size = attributes[.size] as? NSNumber {
            return size.intValue
        }
        return nil
    }

    /// Whether the document's first bytes are one of the signatures a ZIP
    /// container can begin with, or `nil` when they could not be read.
    ///
    /// Unknown is a deliberate, distinct answer: some Files providers vend
    /// their content only inside a coordinated read, and a document that
    /// could not be looked at here is not a document that failed a check.
    /// The pre-import policy refuses only an observation of *wrong* bytes.
    private func archiveSignatureMarker(at source: URL) -> Bool? {
        if let marker = try? readLeadingBytes(of: source) {
            return marker
        }
        var coordinatedMarker: Bool?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            coordinatedMarker = try? self.readLeadingBytes(of: url)
        }
        return coordinatedMarker
    }

    /// Reads the first four bytes and decides whether they begin a ZIP
    /// container. A document shorter than four bytes cannot, and is reported
    /// as such rather than treated as unreadable.
    private func readLeadingBytes(of url: URL) throws -> Bool {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        guard let head = try reader.read(upToCount: 4), head.count == 4 else { return false }
        let bytes = [UInt8](head)
        guard bytes[0] == 0x50, bytes[1] == 0x4B else { return false }
        // "PK\x03\x04" a local file header, "PK\x05\x06" an empty archive,
        // "PK\x07\x08" a spanned-archive marker.
        return (bytes[2] == 0x03 && bytes[3] == 0x04)
            || (bytes[2] == 0x05 && bytes[3] == 0x06)
            || (bytes[2] == 0x07 && bytes[3] == 0x08)
    }

    // MARK: - Leftover lifecycle

    /// Removes everything in the staging directory except the working
    /// copies of `artifacts`.
    ///
    /// Staged archives are session-scoped: an accepted package is moved out
    /// of staging when the library adopts it and every other outcome
    /// discards the staged copy, so a pre-existing file is a leftover — a
    /// partial copy, or the working copy of an import nothing will resume.
    /// The Import Hub calls this once at launch, keeping the copies of the
    /// interrupted imports it restores. Failure to remove a leftover is not
    /// allowed to block anything; it is simply tried again next launch.
    func sweepStagedDocuments(keeping artifacts: Set<ArtifactIdentifier>) {
        let kept = Set(artifacts.map { location(for: $0).lastPathComponent })
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for leftover in leftovers where !kept.contains(leftover.lastPathComponent) {
            try? FileManager.default.removeItem(at: leftover)
        }
    }

    /// The size of the working copy staged as `artifact`, or `nil` when
    /// there is none.
    func stagedByteCount(for artifact: ArtifactIdentifier) -> Int? {
        let url = self.location(for: artifact)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return nil
        }
        return values.fileSize
    }

    // MARK: - Archive entries

    /// Streams one package out of the archive staged as `container` into a
    /// new working copy named `artifact`.
    ///
    /// The container is ZynSign's own working copy, so no security scope or
    /// coordination is involved. The extractor bounds the output by the
    /// sizes the archive declares, verifies the archive's checksum, and
    /// refuses encrypted, linked, and unsupported entries; the destination is
    /// chosen here, from the identifier alone. A failed or cancelled
    /// extraction leaves nothing behind.
    func stageArchiveEntry(
        _ candidate: NestedPackageCandidate,
        from container: ArtifactIdentifier,
        as artifact: ArtifactIdentifier,
        reporting progress: (any ImportProgressReporting)?
    ) throws {
        if Task.isCancelled {
            throw ZynSignError.importCancelled()
        }
        try prepareDirectory()
        let destination = location(for: artifact)
        try? FileManager.default.removeItem(at: destination)
        do {
            try ZipEntryStreamExtractor(archive: location(for: container)).extract(
                candidate.path,
                to: destination,
                reporting: progress
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
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
    /// The working-copy location for `artifact`: the staging directory, the
    /// identifier, and the extension convention — nothing else.
    func location(for artifact: ArtifactIdentifier) -> URL {
        directory
            .appendingPathComponent(artifact.rawValue, isDirectory: false)
            .appendingPathExtension(fileExtension)
    }
}
