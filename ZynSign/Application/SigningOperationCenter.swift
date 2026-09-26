import Foundation

/// Why a signing operation did not start.
///
/// A refusal is not a failed signing. Nothing ran, no working copy was made,
/// no stage was reported, and — deliberately — no history record is written:
/// the journal lists operations that happened, and recording a run that never
/// began as a failed operation would misstate it. The refusal carries its own
/// explanation, which the interface shows immediately, and the user can fix
/// the cause and start the operation again.
enum SigningOperationRefusal: Equatable, Sendable {

    /// The package the library holds for this application is gone.
    case sourceUnavailable(explanation: String)

    /// The device does not have the free space the operation needs.
    case insufficientStorage(requiredByteCount: Int, availableByteCount: Int)

    /// A per-operation working directory could not be prepared.
    case workspaceUnavailable(explanation: String)

    /// The refusal's short title.
    var title: String {
        switch self {
        case .sourceUnavailable: return "Package Not Available"
        case .insufficientStorage: return "Not Enough Free Space"
        case .workspaceUnavailable: return "Could Not Start Signing"
        }
    }

    /// The refusal's explanation, in fixed language.
    var message: String {
        switch self {
        case .sourceUnavailable(let explanation):
            return explanation
        case .insufficientStorage(let required, let available):
            let requiredText = ByteCountFormatter.string(fromByteCount: Int64(required), countStyle: .file)
            let availableText = ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file)
            return "\(ZynSignError.insufficientStorageForSigning().userMessage) Signing needs about \(requiredText) for the working copy and the signed artifact, and this device has about \(availableText) available."
        case .workspaceUnavailable(let explanation):
            return explanation
        }
    }
}

/// What one signing operation did.
enum SigningOperationOutcome: Sendable {

    /// Signed output was produced, committed to export storage, and recorded.
    case exported(record: ExportRecord, operation: SigningRecord, fileURL: URL)

    /// The run failed at a stage. A record describes it; nothing was
    /// delivered, and nothing partial reached export storage.
    case failed(operation: SigningRecord, failure: SigningFailureSummary)

    /// The run was cancelled. A record describes how far it got.
    case cancelled(operation: SigningRecord)

    /// The run never started, so nothing was recorded.
    case refused(SigningOperationRefusal)

    /// The operation's history record, when the operation ran.
    var operationRecord: SigningRecord? {
        switch self {
        case .exported(_, let operation, _): return operation
        case .failed(let operation, _): return operation
        case .cancelled(let operation): return operation
        case .refused: return nil
        }
    }

    /// The export record describing the delivered artifact, when there is one.
    var exportRecord: ExportRecord? {
        guard case .exported(let record, _, _) = self else { return nil }
        return record
    }

    /// The delivered artifact's location, when there is one.
    var fileURL: URL? {
        guard case .exported(_, _, let url) = self else { return nil }
        return url
    }

    /// The refusal, when the operation never started.
    var refusal: SigningOperationRefusal? {
        guard case .refused(let refusal) = self else { return nil }
        return refusal
    }

    /// Whether signed output was delivered.
    var didExport: Bool {
        if case .exported = self { return true }
        return false
    }
}

/// One signing operation's inputs.
///
/// The request carries what the run needs and nothing that must not be
/// stored: the profile's bytes are used to sign and are never persisted, the
/// identity is named by identifier, and the certificate is named by its
/// display name and fingerprint rather than reproduced.
struct SigningOperationRequest: Sendable {

    /// The library entry being signed.
    let entry: LibraryEntry

    /// The source container's location in library storage.
    let sourceURL: URL

    /// The replacement profile's bytes. Used for this run only; never stored.
    let profile: Data

    /// The profile's declared name, when the caller knows it. Recorded; the
    /// bytes are not.
    let provisioningProfileName: String?

    /// The identity whose capability signs.
    let identityID: SigningIdentityIdentifier

    /// The certificate's display name as the certificate store presents it,
    /// when the caller has it. An identifier for auditing, never key
    /// material.
    let certificateDisplayName: String?

    /// The certificate's fingerprint, when the caller has it.
    let certificateFingerprint: CertificateFingerprint?

