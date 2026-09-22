import Foundation

/// The import use case: it brings one user-selected package into ZynSign and
/// records what the inspection stage established about it.
///
/// The use case composes capabilities that already exist rather than
/// duplicating them: staging is delegated to the `ArtifactIntake` port, and
/// examination is delegated to the structural and metadata inspection use
/// cases over the same archive-reader boundary every other consumer uses.
/// The flow it coordinates is:
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
/// Ownership of the staged archive is explicit. A rejected import's archive
/// is discarded before the result is returned. An accepted import's archive
/// is retained deliberately — it is what the future persistence stage will
/// adopt — and is released through `discardStagedArtifact` when the result's
/// owner drops or replaces it. Nothing staged survives implicitly: a new
/// process clears what previous processes left behind.
///
/// The use case is `async` because staging copies files, but it performs no
/// actor hop of its own: called from an isolated context, the nonisolated
/// function runs on the cooperative executor, so file copying, archive
/// reading, and property-list parsing never occupy the caller's actor.
/// Cancellation is honoured at every stage boundary, and a cancelled import
/// is an ordinary outcome, not an application error.
struct IPAPackageImport {

    private let intake: any ArtifactIntake
    private let structuralInspection: IPAArchiveInspection
    private let metadataInspection: IPABundleMetadataInspection

    /// Creates the use case from the intake port and the archive boundary
    /// the composition root selected. Both inspection use cases are built
    /// over the same reader provider, so a staged archive is examined by
    /// exactly the machinery any other artifact would be examined with.
    init(
        intake: any ArtifactIntake,
        readerProvider: any ArtifactArchiveReaderProvider,
        limits: ArchiveLimits = .default
    ) {
        self.intake = intake
        self.structuralInspection = IPAArchiveInspection(readerProvider: readerProvider, limits: limits)
        self.metadataInspection = IPABundleMetadataInspection(readerProvider: readerProvider, limits: limits)
    }

    /// Imports the package the user selected and returns it with the
    /// inspection outcome recorded.
    ///
    /// The returned artifact is the imported-artifact result for this stage:
    /// its identifier is the stable reference to the staged archive, and it
    /// carries the discovered bundle, the declared metadata, and the
    /// validation outcome. A `nil`-metadata or non-`valid` outcome is a
    /// result, not an exception — its findings say what was wrong. Only
    /// intake and infrastructure failures throw, and they throw typed errors.
    ///
    /// The staged archive's lifetime is decided by the outcome: a rejected
    /// artifact's archive is discarded here, an accepted one is retained
    /// until its owner releases it through `discardStagedArtifact(_:)`.
    func importArtifact(from source: URL) async throws -> IPAArtifact {
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
            return examined
        }

        // The staged archive stays. Its owner releases it explicitly.
        return examined
    }

    /// Releases the staged archive for `artifact`. This is the explicit
    /// ownership-transfer endpoint for an accepted import: the owner of an
    /// import result calls it when the result is dropped or replaced, and
    /// never assumes the archive is cleaned up by anything else.
    func discardStagedArtifact(_ artifact: ArtifactIdentifier) {
        intake.discardStagedDocument(for: artifact)
    }

    /// Normalizes a staging failure into a typed error without ever letting
    /// a foreign error's rendered text become user-facing.
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
