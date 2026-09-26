import Foundation

/// The Import Hub's per-item pipeline: stage, validate, analyze, and admit.
///
/// The workflow composes the capabilities the one-shot import already uses
/// — the intake, the preflight policy, the package inspections, and the
/// library — with what the hub adds: containers that hold packages, a
/// storage check before every copy, analysis beyond the declared identity,
/// and admission that is decided by the user rather than asked mid-flight.
///
/// Guarantees, for every item:
///
/// - The user's file is only ever read. Every later step works on
///   ZynSign's own working copy, named by an identifier ZynSign chose.
/// - Nothing is copied when the source is unacceptable or the device lacks
///   the space for it.
/// - A container is classified from its entry table before anything is
///   extracted; an archive with any unsafe or duplicated entry is refused
///   whole.
/// - The library is only changed by `admit`, and a package with a conflict
///   is only admitted with the user's resolution. "Replace Existing"
///   stores the new entry first and then removes exactly the entries the
///   user was shown.
///
/// The workflow holds no mutable state of its own; its collaborators are
/// either stateless or actors, which is why it may be shared by concurrent
/// items.
struct ImportWorkflow: ImportProcessing, @unchecked Sendable {

    /// Called after a package has been stored, with the prepared import and
    /// the record that now stands for it — how the composition root primes
    /// the icon and analysis caches so the library shows them at once.
    typealias AdmissionObserver = @Sendable (PreparedImport, ApplicationRecord) async -> Void

    private let intake: any ArtifactIntake
    private let stagingArea: any ImportStagingArea
    private let readerProvider: any ArtifactArchiveReaderProvider
    private let library: ApplicationLibrary
    private let structuralInspection: IPAArchiveInspection
    private let metadataInspection: IPABundleMetadataInspection
    private let storage: ImportStorageGuard
    private let maximumIconBytes: Int
    private let onAdmitted: AdmissionObserver?

    init(
        intake: any ArtifactIntake,
        stagingArea: any ImportStagingArea,
        readerProvider: any ArtifactArchiveReaderProvider,
        library: ApplicationLibrary,
        storage: ImportStorageGuard,
        limits: ArchiveLimits = .default,
        maximumIconBytes: Int = 512 * 1_024,
        onAdmitted: AdmissionObserver? = nil
    ) {
        self.intake = intake
        self.stagingArea = stagingArea
        self.readerProvider = readerProvider
        self.library = library
        self.structuralInspection = IPAArchiveInspection(readerProvider: readerProvider, limits: limits)
        self.metadataInspection = IPABundleMetadataInspection(readerProvider: readerProvider, limits: limits)
        self.storage = storage
        self.maximumIconBytes = maximumIconBytes
        self.onAdmitted = onAdmitted
    }

    // MARK: - Staging

    func stage(
        _ source: ImportStagingSource,
        fileName: String,
        as artifact: ArtifactIdentifier,
        reporting progress: (any ImportProgressReporting)?
    ) async throws -> StagedImport {
        try Task.checkCancellation()
        progress?.report(ImportProgress(stage: .preparing))

        switch source {
        case .document(let url):
            // The platform describes the selection and the policy decides
            // whether it is worth copying — both before a byte moves.
            let description: ImportSourceDescription
            do {
                description = try intake.describeDocument(at: url)
            } catch {
                throw Self.normalized(error)
            }
            try ImportPreflight.validate(url, describedBy: description, acceptingContainers: true)

            let reservation = try storage.reserve(byteCount: description.byteCount ?? 0)
            defer { storage.release(reservation) }

            progress?.report(ImportProgress(stage: .copying, totalUnitCount: description.byteCount ?? 0))
            do {
                try intake.stageDocument(at: url, as: artifact, reporting: progress)
            } catch {
                throw Self.normalized(error)
            }
            try discardingOnCancellation(artifact)
            return StagedImport(
                artifactID: artifact,
                fileName: fileName,
                byteCount: stagingArea.stagedByteCount(for: artifact) ?? description.byteCount
            )

        case .archiveEntry(let container, let candidate):
            // The archive's own size claims are policed exactly like a
            // selected file's: empty and oversized entries are refused
            // before extraction.
            guard candidate.byteCount > 0 else {
                throw ZynSignError.importSourceEmpty(
                    diagnosticDetail: "The archive records the chosen package as zero bytes."
                )
            }
            guard candidate.byteCount <= ImportPreflight.maximumCandidateByteCount else {
                throw ZynSignError.importSourceTooLarge(
                    diagnosticDetail: "The archive records the chosen package as \(candidate.byteCount) bytes, above the accepted ceiling."
                )
            }

            let reservation = try storage.reserve(byteCount: candidate.byteCount)
            defer { storage.release(reservation) }

            progress?.report(ImportProgress(stage: .copying, totalUnitCount: candidate.byteCount))
            do {
                try stagingArea.stageArchiveEntry(candidate, from: container, as: artifact, reporting: progress)
            } catch {
                throw Self.normalized(error)
            }
            try discardingOnCancellation(artifact)
            return StagedImport(artifactID: artifact, fileName: fileName, byteCount: candidate.byteCount)
        }
    }