    /// The entitlements to embed. The profile stage holds them against the
    /// profile before anything is signed.
    let entitlements: CodeSigningEntitlements

    /// The run's options.
    let options: SignApplicationOptions

    /// The signing preset the run came from, when it came from one.
    let presetID: PresetIdentifier?

    init(
        entry: LibraryEntry,
        sourceURL: URL,
        profile: Data,
        provisioningProfileName: String? = nil,
        identityID: SigningIdentityIdentifier,
        certificateDisplayName: String? = nil,
        certificateFingerprint: CertificateFingerprint? = nil,
        entitlements: CodeSigningEntitlements,
        options: SignApplicationOptions = SignApplicationOptions(),
        presetID: PresetIdentifier? = nil
    ) {
        self.entry = entry
        self.sourceURL = sourceURL
        self.profile = profile
        self.provisioningProfileName = provisioningProfileName
        self.identityID = identityID
        self.certificateDisplayName = certificateDisplayName
        self.certificateFingerprint = certificateFingerprint
        self.entitlements = entitlements
        self.options = options
        self.presetID = presetID
    }
}

/// The result of verifying one exported artifact again.
struct ExportedArtifactVerification: Sendable {

    /// The export record with verification's conclusion recorded.
    let record: ExportRecord

    /// The report itself, so the interface can show every finding of the run
    /// that just happened rather than only what was persisted.
    let report: ArtifactVerificationReport
}

/// The boundary through which one signing operation gets a working directory
/// of its own.
///
/// The provider owns the place working copies are made and nothing else. Given
/// an operation's own identifier it returns a directory nothing else writes
/// into, and it can remove that directory again. Two operations, or a run and
/// a cleanup, therefore never write into each other's files, and an operation
/// that is interrupted leaves only identifiable leftovers for recovery to
/// remove.
protocol SigningWorkspaceProviding: Sendable {

    /// Creates and returns the working directory for one operation, named by
    /// the operation's own identifier.
    func makeOperationDirectory(forOperation identifier: String) throws -> URL

    /// Removes a directory this provider created. Idempotent: a directory
    /// that is already gone is not an error.
    func removeOperationDirectory(at location: URL)
}

/// Runs one signing operation end to end and records what happened.
///
/// The center composes the pipeline, export storage, the signing journal, and
/// independent verification into the sequence the product promises:
///
///     import → validation → preflight → nested signing → main signing →
///     verification → packaging → export
///
/// and it turns every execution it runs into history. (The Sign screen runs
/// the Signing Engine directly and journals its runs through
/// `SigningEngineJournalDraft`.) What it guarantees:
///
/// - **Isolation.** Every run works in its own directory, named by the run's
///   own identifier, so concurrent runs and a concurrent cleanup can never
///   write into each other's files. The directory is removed when the run
///   ends, whether it succeeded, failed, or was cancelled; a run that is
///   killed outright leaves only that directory behind, and recovery removes
///   it.
/// - **No overwrite.** The artifact is named by `ExportNamingPolicy` from what
///   the bundle declares, resolved against the names export storage holds at
///   that moment, and export storage refuses to overwrite regardless: a name
///   taken between choosing and writing fails the export rather than losing a
///   file.
/// - **Honest records.** A run that fails records the stage it failed at, its
///   category, a fixed-language explanation, and a timeline in which
///   everything after the failure reads "not reached". A cancelled run records
///   itself as cancelled. A refusal before the run records nothing, because
///   nothing ran.
/// - **No secrets.** Neither the export record nor the operation record
///   carries profile bytes, key material, passwords, or absolute paths.
///
/// The center holds no mutable state of its own: the concurrency story is
/// entirely in the per-operation directories and the isolated stores it
/// composes.
struct SigningOperationCenter {

    /// How many times the source package's size a run is expected to need for
    /// its working copy and its produced container. Packaging rebuilds a
    /// container from an extracted working copy, so more than one copy of the
    /// content exists at once. The factor is a conservative planning number,
    /// not a measurement.
    static let workingCopyOverheadFactor = 3

    /// The free space ZynSign insists on leaving untouched, so a device that
    /// is nearly full does not fail halfway through a write.
    static let minimumFreeSpaceHeadroom = 512 * 1_024 * 1_024

