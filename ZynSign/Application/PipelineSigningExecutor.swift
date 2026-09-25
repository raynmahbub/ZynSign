import Foundation

/// Runs one signing job through the nine-stage pipeline: the production
/// implementation of `SigningQueueExecuting`.
///
/// The executor owns the seam between the queue's job vocabulary and the
/// pipeline's run vocabulary. It derives the entitlement set from the job's
/// profile bytes, resolves the run's options, maps the pipeline's stage
/// reports onto the job's coarser stages, and turns the pipeline's result —
/// delivered evidence or a typed refusal — into the queue's outcome. Every
/// settled run is recorded in the signing history journal, succeeded,
/// failed, and cancelled alike, so the queue and the journal never disagree
/// about what happened.
///
/// Isolation is the executor's contract with concurrent safety: it reads
/// only the job's own source, writes only the job's own output, and the
/// pipeline creates a fresh unique working directory per attempt — so a
/// retry is always a clean run over untouched inputs, and no two jobs can
/// reach each other's files. A stale output from an earlier attempt of the
/// *same* job is removed before the run, which is the one file the executor
/// deletes.
struct PipelineSigningExecutor: SigningQueueExecuting {

    /// One pipeline run, as the executor drives it: the request, and the
    /// observer the pipeline calls at each stage boundary. Injectable so a
    /// test can double the run without a filesystem, a container, or a
    /// Keychain; the production initializer binds the real pipeline.
    typealias SigningRun = @Sendable (
        SignApplicationRequest,
        @Sendable (ApplicationSigningStage) -> Void
    ) async throws -> SignApplicationResult

    private let run: SigningRun
    private let history: (any SigningHistoryStore)?
    private let now: @Sendable () -> Date

    /// Builds the executor over the real pipeline and the history journal
    /// the composition root supplies. `history` is optional so a queue can
    /// run without a journal; nothing else changes.
    init(
        pipeline: SignApplicationPipeline,
        history: (any SigningHistoryStore)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.run = { request, stageObserver in
            try await pipeline.sign(request, reportingStage: stageObserver)
        }
        self.history = history
        self.now = now
    }

    /// Builds the executor over an injected run. Test seam; the production
    /// path uses the pipeline initializer above.
    init(
        run: @escaping SigningRun,
        history: (any SigningHistoryStore)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.run = run
        self.history = history
        self.now = now
    }

