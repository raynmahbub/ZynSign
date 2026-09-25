import Foundation

/// The import use case: it brings one user-selected package into ZynSign,
/// records what the inspection stage established about it, and hands an
/// accepted package to the library.
///
/// The use case composes capabilities that already exist rather than
/// duplicating them: pre-import validation is delegated to the `ImportPreflight`
/// policy over what the intake observed, staging is delegated to the
/// `ArtifactIntake` port, examination is delegated to the structural and
/// metadata inspection use cases over the same archive-reader boundary every
/// other consumer uses, duplicate detection is delegated to the library, and
/// persistence is delegated to the library use case. The flow it coordinates
/// is:
///
///     selected document
///         ↓  file-type policy (cheap gate, not trusted)
///     pre-import validation through the intake port
///         ↓  existence, kind, size, and the archive signature
///     staging through the intake port
///         ↓  security-scoped access and the copy are platform concerns
///     structural inspection of the staged archive
///         ↓
///     metadata inspection of the established bundle
///         ↓
///     examined artifact
///         ↓  duplicate comparison against the library, against the staged copy
///     the user's decision, when the comparison found a collision
///         ↓  accepted packages only
///     library admission: duplicate policy, artifact adoption, record
///         ↓  replacement, when the user asked for it and only after the new
///            entry is stored
///     import result
///
/// Four properties are deliberate.
///
/// **The user's file is never modified.** The selected document is opened for
/// reading and copied; it is never written to, moved, renamed, or reopened
/// for writing. Every write this flow performs lands in ZynSign's own staging
/// or library storage. A failed, refused, cancelled, or replaced import
/// therefore leaves the original bytes, name, and timestamps exactly as they
/// were found.
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
/// Ownership of the staged archive is explicit and ends inside this use case.
/// A rejected import's archive is discarded before the result is returned. An
/// accepted import's archive is offered to the library, which either adopts it
/// into durable library storage — after which the record's artifact reference
/// is the only way to reach it — or recognises it as content the library
/// already holds, in which case it is discarded here. If admission fails, the
/// archive is discarded here as well. Nothing staged survives an import in any
/// outcome, and the caller never owns a staged archive.
///
/// The use case is `async` because staging copies files and admission hashes
/// and moves them, but it performs no main-actor work: called from an isolated
/// context, the nonisolated function runs on the cooperative executor, and
/// admission runs on the library actor. Cancellation is honoured at every
/// stage boundary up to admission, including while the user is deciding about
/// a duplicate, and a cancelled import is an ordinary outcome, not an
/// application error.
struct IPAPackageImport: PackageImporting {

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