    private let pipeline: SignApplicationPipeline
    private let exports: ExportCenter
    private let history: any SigningHistoryStore
    private let verification: VerifyExportedArtifact
    private let workspaces: any SigningWorkspaceProviding
    private let capacity: (any StorageCapacityProbing)?
    private let now: @Sendable () -> Date

    init(
        pipeline: SignApplicationPipeline,
        exports: ExportCenter,
        history: any SigningHistoryStore,
        verification: VerifyExportedArtifact,
        workspaces: any SigningWorkspaceProviding,
        capacity: (any StorageCapacityProbing)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pipeline = pipeline
        self.exports = exports
        self.history = history
        self.verification = verification
        self.workspaces = workspaces
        self.capacity = capacity
        self.now = now
    }

    /// The free space a run needs before it starts, for a source of
    /// `byteCount` bytes.
    func requiredFreeSpace(forSourceByteCount byteCount: Int) -> Int {
        max(0, byteCount) * Self.workingCopyOverheadFactor + Self.minimumFreeSpaceHeadroom
    }

    /// Signs one application and delivers the result to export storage.
    ///
    /// - Returns: What the operation did. A run that never started returns a
    ///   refusal; a run that failed or was cancelled returns a record and
    ///   leaves export storage untouched.
    /// - Parameters:
    ///   - request: The operation's inputs.
    ///   - observer: Receives the pipeline's progress events as the run
    ///     advances, after the operation's own timeline has recorded each
    ///     one. Called synchronously on the run's execution context; a caller
    ///     that renders progress marshals it to its own actor. Advisory only:
    ///     an observer cannot influence the run. The signing queue uses this
    ///     to report honest per-job stage progress. `nil` observes nothing.
    /// - Throws: `CancellationError` when the surrounding task was cancelled.
    ///   The operation's own record is written before the error is thrown, so
    ///   the history is complete either way.
    func run(
        _ request: SigningOperationRequest,
        observer: ApplicationSigningProgressObserver? = nil
    ) async throws -> SigningOperationOutcome {
        let startedAt = now()
        let operationIdentifier = UUID().uuidString
        let timeline = SigningTimelineBox(now: now)
        timeline.began(.importSource, at: startedAt)

        if let refusal = refuseBeforeStarting(sourceURL: request.sourceURL) {
            return .refused(refusal)
        }
        timeline.finished(.importSource, at: now())

        let operationDirectory: URL
        do {
            operationDirectory = try workspaces.makeOperationDirectory(forOperation: operationIdentifier)
        } catch {
            return .refused(.workspaceUnavailable(
                explanation: ZynSignError.signingWorkspaceUnavailable().userMessage
            ))
        }
        defer { workspaces.removeOperationDirectory(at: operationDirectory) }

        let base = ExportNamingPolicy.baseName(
            applicationName: request.entry.record.displayName,
            bundleIdentifier: request.entry.record.bundleIdentifier.rawValue,
            shortVersion: request.entry.record.identity.shortVersionString,
            buildVersion: request.entry.record.identity.buildVersion
        )
        // The staged name is used only inside this operation's own directory,
        // so it is the unsuffixed candidate: collisions are resolved against
        // export storage at commit time, where other runs' artifacts live.
        let stagedURL = operationDirectory.appendingPathComponent(
            ExportNamingPolicy.candidateName(base: base, attempt: 0),
            isDirectory: false
        )
        let signingRequest = SignApplicationRequest(
            sourceURL: request.sourceURL,
            profile: request.profile,
            identityID: request.identityID,
            entitlements: request.entitlements,
            outputURL: stagedURL,
            options: request.options
        )

        let result: SignApplicationResult
        do {
            // This operation's own directory is handed to the run as its
            // working root, so the working copy is extracted where nothing
            // else writes: a concurrent run, or a cleanup, can never reach
            // it, and an interrupted run leaves exactly one directory for
            // recovery to remove. The pipeline takes a supplied working root
            // as the caller's and never removes it, which is what lets this
            // run clean up after itself on every path below.
            result = try await pipeline.sign(
                signingRequest,
                observer: { event in
                    timeline.apply(event)
                    observer?(event)
                },
                workingRoot: operationDirectory
            )
        } catch is CancellationError {
            timeline.cancelledActiveStage(detail: "The operation was cancelled during this stage.")
            timeline.notRun(.export, detail: "No artifact was committed.")
            let record = makeRecord(
                request: request,
                startedAt: startedAt,
                result: .cancelled,
                stoppingStage: timeline.build().lastConcludedStage?.rawValue,
                outputFileName: nil,
                outputByteCount: nil,
                outputFingerprint: nil,
                exportIdentifier: nil,
                verificationStatus: nil,
                verificationRecordedAt: nil,
                verificationFindings: nil,
                failure: nil,
                timeline: timeline.build()
            )
            try? await history.append(record)
            throw CancellationError()
        } catch {
            let failure = ApplicationSigningFailure(
                stage: .integrity,
                detail: "The signing run could not be completed.",
                category: (error as? ZynSignError)?.category ?? .internalFailure
            )
            timeline.failed(timeline.activeStage ?? .validation, at: now(), detail: failure.detail)
            timeline.notRun(.export, detail: "No artifact was committed.")
            return await recordFailure(failure, request: request, startedAt: startedAt, timeline: timeline)
        }

        switch result.status {
        case .failed:
            let failure = result.failure ?? ApplicationSigningFailure(
                stage: .integrity,
                detail: "The signing run reported no result.",
                category: .internalFailure
            )
            timeline.notRun(.export, detail: "No artifact was committed.")
            return await recordFailure(failure, request: request, startedAt: startedAt, timeline: timeline)

        case .signed:
            guard let stagedOutput = result.outputURL else {
                let failure = ApplicationSigningFailure(
                    stage: .packaging,
                    detail: "The signing run delivered no container.",
                    category: .internalFailure
                )
                timeline.notRun(.export, detail: "No artifact was committed.")
                return await recordFailure(failure, request: request, startedAt: startedAt, timeline: timeline)
            }
            return await commit(
                stagedOutput: stagedOutput,
                base: base,
                runVerification: result.stages?.verification,
                request: request,
                startedAt: startedAt,
                timeline: timeline
            )
        }
    }