    // MARK: - Validation and analysis

    func examine(
        _ staged: StagedImport,
        reporting progress: (any ImportProgressReporting)?
    ) async throws -> ImportExamination {
        try Task.checkCancellation()
        progress?.report(ImportProgress(stage: .examiningStructure))

        // One reader serves the classification, the analysis, and the icon;
        // the package inspections open their own, as they always have.
        let reader: any ArchiveReader
        do {
            reader = try readerProvider.archiveReader(for: staged.artifactID)
        } catch {
            throw ImportFailure.corruptedArchive()
        }
        defer { reader.close() }

        let entries: [ArchiveEntry]
        do {
            entries = try reader.readEntryTable()
        } catch {
            throw ImportFailure.corruptedArchive()
        }

        switch PackageContainerClassification.classify(entries) {
        case .unsafe(let reason):
            throw ImportFailure.unsafeArchive(reason)
        case .noPackages:
            throw ImportFailure.archiveHasNoPackages()
        case .unsupportedLayout(let layout):
            throw ImportFailure.unsupportedLayout(layout)
        case .packageCollection(let candidates):
            return .archive(candidates)
        case .applicationPackage:
            break
        }

        let artifact = IPAArtifact(id: staged.artifactID, sourceFileName: staged.fileName)
        let structurallyExamined = structuralInspection.inspect(artifact)
        guard structurallyExamined.permitsLaterStages else {
            throw ImportFailure.from(validation: structurallyExamined.validation)
        }

        try Task.checkCancellation()
        progress?.report(ImportProgress(stage: .examiningMetadata))
        let examined = metadataInspection.inspect(structurallyExamined)
        guard examined.permitsLaterStages, let metadata = examined.metadata else {
            throw ImportFailure.from(validation: examined.validation)
        }

        let analysis = ApplicationAnalysis.derive(
            from: entries,
            bundleRoot: examined.discoveredBundle?.bundlePath ?? AppIconExtraction.applicationBundleRoot(in: entries),
            metadata: metadata
        )
        let iconData = AppIconExtraction.extractIcon(using: reader, maximumBytes: maximumIconBytes)

        try Task.checkCancellation()
        progress?.report(ImportProgress(stage: .checkingForDuplicates))

        // The working copy is measured here, on this item's task, so the
        // library is never held while a large package is hashed.
        let reference: ArtifactReference
        let report: DuplicateReport
        do {
            reference = try library.describeStagedArtifact(staged.artifactID)
            report = try await library.duplicateReport(for: examined, describedBy: reference)
        } catch {
            throw Self.normalized(error)
        }

        return .package(
            PreparedImport(
                artifact: examined,
                identity: metadata.identity,
                reference: reference,
                analysis: analysis,
                iconData: iconData,
                conflict: ImportRules.conflict(for: report, incoming: metadata.identity)
            )
        )
    }

    // MARK: - Admission