    func execute(
        _ request: SigningJobExecutionRequest,
        reporting progress: (any SigningJobProgressReporting)?
    ) async throws -> SigningJobExecutionOutcome {
        let startedAt = now()
        progress?.report(SigningJobProgress(stage: .preparing))

        // Derive the entitlement set from the job's own profile bytes. A
        // profile whose entitlements cannot be derived falls back to the
        // empty set, exactly as the inline signing screen does: the
        // pipeline's profile stage holds whatever set arrives against the
        // profile's policy and refuses when the profile requires claims.
        let entitlements: CodeSigningEntitlements
        if let derived = try? ProfileEntitlementDerivation.entitlements(fromProvisioningProfile: request.profile) {
            entitlements = derived
        } else if let empty = try? CodeSigningEntitlements(values: [:]) {
            entitlements = empty
        } else {
            let failure = SigningJobFailure(
                stage: .preparing,
                summary: "The entitlement set could not be created, so the run stopped before signing.",
                detail: "Neither the profile's entitlements nor the empty fallback set could be constructed.",
                category: .internalFailure,
                isRetryable: true,
                occurredAt: now()
            )
            await appendHistory(request, startedAt: startedAt, failure: failure)
            return .failed(failure)
        }

        // Locate the source before any heavy work: a job whose package file
        // has gone missing fails here, in plain words, rather than deep
        // inside the archive machinery.
        guard FileManager.default.fileExists(atPath: request.sourceURL.path) else {
            let failure = SigningJobFailure(
                stage: .preparing,
                summary: "The package file could not be found in ZynSign's storage.",
                detail: "The library artifact this job refers to is missing. Re-import the application, then queue it again.",
                category: .invalidInput,
                isRetryable: false,
                occurredAt: now()
            )
            await appendHistory(request, startedAt: startedAt, failure: failure)
            return .failed(failure)
        }

        // A clean run writes a clean output: remove this job's own stale
        // output from an earlier attempt, and make sure the delivery
        // directory exists. No other job's file is named here — output
        // names are unique per job.
        try? FileManager.default.removeItem(at: request.outputURL)
        try? FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var options = SignApplicationOptions()
        if request.emitDEREntitlements {
            options = SignApplicationOptions(emitDEREntitlements: true)
        }
        let pipelineRequest = SignApplicationRequest(
            sourceURL: request.sourceURL,
            profile: request.profile,
            identityID: request.identityID,
            entitlements: entitlements,
            outputURL: request.outputURL,
            options: options
        )

        // The last stage the pipeline reported, kept so an infrastructure
        // throw can be recorded against the stage the run actually reached
        // instead of a guess. Lock-guarded because the observer is called
        // from the run's own context.
        let reachedStage = StageBox()
        let stageObserver: @Sendable (ApplicationSigningStage) -> Void = { stage in
            let mapped = Self.jobStage(for: stage)
            reachedStage.set(mapped)
            progress?.report(SigningJobProgress(stage: mapped))
        }

        do {
            let result = try await run(pipelineRequest, stageObserver)
            switch result.status {
            case .signed:
                let completion = Self.completion(
                    from: result,
                    outputURL: request.outputURL,
                    finishedAt: now()
                )
                await appendHistory(request, startedAt: startedAt, completion: completion)
                return .completed(completion)
            case .failed:
                let failure = Self.failure(from: result.failure, reached: reachedStage.get(), at: now())
                await appendHistory(request, startedAt: startedAt, failure: failure)
                return .failed(failure)
            }
        } catch let cancellation as CancellationError {
            // A cancelled run delivers nothing: remove a partially written
            // output, record the cancellation in the journal, and let the
            // queue settle the job as cancelled.
            try? FileManager.default.removeItem(at: request.outputURL)
            await appendHistoryCancelled(request, startedAt: startedAt)
            throw cancellation
        } catch {
            let zynSignError = error as? ZynSignError
            let category = zynSignError?.category ?? .internalFailure
            let failure = SigningJobFailure(
                stage: reachedStage.get(),
                summary: Self.summary(for: category),
                detail: zynSignError?.userMessage ?? "Signing failed unexpectedly.",
                category: category,
                isRetryable: SigningJobFailure.isRetryable(category: category),
                occurredAt: now()
            )
            await appendHistory(request, startedAt: startedAt, failure: failure)
            return .failed(failure)
        }
    }

    // MARK: - Stage mapping

    /// Maps one pipeline stage onto the job stage the queue reports. The
    /// grouping is fixed: the two validation stages are one preflight,
    /// discovery travels with extraction, sealing travels with the main
    /// executable, and the rest map one to one.
    static func jobStage(for stage: ApplicationSigningStage) -> SigningJobStage {
        switch stage {
        case .integrity, .profile:
            return .preflight
        case .discovery, .extraction:
            return .extraction
        case .nestedSigning:
            return .signingFrameworks
        case .resourceSealing, .mainExecutable:
            return .signingApp
        case .packaging:
            return .packaging
        case .verification:
            return .verification
        }
    }

    // MARK: - Outcome mapping