    /// Imports a package without progress and without a duplicate dialog: the
    /// library's own duplicate policy decides.
    ///
    /// This is the shape the single-package import uses. It is equivalent to
    /// the full call with `nil` for both, so no caller needs to know about
    /// capabilities it does not use.
    func importArtifact(from source: URL) async throws -> PackageImportResult {
        try await importArtifact(from: source, reporting: nil, resolvingDuplicatesWith: nil)
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
    func importArtifact(
        from source: URL,
        reporting progress: (any ImportProgressReporting)?,
        resolvingDuplicatesWith duplicateDecision: DuplicateDecisionProvider?
    ) async throws -> PackageImportResult {
        try Task.checkCancellation()
        progress?.report(ImportProgress(stage: .preparing))

        let artifact = IPAArtifact(sourceFileName: source.lastPathComponent)

        // Pre-import validation, before anything is copied. The platform
        // describes the selection — which it can only do if the file exists
        // and is reachable — and the policy decides whether the description
        // is worth acting on. Both steps throw typed errors; the intake's own
        // errors are normalized, and the policy's are already typed.
        let description: ImportSourceDescription
        do {
            description = try intake.describeDocument(at: source)
        } catch {
            throw Self.normalized(error)
        }
        try ImportPreflight.validate(source, describedBy: description)

        // Staging either completes or leaves nothing behind, so a failure
        // here needs no cleanup — only a typed error. The copy reports its
        // own progress, since only it knows how many bytes have moved.
        progress?.report(ImportProgress(stage: .copying))
        do {
            try intake.stageDocument(at: source, as: artifact.id, reporting: progress)
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

        progress?.report(ImportProgress(stage: .examiningStructure))
        let structurallyExamined = structuralInspection.inspect(artifact)
        guard structurallyExamined.permitsLaterStages else {
            // A package with no usable structure has no bundle to read, and
            // its bytes have no future use; the findings on the returned
            // artifact are the record.
            intake.discardStagedDocument(for: artifact.id)
            return PackageImportResult(artifact: structurallyExamined, admission: nil)
        }

        progress?.report(ImportProgress(stage: .examiningMetadata))
        let examined = metadataInspection.inspect(structurallyExamined)
        guard examined.permitsLaterStages else {
            intake.discardStagedDocument(for: artifact.id)
            return PackageImportResult(artifact: examined, admission: nil)
        }

        progress?.report(ImportProgress(stage: .checkingForDuplicates))
        var admissionPolicy = AdmissionPolicy.strict
        var duplicate: DuplicateOutcome?

        if let duplicateDecision {
            // The comparison runs against the staged copy, before anything is
            // committed, so a decision can be made without the library being
            // touched. A comparison that cannot be made at all is a typed
            // failure, not a silent "no duplicate": the import cannot be
            // admitted safely if the library cannot be asked.
            let report: DuplicateReport
            do {
                report = try await library.duplicateReport(for: examined)
            } catch {
                intake.discardStagedDocument(for: artifact.id)
                throw Self.normalized(error)
            }

            if report.requiresDecision {
                // The last cancellation window before the user is asked; a
                // cancelled import must not open a question nobody is left to
                // answer.
                do {
                    try Task.checkCancellation()
                } catch {
                    intake.discardStagedDocument(for: artifact.id)
                    throw error
                }

                let resolution = await duplicateDecision(report)
                switch resolution {
                case .cancel:
                    // Cancelling a duplicate is an ordinary outcome: nothing
                    // was stored, and the staged copy goes away.
                    intake.discardStagedDocument(for: artifact.id)
                    throw ZynSignError.importCancelled(
                        diagnosticDetail: "The import was cancelled while deciding what to do about a package the library already relates to."
                    )
                case .keepBoth, .replaceExisting:
                    // Both answers store this import, so both admit it even
                    // when the library holds byte-identical content. What
                    // differs is what happens to the entries it matched,
                    // which is settled after the new entry is safely stored.
                    admissionPolicy = .allowDuplicateContent
                }
                // The answer is recorded with the report and applied after
                // admission, so the new entry is always stored before any
                // matched entry is removed.
                duplicate = DuplicateOutcome(report: report, resolution: resolution)
            } else if !report.matches.isEmpty {
                // An ordinary re-import of another version: nothing to
                // decide, but the relation is still worth reporting.
                duplicate = DuplicateOutcome(report: report)
            }
        }

        // The last cancellation window: once the library begins adopting the
        // archive, the admission runs to completion so that storage is never
        // left half-changed by a cancelled task.
        do {
            try Task.checkCancellation()
        } catch {
            intake.discardStagedDocument(for: artifact.id)
            throw error
        }

        progress?.report(ImportProgress(stage: .storing))

        let admission: LibraryAdmission
        do {
            admission = try await library.admit(examined, policy: admissionPolicy)
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

        if let pending = duplicate, let resolution = pending.resolution {
            duplicate = await apply(resolution, to: pending)
        }

        progress?.report(ImportProgress(stage: .finished))
        return PackageImportResult(artifact: examined, admission: admission, duplicate: duplicate)
    }

    // MARK: - Duplicate follow-through

    /// Applies a decision that was made *after* the import was admitted.
    ///
    /// Only replacement does anything here, and it is deliberately second:
    /// the new entry is stored first and the matched entries are removed
    /// afterwards. A failure part way through therefore leaves the library
    /// holding more than the user asked for — the new entry plus the entries
    /// that could not be removed — rather than less. Nothing is ever removed
    /// before its replacement is safely held, and the records that could not
    /// be removed are reported instead of being hidden.
    private func apply(
        _ resolution: DuplicateResolution,
        to outcome: DuplicateOutcome
    ) async -> DuplicateOutcome {
        guard resolution == .replaceExisting else {
            return DuplicateOutcome(
                report: outcome.report,
                resolution: resolution,
                replacedRecords: [],
                retainedRecords: []
            )
        }

        var replaced: [ApplicationRecord] = []
        var retained: [ApplicationRecord] = []
        for match in outcome.report.decisiveMatches {
            do {
                try await library.remove(recordWithID: match.record.id)
                replaced.append(match.record)
            } catch {
                retained.append(match.record)
            }
        }
        return DuplicateOutcome(
            report: outcome.report,
            resolution: .replaceExisting,
            replacedRecords: replaced,
            retainedRecords: retained
        )
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
