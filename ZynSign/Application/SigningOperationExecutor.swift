import Foundation

/// Runs one signing job as one signing operation: the production
/// implementation of `SigningQueueExecuting`.
///
/// The executor owns the seam between the queue's job vocabulary and the
/// signing operation's vocabulary. It resolves the job's library entry,
/// derives the entitlement set from the job's profile bytes, resolves the
/// run's options, maps the pipeline's progress events onto the job's coarser
/// stages, and turns the operation's outcome — an exported artifact, a
/// recorded failure, or a refusal before anything ran — into the queue's
/// outcome.
///
/// Delivery, isolation, and history belong to `SigningOperationCenter`, not
/// to the executor. The center works in a directory of its own per run,
/// commits the verified container to export storage under a name export
/// storage chooses and refuses to overwrite, verifies the committed artifact
/// independently, and journals every run it executes — succeeded, failed,
/// and cancelled alike. A queued job therefore appears in the Export Center
/// and the signing history exactly like any other signing operation, and the
/// queue and the journal can never disagree about what happened, because the
/// queue does not write the journal at all.
///
/// A retry is always a clean run over untouched inputs: every attempt is a
/// fresh operation with a fresh working directory, the source container is
/// only ever read, and an earlier attempt that failed delivered nothing.
struct SigningOperationExecutor: SigningQueueExecuting {

    /// One signing operation, as the executor drives it: the request, and
    /// the observer the operation forwards the pipeline's progress events
    /// to. Injectable so a test can double the operation without a
    /// filesystem, a container, or a Keychain; the production initializer
    /// binds the real center.
    typealias OperationRun = @Sendable (
        SigningOperationRequest,
        @escaping ApplicationSigningProgressObserver
    ) async throws -> SigningOperationOutcome

    /// Resolves a library record to its current entry, or `nil` when the
    /// library no longer lists it.
    typealias EntryResolver = @Sendable (ApplicationRecordIdentifier) async throws -> LibraryEntry?

    private let run: OperationRun
    private let resolveEntry: EntryResolver
    private let now: @Sendable () -> Date

    /// Builds the executor over the real signing operation center and the
    /// library the composition root supplies.
    init(
        operations: SigningOperationCenter,
        library: ApplicationLibrary,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.run = { request, observer in
            try await operations.run(request, observer: observer)
        }
        self.resolveEntry = { id in
            try await library.entry(withID: id)
        }
        self.now = now
    }

    /// Builds the executor over an injected operation and entry resolver.
    /// Test seam; the production path uses the initializer above.
    init(
        run: @escaping OperationRun,
        resolveEntry: @escaping EntryResolver,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.run = run
        self.resolveEntry = resolveEntry
        self.now = now
    }