    func admit(
        _ prepared: PreparedImport,
        resolution: ConflictResolution?,
        reporting progress: (any ImportProgressReporting)?
    ) async throws -> ImportSettlement {
        let artifactID = prepared.artifactID
        let relation = prepared.conflict.map { conflict in
            DuplicateOutcome(report: Self.report(for: conflict, reference: prepared.reference))
        }

        if prepared.conflict != nil && resolution == nil {
            // Never guess: an unresolved conflict is not stored.
            intake.discardStagedDocument(for: artifactID)
            throw ZynSignError(
                category: .internalFailure,
                userMessage: "The package conflicts with the library and no choice was made, so nothing was stored.",
                diagnosticDetail: "Admission was requested for a conflicting package without a resolution."
            )
        }

        if resolution == .skip {
            intake.discardStagedDocument(for: artifactID)
            return .skipped(duplicate: relation)
        }

        // The last cancellation window: once adoption begins it runs to
        // completion, so storage is never left half-changed.
        try discardingOnCancellation(artifactID)
        progress?.report(ImportProgress(stage: .storing))

        let policy: AdmissionPolicy = resolution == nil ? .strict : .allowDuplicateContent
        let admission: LibraryAdmission
        do {
            admission = try await library.admit(prepared.artifact, describedBy: prepared.reference, policy: policy)
        } catch {
            intake.discardStagedDocument(for: artifactID)
            throw Self.normalized(error)
        }

        let settlement: ImportSettlement
        switch admission {
        case .alreadyRecorded(let existing):
            // The library holds these exact bytes and took nothing.
            intake.discardStagedDocument(for: artifactID)
            settlement = ImportSettlement(kind: .alreadyHeld, record: existing, duplicate: relation)

        case .recorded(let record, let recordRelation):
            switch resolution {
            case .some(.replaceExisting):
                let (replaced, retained) = await removeReplacedRecords(prepared.conflict?.existingRecords ?? [])
                guard !replaced.isEmpty || !retained.isEmpty else {
                    // Every entry the user chose to replace was already
                    // gone: nothing needed replacing.
                    settlement = ImportSettlement(kind: .imported, record: record, relation: recordRelation)
                    break
                }
                settlement = ImportSettlement(
                    kind: .replaced,
                    record: record,
                    replacedRecords: replaced,
                    retainedRecords: retained,
                    relation: recordRelation,
                    duplicate: prepared.conflict.map { conflict in
                        DuplicateOutcome(
                            report: Self.report(for: conflict, reference: prepared.reference),
                            resolution: .replaceExisting,
                            replacedRecords: replaced,
                            retainedRecords: retained
                        )
                    }
                )
            case .some(.keepBoth):
                settlement = ImportSettlement(
                    kind: .keptBoth,
                    record: record,
                    relation: recordRelation,
                    duplicate: prepared.conflict.map { conflict in
                        DuplicateOutcome(
                            report: Self.report(for: conflict, reference: prepared.reference),
                            resolution: .keepBoth
                        )
                    }
                )
            case .some(.skip), .none:
                settlement = ImportSettlement(kind: .imported, record: record, relation: recordRelation)
            }
            if let onAdmitted {
                await onAdmitted(prepared, record)
            }
        }

        progress?.report(ImportProgress(stage: .finished))
        return settlement
    }

    /// Removes the entries a replacement was confirmed for, after the new
    /// entry is stored. An entry that is already gone is neither removed
    /// nor retained — it simply no longer needs replacing; an entry that
    /// cannot be removed is reported as retained so the interface can say
    /// so.
    private func removeReplacedRecords(
        _ records: [ApplicationRecord]
    ) async -> (replaced: [ApplicationRecord], retained: [ApplicationRecord]) {
        var replaced: [ApplicationRecord] = []
        var retained: [ApplicationRecord] = []
        for record in records {
            // Only an entry the library positively reports as gone is
            // skipped; an entry whose state cannot be read is attempted,
            // and reported as retained if the removal fails.
            let stillPresent: Bool
            do {
                stillPresent = try await library.entry(withID: record.id) != nil
            } catch {
                stillPresent = true
            }
            guard stillPresent else { continue }
            do {
                try await library.remove(recordWithID: record.id)
                replaced.append(record)
            } catch {
                retained.append(record)
            }
        }
        return (replaced, retained)
    }

    // MARK: - Working copies

    func discardWorkingCopy(_ artifact: ArtifactIdentifier) {
        intake.discardStagedDocument(for: artifact)
    }

    func workingCopyByteCount(_ artifact: ArtifactIdentifier) -> Int? {
        stagingArea.stagedByteCount(for: artifact)
    }

    func sweepWorkingCopies(keeping artifacts: Set<ArtifactIdentifier>) {
        stagingArea.sweepStagedDocuments(keeping: artifacts)
    }

    func availableCapacity() -> Int? {
        storage.availableCapacity()
    }

    // MARK: - Helpers

    /// Discards `artifact` and rethrows when the task was cancelled after a
    /// step completed, so a cancelled item never leaves a working copy.
    private func discardingOnCancellation(_ artifact: ArtifactIdentifier) throws {
        do {
            try Task.checkCancellation()
        } catch {
            intake.discardStagedDocument(for: artifact)
            throw error
        }
    }

    /// The duplicate report a conflict was derived from, reconstructed for
    /// the settlement so the interface can describe the relation.
    private static func report(for conflict: ImportConflict, reference: ArtifactReference) -> DuplicateReport {
        DuplicateDetection.report(
            identity: conflict.incomingIdentity,
            reference: reference,
            against: conflict.existingRecords
        )
    }

    private static func normalized(_ error: any Error) -> any Error {
        switch error {
        case let failure as ImportFailure:
            return failure
        case let zynSignError as ZynSignError:
            return zynSignError
        case is CancellationError:
            return error
        default:
            return ZynSignError.importUnexpectedFailure(underlyingError: error)
        }
    }
}