    private static func completion(
        from result: SignApplicationResult,
        outputURL: URL,
        finishedAt: Date
    ) -> SigningJobCompletion {
        let byteCount: Int?
        if let values = try? outputURL.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
            byteCount = size
        } else {
            byteCount = nil
        }
        return SigningJobCompletion(
            outputFileName: outputURL.lastPathComponent,
            outputByteCount: byteCount,
            nestedItemCount: result.stages?.discovery.nestedItemCount,
            sealedFileCount: result.stages?.sealing.sealedFileCount,
            signatureByteCount: result.stages?.mainExecutable.signatureByteCount,
            // The pipeline delivers a container only after its independent
            // verification passed; a refused verification is a failure and
            // never reaches this point. Recorded explicitly so the detail
            // screen states the verification as evidence.
            verificationPassed: true,
            finishedAt: finishedAt
        )
    }

    private static func failure(
        from pipelineFailure: ApplicationSigningFailure?,
        reached: SigningJobStage,
        at occurredAt: Date
    ) -> SigningJobFailure {
        guard let pipelineFailure else {
            return SigningJobFailure(
                stage: reached,
                summary: "Signing failed without a typed refusal.",
                detail: nil,
                category: .internalFailure,
                isRetryable: true,
                occurredAt: occurredAt
            )
        }
        return SigningJobFailure(
            stage: jobStage(for: pipelineFailure.stage),
            summary: summary(for: pipelineFailure.category),
            detail: pipelineFailure.detail,
            category: pipelineFailure.category,
            isRetryable: SigningJobFailure.isRetryable(category: pipelineFailure.category),
            occurredAt: occurredAt
        )
    }

    /// The short explanation for one failure category, in fixed language.
    /// The stage badge says where; this says what it means; the pipeline's
    /// own detail remains available beneath both.
    static func summary(for category: DiagnosticCategory) -> String {
        switch category {
        case .invalidInput:
            return "The application or profile was refused on its content. Nothing was delivered."
        case .unsupportedInput:
            return "The application carries something this signing does not support. Nothing was delivered."
        case .ambiguousInput:
            return "The inputs admit more than one safe interpretation, so the run stopped."
        case .capabilityUnavailable:
            return "The signing identity is not available for signing right now."
        case .cancelled:
            return "The run was cancelled."
        case .storageFailure:
            return "Storage failed or ran out of space during the run."
        case .internalFailure:
            return "Signing failed unexpectedly. Nothing was delivered."
        }
    }

    // MARK: - History

    private func appendHistory(
        _ request: SigningJobExecutionRequest,
        startedAt: Date,
        completion: SigningJobCompletion
    ) async {
        await appendHistory(
            request,
            startedAt: startedAt,
            stoppingStage: SigningJobStage.verification.rawValue,
            errorCode: nil,
            outputFileName: completion.outputFileName,
            outputByteCount: completion.outputByteCount
        )
    }

    private func appendHistory(
        _ request: SigningJobExecutionRequest,
        startedAt: Date,
        failure: SigningJobFailure
    ) async {
        // A failure delivers nothing: no output name, no byte count, and
        // the journal's outcome derivation reads the stopping stage as the
        // failure it is.
        await appendHistory(
            request,
            startedAt: startedAt,
            stoppingStage: failure.stage.rawValue,
            errorCode: failure.category.rawValue,
            outputFileName: nil,
            outputByteCount: nil
        )
    }

    private func appendHistoryCancelled(
        _ request: SigningJobExecutionRequest,
        startedAt: Date
    ) async {
        // A cancellation records no stopping stage, which is exactly how
        // the journal distinguishes it from a failure; the duration
        // measures the time spent before the cancellation.
        await appendHistory(
            request,
            startedAt: startedAt,
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: nil,
            outputByteCount: nil
        )
    }

    private func appendHistory(
        _ request: SigningJobExecutionRequest,
        startedAt: Date,
        stoppingStage: String?,
        errorCode: String?,
        outputFileName: String?,
        outputByteCount: Int?
    ) async {
        guard let history else { return }
        let record = SigningRecord(
            presetID: request.presetID,
            certificateFingerprint: request.certificateFingerprint,
            sourceBundleIdentifier: request.bundleIdentifier,
            sourceDisplayName: request.applicationName,
            stoppingStage: stoppingStage,
            errorCode: errorCode,
            outputFileName: outputFileName,
            outputByteCount: outputByteCount,
            startedAt: startedAt,
            duration: max(0, now().timeIntervalSince(startedAt))
        )
        try? await history.append(record)
    }
}

/// The last stage a run reported, safe to touch from the run's context and
/// read from the executor's. One value behind one lock; nothing else.
private final class StageBox: @unchecked Sendable {

    private let lock = NSLock()
    private var value: SigningJobStage = .preparing

    func set(_ stage: SigningJobStage) {
        lock.lock()
        value = stage
        lock.unlock()
    }

    func get() -> SigningJobStage {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