    /// Verifies one exported artifact again, independently of the run that
    /// produced it, and records what verification concluded.
    ///
    /// - Returns: The updated record and the full report of the run that just
    ///   happened.
    /// - Throws: A typed error when no export carries the identifier.
    ///   `CancellationError` when the surrounding task was cancelled. A
    ///   missing artifact is not an error: it is verification's own
    ///   `unsupported` finding, recorded like any other conclusion.
    func verifyExportedArtifact(withID id: ExportIdentifier) async throws -> ExportedArtifactVerification {
        guard let entry = try await exports.entry(withID: id) else {
            throw ZynSignError.exportRecordNotFound(
                diagnosticDetail: "No export record carries identifier '\(id.rawValue)'."
            )
        }
        let report: ArtifactVerificationReport
        if let fileURL = entry.fileURL {
            report = try await verification.verify(artifactAt: fileURL)
        } else {
            report = ArtifactVerificationReport.derive(
                findings: [
                    ArtifactVerificationFinding(
                        code: .artifactUnavailable,
                        severity: .unsupported,
                        detail: "The exported artifact is no longer on this device, so there was nothing to verify."
                    )
                ],
                verifiedAt: now(),
                artifactByteCount: nil,
                checksRun: 0
            )
        }
        let record = try await exports.recordVerification(report, for: id)
        return ExportedArtifactVerification(record: record, report: report)
    }

    // MARK: - Starting conditions

