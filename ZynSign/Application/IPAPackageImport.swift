import Foundation

/// The import use case: it brings one user-selected package into ZynSign,
/// records what the inspection stage established about it, and hands an
/// accepted package to the library.
///
/// The use case composes capabilities that already exist rather than
/// duplicating them: staging is delegated to the `ArtifactIntake` port,
/// examination is delegated to the structural and metadata inspection use
/// cases over the same archive-reader boundary every other consumer uses,
/// and persistence is delegated to the library use case. The flow it
/// coordinates is:
///
///     selected document
///         ↓  file-type policy (cheap gate, not trusted)
///     staging through the intake port
///         ↓  security-scoped access and the copy are platform concerns
///     structural inspection of the staged archive
///         ↓
///     metadata inspection of the established bundle
///         ↓
///     examined artifact
///         ↓  accepted packages only
///     library admission: duplicate policy, artifact adoption, record
///         ↓
///     import result
///
/// Three properties are deliberate.
///
/// Import never trusts the file name. The `.ipa` extension is a policy gate
/// only; a file that passes it is still untrusted, and only the archive and
/// metadata examinations decide whether it is a valid package.
///
/// Import never extracts. The staged archive is read through the bounded
/// archive boundary exactly the way standalone inspection reads it: entry
/// tables and one bounded information-file read, no unpacked content, and no
/// signature, trust, or installation claims of any kind.
///
/// Ownership of the staged archive is explicit and ends inside this use
/// case. A rejected import's archive is discarded before the result is
/// returned. An accepted import's archive is offered to the library, which
/// either adopts it into durable library storage — after which the record's
/// artifact reference is the only way to reach it — or recognises it as
/// content the library already holds, in which case it is discarded here.
/// If admission fails, the archive is discarded here as well. Nothing staged
/// survives an import in any outcome, and the caller never owns a staged
/// archive.
///
/// The use case is `async` because staging copies files and admission
/// hashes and moves them, but it performs no main-actor work: called from an
/// isolated context, the nonisolated function runs on the cooperative
/// executor, and admission runs on the library actor. Cancellation is
/// honoured at every stage boundary up to admission, and a cancelled import
/// is an ordinary outcome, not an application error.
struct IPAPackageImport {

    private let intake: any ArtifactIntake
    private let structuralInspection: IPAArchiveInspection
    private let metadataInspection: IPABundleMetadataInspection
    private let library: ApplicationLibrary

    /// Creates the use case from the intake port, the archive boundary, and
    /// the library the composition root selected. Both inspection use cases
    /// are built over the same reader provider, so a staged archive is
    /// examined by exactly the machinery any other artifact would be
    /// examined with.
    init(
        intake: any ArtifactIntake,
        readerProvider: any ArtifactArchiveReaderProvider,
        library: ApplicationLibrary,
        limits: ArchiveLimits = .default
    ) {
        self.intake = intake
        self.structuralInspection = IPAArchiveInspection(readerProvider: readerProvider, limits: limits)
        self.metadataInspection = IPABundleMetadataInspection(readerProvider: readerProvider, limits: limits)
        self.library = library
    }

    /// Imports the package the user selected and returns the examined
    /// artifact together with the library's decision.
    ///
    /// The returned artifact carries the discovered bundle, the declared
    /// metadata, and the validation outcome; its identifier is the stable
    /// reference to the artifact wherever the library now holds it. A
    /// rejected package is a result, not an exception — its findings say
    /// what was wrong and its admission is `nil`. Only intake, library, and
    /// infrastructure failures throw, and they throw typed errors.
    func importArtifact(from source: URL) async throws -> PackageImportResult {
        try Task.checkCancellation()

        guard IPAFileFormat.accepts(source) else {
            throw ZynSignError.unsupportedImportFile(
                diagnosticDetail: "The selected file's extension is not the accepted package type."
            )
        }

        let artifact = IPAArtifact(sourceFileName: source.lastPathComponent)

        // Staging either completes or leaves nothing behind, so a failure
        // here needs no cleanup — only a typed error. The intake already
        // throws typed errors; a cancellation is passed through unchanged,
        // and anything else is reported honestly as unexpected.
        do {
            try intake.stageDocument(at: source, as: artifact.id)
        } catch {
            throw Self.normalized(error)
        }

        // Staging can complete just before the task is cancelled. The
        // partial import must then be discarded rather than examined.
        do {
            try Task.checkCancellation()
        } catch {
            intake.discardStagedDocument(for: artifact.id)
            throw error
        }

        let examined = metadataInspection.inspect(structuralInspection.inspect(artifact))

        guard examined.permitsLaterStages else {
            // A rejected package's bytes have no future use; the findings on
            // the returned artifact are the record.
            intake.discardStagedDocument(for: artifact.id)
            return PackageImportResult(artifact: examined, admission: nil)
        }

        // The last cancellation window: once the library begins adopting
        // the archive, the admission runs to completion.
        do {
            try Task.checkCancellation()
        } catch {
            intake.discardStagedDocument(for: artifact.id)
            throw error
        }

        let admission: LibraryAdmission
        do {
            admission = try await library.admit(examined)
        } catch {
            // Whatever the library did, it holds nothing for this artifact
            // now; anything still staged is this flow's to discard.
            intake.discardStagedDocument(for: artifact.id)
            throw Self.normalized(error)
        }

        if case .alreadyRecorded = admission {
            // The library already holds these bytes and took nothing; the
            // staged copy is surplus.
            intake.discardStagedDocument(for: artifact.id)
        }

        return PackageImportResult(artifact: examined, admission: admission)
    }

    /// Normalizes a staging or admission failure into a typed error without
    /// ever letting a foreign error's rendered text become user-facing.
    private static func normalized(_ error: any Error) -> any Error {
        switch error {
        case let zynSignError as ZynSignError:
            return zynSignError
        case is CancellationError:
            return error
        default:
            return ZynSignError.importUnexpectedFailure(underlyingError: error)
        }
    }
}