    func execute(
        _ request: SigningJobExecutionRequest,
        reporting progress: (any SigningJobProgressReporting)?
    ) async throws -> SigningJobExecutionOutcome {
        progress?.report(SigningJobProgress(stage: .preparing))

        // Resolve the application as the library lists it *now*. A job that
        // waited while its application was removed fails here, in plain
        // words, rather than signing a package nothing refers to any more.
        let entry: LibraryEntry
        do {
            guard let resolved = try await resolveEntry(request.recordID) else {
                return .failed(SigningJobFailure(
                    stage: .preparing,
                    summary: "This application is no longer in the library.",
                    detail: "The library record this job refers to was removed. Re-import the application, then queue it again.",
                    category: .invalidInput,
                    isRetryable: false,
                    occurredAt: now()
                ))
            }
            entry = resolved
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let category = (error as? ZynSignError)?.category ?? .storageFailure
            return .failed(SigningJobFailure(
                stage: .preparing,
                summary: "The library could not be read, so the run stopped before signing.",
                detail: (error as? ZynSignError)?.userMessage,
                category: category,
                isRetryable: SigningJobFailure.isRetryable(category: category),
                occurredAt: now()
            ))
        }
        try Task.checkCancellation()

        // Derive the entitlement set from the job's own profile bytes. A
        // profile whose entitlements cannot be derived falls back to the
        // empty set: the pipeline's profile stage holds whatever set arrives
        // against the profile's policy and refuses when the profile requires
        // claims the set does not carry.
        let entitlements: CodeSigningEntitlements
        if let derived = try? ProfileEntitlementDerivation.entitlements(fromProvisioningProfile: request.profile) {
            entitlements = derived
        } else if let empty = try? CodeSigningEntitlements(values: [:]) {
            entitlements = empty
        } else {
            return .failed(SigningJobFailure(
                stage: .preparing,
                summary: "The entitlement set could not be created, so the run stopped before signing.",
                detail: "Neither the profile's entitlements nor the empty fallback set could be constructed.",
                category: .internalFailure,
                isRetryable: true,
                occurredAt: now()
            ))
        }

        var options = SignApplicationOptions()
        if request.emitDEREntitlements {
            options = SignApplicationOptions(emitDEREntitlements: true)
        }
        let operationRequest = SigningOperationRequest(
            entry: entry,
            sourceURL: request.sourceURL,
            profile: request.profile,
            provisioningProfileName: request.profileDisplayName,
            identityID: request.identityID,
            certificateDisplayName: request.identityDisplayName,
            certificateFingerprint: request.certificateFingerprint,
            entitlements: entitlements,
            options: options,
            presetID: request.presetID
        )

        // The furthest stage the pipeline reported and the plan's nested
        // total, kept so a failure can be placed at the stage the run
        // actually reached and a completion can state how much nested code
        // was signed. Lock-guarded because the observer is called from the
        // run's own context.
        let tracker = RunTracker()
        let observer: ApplicationSigningProgressObserver = { event in
            guard let observed = tracker.apply(event) else { return }
            progress?.report(observed)
        }

        let outcome: SigningOperationOutcome
        do {
            outcome = try await run(operationRequest, observer)
        } catch is CancellationError {
            // The operation journals the cancellation and removes its own
            // working directory before it rethrows; nothing was committed.
            throw CancellationError()
        } catch {
            let zynSignError = error as? ZynSignError
            let category = zynSignError?.category ?? .internalFailure
            return .failed(SigningJobFailure(
                stage: tracker.reachedStage,
                summary: Self.summary(for: category),
                detail: zynSignError?.userMessage ?? "Signing failed unexpectedly.",
                category: category,
                isRetryable: SigningJobFailure.isRetryable(category: category),
                occurredAt: now()
            ))
        }

        switch outcome {
        case .exported(let record, _, _):
            return .completed(SigningJobCompletion(
                outputFileName: record.fileName,
                outputByteCount: record.byteCount,
                nestedItemCount: tracker.nestedPlannedCount,
                // The operation delivers a container only after the run's
                // own independent verification passed; a refused
                // verification is a failure and never reaches this point.
                verificationPassed: true,
                finishedAt: now(),
                exportIdentifier: record.id.rawValue,
                exportVerification: record.verificationStatus
            ))

        case .failed(_, let summary):
            let category = DiagnosticCategory(rawValue: summary.category) ?? .internalFailure
            return .failed(SigningJobFailure(
                stage: Self.jobStage(for: summary.stage, reached: tracker.reachedStage),
                summary: Self.summary(for: category),
                detail: summary.explanation,
                category: category,
                isRetryable: SigningJobFailure.isRetryable(category: category),
                occurredAt: now()
            ))

        case .cancelled:
            // The operation reports a cancellation it observed as a value on
            // some paths; the queue settles every cancellation the same way.
            throw CancellationError()

        case .refused(let refusal):
            return .failed(Self.failure(for: refusal, at: now()))
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

    /// Maps the stage a signing operation recorded its failure at onto the
    /// job stage the queue shows. The operation's timeline groups discovery,
    /// extraction, and nested signing into one stage; when the run's own
    /// progress places the failure more precisely inside that group, the
    /// more precise stage wins. An export refusal happens after the run's
    /// verification, so it is shown against verification — the last stage
    /// the job lists.
    static func jobStage(for stage: SigningOperationStage, reached: SigningJobStage) -> SigningJobStage {
        switch stage {
        case .importSource:
            return .preparing
        case .validation, .preflight:
            return .preflight
        case .nestedSigning:
            return reached == .extraction ? .extraction : .signingFrameworks
        case .mainSigning:
            return .signingApp
        case .packaging:
            return .packaging
        case .verification, .export:
            return .verification
        }
    }

    // MARK: - Outcome mapping

    /// The job failure for a refusal: the operation never started, so the
    /// failure sits at the preparing stage and nothing was journaled.
    static func failure(for refusal: SigningOperationRefusal, at occurredAt: Date) -> SigningJobFailure {
        switch refusal {
        case .sourceUnavailable:
            return SigningJobFailure(
                stage: .preparing,
                summary: "The package file could not be found in ZynSign's storage.",
                detail: refusal.message,
                category: .invalidInput,
                isRetryable: false,
                occurredAt: occurredAt
            )
        case .insufficientStorage:
            return SigningJobFailure(
                stage: .preparing,
                summary: "There is not enough free space to sign this application.",
                detail: refusal.message,
                category: .storageFailure,
                isRetryable: true,
                occurredAt: occurredAt
            )
        case .workspaceUnavailable:
            return SigningJobFailure(
                stage: .preparing,
                summary: "A working directory for this job could not be prepared.",
                detail: refusal.message,
                category: .storageFailure,
                isRetryable: true,
                occurredAt: occurredAt
            )
        }
    }

    /// The short explanation for one failure category, in fixed language.
    /// The stage badge says where; this says what it means; the operation's
    /// own explanation remains available beneath both.
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
}

/// What one run has reported so far: the furthest job stage reached and the
/// nested plan's size. Safe to update from the run's context and read from
/// the executor's; one small value behind one lock.
private final class RunTracker: @unchecked Sendable {

    private let lock = NSLock()
    private var stage: SigningJobStage = .preparing
    private var nestedTotal: Int?
    private var nestedSigned = 0

    /// The furthest job stage the run has reported.
    var reachedStage: SigningJobStage {
        lock.lock()
        defer { lock.unlock() }
        return stage
    }

    /// How many nested targets the run's validated plan signs, once the
    /// plan exists.
    var nestedPlannedCount: Int? {
        lock.lock()
        defer { lock.unlock() }
        return nestedTotal
    }

    /// Applies one pipeline event and returns the job progress it
    /// establishes, or `nil` when the event establishes nothing new. The
    /// stage never moves backwards: the pipeline reports stages in order,
    /// and a late or duplicate event cannot rewind what the job shows.
    func apply(_ event: ApplicationSigningProgressEvent) -> SigningJobProgress? {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .stageStarted(let pipelineStage):
            let mapped = SigningOperationExecutor.jobStage(for: pipelineStage)
            guard mapped.isAtOrAfter(stage) else { return nil }
            stage = mapped
            if mapped == .signingFrameworks, let nestedTotal, nestedTotal > 0 {
                return SigningJobProgress(
                    stage: mapped,
                    completedUnitCount: nestedSigned,
                    totalUnitCount: nestedTotal
                )
            }
            return SigningJobProgress(stage: mapped)

        case .nestedPlan(let totals):
            nestedTotal = totals.values.reduce(0, +)
            return nil

        case .nestedItemSigned(_, let total, _, _):
            // Countable work, counted as it is done: the frameworks stage
            // advances by one signed target at a time, never by a guess.
            nestedSigned += 1
            guard stage == .signingFrameworks, total > 0 else { return nil }
            return SigningJobProgress(
                stage: .signingFrameworks,
                completedUnitCount: min(nestedSigned, total),
                totalUnitCount: total
            )

        case .stageCompleted, .nestedItemStarted, .nestedItemRefused:
            return nil
        }
    }
}