    /// The checks a run makes before it starts: the source package is still
    /// held, and the device can hold the working copy.
    private func refuseBeforeStarting(sourceURL: URL) -> SigningOperationRefusal? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return .sourceUnavailable(
                explanation: "The package ZynSign keeps for this application is no longer in its library, so there is nothing to sign."
            )
        }
        guard let capacity, let available = try? capacity.availableByteCount() else { return nil }
        let required = requiredFreeSpace(forSourceByteCount: Self.sourceByteCount(at: sourceURL))
        guard available < required else { return nil }
        return .insufficientStorage(requiredByteCount: required, availableByteCount: available)
    }

    /// The source package's size, or zero when the file system will not say.
    /// A size that cannot be read produces a smaller requirement, never a
    /// refusal: not measuring is not evidence.
    private static func sourceByteCount(at location: URL) -> Int {
        guard let values = try? location.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return 0
        }
        return max(0, size)
    }

    // MARK: - Delivery

    /// Commits a produced container to export storage, verifies it
    /// independently, and records both.
    private func commit(
        stagedOutput: URL,
        base: String,
        runVerification: VerifySignedApplicationReport?,
        request: SigningOperationRequest,
        startedAt: Date,
        timeline: SigningTimelineBox
    ) async -> SigningOperationOutcome {
        timeline.began(.export, at: now())
        let measurement: StagedExportMeasurement
        do {
            measurement = try await exports.measure(stagedOutput)
        } catch {
            return await recordExportFailure(
                detail: "The signed container could not be measured before it was exported.",
                category: (error as? ZynSignError)?.category ?? .storageFailure,
                request: request,
                startedAt: startedAt,
                timeline: timeline
            )
        }

        let fileName: String
        let artifactURL: URL
        do {
            (fileName, artifactURL) = try await exports.commit(stagedOutput, base: base)
        } catch {
            return await recordExportFailure(
                detail: (error as? ZynSignError)?.userMessage
                    ?? "The signed container could not be added to export storage.",
                category: (error as? ZynSignError)?.category ?? .storageFailure,
                request: request,
                startedAt: startedAt,
                timeline: timeline
            )
        }

        var record = ExportRecord(
            sourceRecordIdentifier: request.entry.record.id.rawValue,
            sourceArtifactIdentifier: request.entry.record.artifact.artifactID.rawValue,
            applicationName: request.entry.record.displayName,
            bundleIdentifier: request.entry.record.bundleIdentifier.rawValue,
            shortVersion: request.entry.record.identity.shortVersionString,
            buildVersion: request.entry.record.identity.buildVersion,
            fileName: fileName,
            byteCount: measurement.byteCount,
            fingerprint: ExportFingerprint(measurement.fingerprint),
            createdAt: now(),
            signingOutcome: .succeeded,
            verificationStatus: .unsupported
        )
        try? await exports.write(record)

        // Independent verification of the committed artifact — the same code
        // path the Export Center's "Verify Again" runs, so the status a row
        // shows is always the result of reopening the artifact and never the
        // signing run's own opinion of itself.
        let report = await verify(fileURL: artifactURL, byteCount: measurement.byteCount)
        if let updated = try? await exports.recordVerification(report, for: record.id) {
            record = updated
        }

        timeline.finished(
            .export,
            at: now(),
            detail: "Artifact committed as \(fileName) and verified independently."
        )

        // The run's own verification and the artifact's verification are two
        // different facts: the pipeline verified the container against what
        // the run established before it was packaged, and the export record
        // carries what verification concluded about the artifact afterwards.
        let runVerificationPassed = runVerification?.passed ?? true
        let operation = makeRecord(
            request: request,
            startedAt: startedAt,
            result: .succeeded,
            stoppingStage: SigningOperationStage.export.rawValue,
            outputFileName: fileName,
            outputByteCount: measurement.byteCount,
            outputFingerprint: ExportFingerprint(measurement.fingerprint),
            exportIdentifier: record.id.rawValue,
            verificationStatus: runVerificationPassed ? .valid : .warning,
            verificationRecordedAt: report.verifiedAt,
            verificationFindings: report.recordedFindings,
            failure: nil,
            timeline: timeline.build()
        )
        try? await history.append(operation)
        return .exported(record: record, operation: operation, fileURL: artifactURL)
    }

    /// Runs independent verification over a committed artifact. The artifact
    /// is already committed at this point, so verification failing to run
    /// must not undo the export: it is reported as an inconclusive finding.
    private func verify(fileURL: URL, byteCount: Int) async -> ArtifactVerificationReport {
        do {
            return try await verification.verify(artifactAt: fileURL)
        } catch {
            return ArtifactVerificationReport.derive(
                findings: [
                    ArtifactVerificationFinding(
                        code: .containerUnreadable,
                        severity: .unsupported,
                        detail: "Independent verification could not run after the artifact was committed."
                    )
                ],
                verifiedAt: now(),
                artifactByteCount: byteCount,
                checksRun: 0
            )
        }
    }

    // MARK: - Records

    /// Records a run that failed, at whatever stage it reached.
    private func recordFailure(
        _ failure: ApplicationSigningFailure,
        request: SigningOperationRequest,
        startedAt: Date,
        timeline: SigningTimelineBox
    ) async -> SigningOperationOutcome {
        // The pipeline reports the stage it refused as part of the failure
        // rather than through progress — progress says what ran, and a
        // refused stage did not run to completion — so the failure is marked
        // here, before the timeline is read. Marking is what makes a failed
        // run show ✕ at the stage that stopped it instead of a row of
        // stages that merely never concluded.
        timeline.failed(
            Self.pipelineStage(for: failure.stage),
            at: now(),
            detail: failure.detail
        )
        let built = timeline.build()
        let summary = Self.failureSummary(for: failure, timeline: built)
        let record = makeRecord(
            request: request,
            startedAt: startedAt,
            result: .failed,
            stoppingStage: summary.stage.rawValue,
            outputFileName: nil,
            outputByteCount: nil,
            outputFingerprint: nil,
            exportIdentifier: nil,
            verificationStatus: nil,
            verificationRecordedAt: nil,
            verificationFindings: nil,
            failure: summary,
            timeline: built
        )
        try? await history.append(record)
        return .failed(operation: record, failure: summary)
    }

    /// Records a failure at the export stage: the container was produced and
    /// verified, but export storage refused it. The staged container is
    /// discarded with the operation's working directory, so nothing partial
    /// reaches export storage.
    private func recordExportFailure(
        detail: String,
        category: DiagnosticCategory,
        request: SigningOperationRequest,
        startedAt: Date,
        timeline: SigningTimelineBox
    ) async -> SigningOperationOutcome {
        timeline.failed(.export, at: now(), detail: detail)
        let built = timeline.build()
        let summary = SigningFailureSummary(
            stage: .export,
            category: category.rawValue,
            explanation: detail,
            technicalDetail: "The container was produced and verified, but export storage refused it, so nothing was kept."
        )
        let record = makeRecord(
            request: request,
            startedAt: startedAt,
            result: .failed,
            stoppingStage: SigningOperationStage.export.rawValue,
            outputFileName: nil,
            outputByteCount: nil,
            outputFingerprint: nil,
            exportIdentifier: nil,
            verificationStatus: nil,
            verificationRecordedAt: nil,
            verificationFindings: nil,
            failure: summary,
            timeline: built
        )
        try? await history.append(record)
        return .failed(operation: record, failure: summary)
    }

    private func makeRecord(
        request: SigningOperationRequest,
        startedAt: Date,
        result: SigningRecord.Outcome,
        stoppingStage: String?,
        outputFileName: String?,
        outputByteCount: Int?,
        outputFingerprint: ExportFingerprint?,
        exportIdentifier: String?,
        verificationStatus: ArtifactVerificationStatus?,
        verificationRecordedAt: Date?,
        verificationFindings: [String]?,
        failure: SigningFailureSummary?,
        timeline: SigningTimeline
    ) -> SigningRecord {
        SigningRecord(
            presetID: request.presetID,
            certificateFingerprint: request.certificateFingerprint,
            sourceBundleIdentifier: request.entry.record.bundleIdentifier.rawValue,
            sourceDisplayName: request.entry.record.displayName,
            stoppingStage: stoppingStage,
            errorCode: failure?.category,
            outputFileName: outputFileName,
            outputByteCount: outputByteCount,
            startedAt: startedAt,
            duration: now().timeIntervalSince(startedAt),
            result: result,
            sourceRecordIdentifier: request.entry.record.id.rawValue,
            shortVersion: request.entry.record.identity.shortVersionString,
            buildVersion: request.entry.record.identity.buildVersion,
            certificateDisplayName: request.certificateDisplayName,
            teamIdentifier: request.options.teamIdentifier?.rawValue,
            provisioningProfileName: request.provisioningProfileName,
            configuration: Self.configuration(for: request),
            failure: failure,
            outputFingerprint: outputFingerprint,
            exportIdentifier: exportIdentifier,
            verificationStatus: verificationStatus,
            verificationRecordedAt: verificationRecordedAt,
            verificationFindings: verificationFindings,
            timeline: timeline.entries
        )
    }

    /// The configuration the run used, recorded for auditing.
    ///
    /// The summary names the choices, and nothing else: no key, no profile
    /// bytes, no password, and no location.
    private static func configuration(for request: SigningOperationRequest) -> SigningConfigurationSummary {
        let policy: String
        switch request.options.existingSignaturePolicy {
        case .rejectExistingSignature: policy = "Existing signatures rejected"
        case .replaceExistingSignature: policy = "Existing signatures replaced"
        }
        let version = request.options.emitDEREntitlements ? CodeDirectoryVersion.v20400 : CodeDirectoryVersion.v20200
        return SigningConfigurationSummary(
            existingSignaturePolicy: policy,
            codeDirectoryVersion: "0x" + String(version.rawValue, radix: 16),
            entitlementCount: request.entitlements.keys.count,
            derEntitlements: request.options.emitDEREntitlements,
            teamIdentifier: request.options.teamIdentifier?.rawValue
        )
    }

    /// The failure in the form the history keeps: the stage's own explanation
    /// first, and the pipeline's own vocabulary behind it.
    ///
    /// The stage recorded is the one the timeline shows — the same stage the
    /// run stopped at — so a failure's stage and its ✕ can never disagree.
    /// The pipeline's own stage name is quoted only when it maps to that same
    /// timeline stage; when it does not, the failure stopped somewhere the
    /// timeline named more precisely, and the quotation is left out rather
    /// than printed against the wrong stage.
    static func failureSummary(
        for failure: ApplicationSigningFailure,
        timeline: SigningTimeline
    ) -> SigningFailureSummary {
        let reported = pipelineStage(for: failure.stage)
        let stage = timeline.failedStage ?? reported
        return SigningFailureSummary(
            stage: stage,
            category: failure.category.rawValue,
            explanation: failure.detail,
            technicalDetail: stage == reported
                ? "Pipeline stage: \(failure.stage.rawValue) · Category: \(failure.category.rawValue)"
                : "Category: \(failure.category.rawValue)"
        )
    }

    // MARK: - Stage mapping

    /// The timeline stage a pipeline stage belongs to.
    ///
    /// The map is not one-to-one, and that is deliberate: the timeline shows
    /// the stages the product promises, while the pipeline reports the work it
    /// actually does. Discovery and extraction prepare nested signing;
    /// resource sealing and the main executable are one main-signing step.
    static func pipelineStage(for stage: ApplicationSigningStage) -> SigningOperationStage {
        switch stage {
        case .integrity: return .validation
        case .profile: return .preflight
        case .discovery, .extraction, .nestedSigning: return .nestedSigning
        case .resourceSealing, .mainExecutable: return .mainSigning
        case .verification: return .verification
        case .packaging: return .packaging
        }
    }

    /// The fixed-language detail recorded when a timeline stage completes.
    ///
    /// The pipeline's own evidence is richer than one sentence, so the
    /// timeline states what the stage established rather than paraphrasing a
    /// count it did not capture. The counts live in the operation's records
    /// and in the artifact itself.
    static func completionDetail(for stage: SigningOperationStage) -> String? {
        switch stage {
        case .importSource: return "Library package available"
        case .validation: return "Container structure, bundle information, and executable established"
        case .preflight: return "Identity, profile, and entitlements held against each other"
        case .nestedSigning: return "Nested code discovered, extracted, and signed"
        case .mainSigning: return "Resources sealed and main executable signed"
        case .verification: return "Produced container verified against what the run established"
        case .packaging: return "Working copy rebuilt as a container"
        case .export: return "Artifact committed to export storage"
        }
    }

    /// The pipeline stages whose completion concludes a timeline stage.
    ///
    /// Discovery, extraction, and resource sealing are steps inside a timeline
    /// stage, so their completion does not conclude the stage that contains
    /// them.
    static func concludesTimelineStage(_ stage: ApplicationSigningStage) -> Bool {
        switch stage {
        case .discovery, .extraction, .resourceSealing: return false
        case .integrity, .profile, .nestedSigning, .mainExecutable, .verification, .packaging: return true
        }
    }
}

/// The run's timeline, shared with the pipeline's progress observer.
///
/// The pipeline reports progress from the run's own task, so the timeline is
/// guarded by a lock rather than confined to an actor: an observer callback
/// must be able to record without awaiting, and the run's own task must be
/// able to read the timeline the moment the pipeline returns. Only the
/// timeline's own state is behind the lock; nothing else is shared.
///
/// Progress describes what ran, never what failed: a refused stage does not
/// emit a completion, so the run reports the failing stage itself through
/// `failed(_:at:detail:)`. Nothing here infers a failure from silence.
final class SigningTimelineBox: @unchecked Sendable {

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var recorder = SigningTimelineRecorder()
    private var active: SigningOperationStage?

    /// How many nested targets the run's plan holds, when it reported one.
    private var nestedPlannedCount: Int?

    /// How many nested targets the run reported signing.
    private var nestedSignedCount = 0

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    /// Applies one progress event from the pipeline.
    ///
    /// Stage events are mapped onto the timeline's stages; nested-target
    /// events are counted, so the nested-signing entry can say how much it
    /// signed rather than repeating a sentence that says only that it ran.
    /// Both are reports of work that happened — an event that never arrives
    /// records nothing.
    func apply(_ event: ApplicationSigningProgressEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .stageStarted(let stage):
            recordBegan(SigningOperationCenter.pipelineStage(for: stage), at: now())
        case .stageCompleted(let stage):
            guard SigningOperationCenter.concludesTimelineStage(stage) else { return }
            let mapped = SigningOperationCenter.pipelineStage(for: stage)
            recordFinished(mapped, at: now(), detail: completionDetail(for: mapped))
        case .nestedPlan(let totals):
            nestedPlannedCount = totals.values.reduce(0, +)
        case .nestedItemSigned:
            nestedSignedCount += 1
        case .nestedItemStarted, .nestedItemRefused:
            // A target that began or refused is not a conclusion about the
            // stage: the stage's own completion, or the run's failure,
            // is what the timeline records.
            break
        }
    }

    /// The detail recorded when a timeline stage completes.
    ///
    /// Nested signing is the one stage the pipeline reports the size of, so
    /// its entry carries what was signed; every other stage uses its fixed
    /// sentence.
    private func completionDetail(for stage: SigningOperationStage) -> String? {
        guard stage == .nestedSigning else {
            return SigningOperationCenter.completionDetail(for: stage)
        }
        if nestedSignedCount > 0 {
            let signed = nestedSignedCount
            return "Signed \(signed) nested code target\(signed == 1 ? "" : "s")"
        }
        if let planned = nestedPlannedCount, planned == 0 {
            return "No nested code targets found"
        }
        return SigningOperationCenter.completionDetail(for: stage)
    }

    /// The timeline stage currently in flight, when one is.
    var activeStage: SigningOperationStage? {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func began(_ stage: SigningOperationStage, at instant: Date) {
        lock.lock()
        defer { lock.unlock() }
        recordBegan(stage, at: instant)
    }

    func finished(_ stage: SigningOperationStage, at instant: Date, detail: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        recordFinished(stage, at: instant, detail: detail)
    }

    /// Records a stage beginning. The caller holds the lock.
    private func recordBegan(_ stage: SigningOperationStage, at instant: Date) {
        recorder.began(stage, at: instant)
        active = stage
    }

    /// Records a stage finishing. The caller holds the lock.
    private func recordFinished(_ stage: SigningOperationStage, at instant: Date, detail: String?) {
        recorder.finished(stage, at: instant, detail: detail)
        if active == stage { active = nil }
    }

    func failed(_ stage: SigningOperationStage, at instant: Date, detail: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        recorder.failed(stage, at: instant, detail: detail)
        active = nil
    }

    func cancelledActiveStage(detail: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let stage = active else { return }
        recorder.cancelled(stage, at: now(), detail: detail)
        active = nil
    }

    func notRun(_ stage: SigningOperationStage, detail: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        recorder.notRun(stage, detail: detail)
    }

    func build() -> SigningTimeline {
        lock.lock()
        defer { lock.unlock() }
        return recorder.build()
    }
}
