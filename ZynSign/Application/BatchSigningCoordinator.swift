import Foundation

/// What one batch step needs from the signing engine: a call that returns the
/// run's outcome, refusals included.
///
/// The coordinator depends on this rather than on `SignApplicationPipeline` so
/// the sequencing rules — a refusal is never counted as a delivery, one failure
/// does not stop the run, every step is recorded — can be exercised without
/// real packages on disk. `SignApplicationPipeline` is the only production
/// conformance.
protocol BatchSigningStep {
    func signApplication(_ request: SignApplicationRequest) async throws -> SignApplicationResult
}

extension SignApplicationPipeline: BatchSigningStep {
    func signApplication(_ request: SignApplicationRequest) async throws -> SignApplicationResult {
        try await sign(request)
    }
}

/// Sequences several signing runs over one configuration.
///
/// **Nothing constructs this type, and the release train no longer promises
/// it.** The capability it describes — sign a set of applications with one
/// identity and one profile, one after another — ships as the signing queue:
/// `SigningQueueConfigurationView` applies one configuration to a whole
/// selection, `SigningQueue` runs the jobs one at a time
/// (`maximumConcurrentJobs = 1`), and each run goes through
/// `SigningOperationCenter`, which owns working-copy isolation, export naming,
/// independent verification of the committed artifact, and the journal.
/// `ReleaseFeature.batchSigning` was retired for the same reason, so the
/// `v0.9.0-beta.3` stop exposes nothing new.
///
/// This type predates the operation center and duplicates part of it: it takes
/// the raw pipeline, chooses output names itself, and writes its own history
/// records, so a run driven through it would deliver and journal differently
/// from every other signed artifact in the app. A batch surface must not be
/// built on it without first retiring that duplication — two signing paths are
/// two answers to what "a signed application" is, and the architecture keeps
/// one.
///
/// The sequencing rules it does state correctly are worth keeping wherever the
/// next version of this lives: a refusal is never a delivery, one failure does
/// not stop the run, and every step is accounted for. `BatchSigningCoordinatorTests`
/// pins them here so the rules survive a rewrite.
actor BatchSigningCoordinator {

    /// The single-entry signing engine reused for every batch step.
    private let pipeline: any BatchSigningStep

    /// The signing history store that records every batch step.
    private let history: any SigningHistoryStore

    /// The factory that resolves an identity-store call into a
    /// `SignApplicationRequest`. Provided by the composition root so
    /// the coordinator does not know about the identity store.
    private let requestFactory: @Sendable (LibraryEntry, SigningIdentityIdentifier, Data) throws -> SignApplicationRequest

    /// The clock used to record timestamps. Injectable for tests.
    private let now: @Sendable () -> Date

    init(
        pipeline: any BatchSigningStep,
        history: any SigningHistoryStore,
        requestFactory: @escaping @Sendable (LibraryEntry, SigningIdentityIdentifier, Data) throws -> SignApplicationRequest,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pipeline = pipeline
        self.history = history
        self.requestFactory = requestFactory
        self.now = now
    }

    /// One batch run request: the identity to use, the profile bytes to
    /// embed, and the entries to sign.
    struct Request: Sendable {
        let identityID: SigningIdentityIdentifier
        let certificateFingerprint: CertificateFingerprint?
        let profile: Data
        let presetID: PresetIdentifier?
        let entries: [LibraryEntry]
        let outputDirectory: URL
        /// Options from the preset or the caller. Applied to every step so a
        /// DER preference is not dropped when the output URL is rewritten.
        let options: SignApplicationOptions

        init(
            identityID: SigningIdentityIdentifier,
            certificateFingerprint: CertificateFingerprint?,
            profile: Data,
            presetID: PresetIdentifier? = nil,
            entries: [LibraryEntry],
            outputDirectory: URL,
            options: SignApplicationOptions = SignApplicationOptions()
        ) {
            self.identityID = identityID
            self.certificateFingerprint = certificateFingerprint
            self.profile = profile
            self.presetID = presetID
            self.entries = entries
            self.outputDirectory = outputDirectory
            self.options = options
        }
    }

    /// One batch step result. Returned in the order the entries were
    /// submitted, so the UI can pair it with its row.
    struct StepResult: Sendable, Equatable {
        let entry: LibraryEntry
        let outcome: SigningRecord.Outcome
        let stoppingStage: String?
        let errorCode: String?
        let outputFileName: String?
        let outputByteCount: Int?
        let duration: TimeInterval
        /// A user-presentable failure, when the step failed. Nil on success
        /// and cancellation. Distinct from `errorCode`, which is diagnostic.
        let userMessage: String?
    }

    /// The aggregate result of a batch run: each step plus the total
    /// counts so the UI can render a summary without re-iterating.
    struct Result: Sendable {
        let steps: [StepResult]
        var succeededCount: Int { steps.filter { $0.outcome == .succeeded }.count }
        var failedCount: Int { steps.filter { $0.outcome == .failed }.count }
        var cancelledCount: Int { steps.filter { $0.outcome == .cancelled }.count }
    }

    /// Runs a batch signing request. Returns the ordered step results
    /// and appends one `SigningRecord` per step to the history.
    func run(_ request: Request) async throws -> Result {
        guard !request.entries.isEmpty else {
            throw ZynSignError.emptyBatchSigningRequest(
                diagnosticDetail: "Batch signing requires at least one application."
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: request.outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            // Non-fatal: the pipeline writes its outputs and may itself
            // create the directory; we still record every step.
        }
        var results: [StepResult] = []
        results.reserveCapacity(request.entries.count)
        for entry in request.entries {
            try Task.checkCancellation()
            let startedAt = now()
            let startMonotonic = Date()
            let step: StepResult
            do {
                let url = try await signOne(
                    entry: entry,
                    identityID: request.identityID,
                    profile: request.profile,
                    outputDirectory: request.outputDirectory,
                    optionsOverride: request.options
                )
                let duration = Date().timeIntervalSince(startMonotonic)
                let byteCount: Int?
                if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                    byteCount = size
                } else {
                    byteCount = nil
                }
                let record = SigningRecord(
                    presetID: request.presetID,
                    certificateFingerprint: request.certificateFingerprint,
                    sourceBundleIdentifier: entry.record.bundleIdentifier.rawValue,
                    sourceDisplayName: entry.record.displayName,
                    stoppingStage: "verification",
                    errorCode: nil,
                    outputFileName: url.lastPathComponent,
                    outputByteCount: byteCount,
                    startedAt: startedAt,
                    duration: duration,
                    sourceRecordIdentifier: entry.record.id.rawValue
                )
                let historyWarning: String?
                do {
                    try await history.append(record)
                    historyWarning = nil
                } catch {
                    historyWarning = "Signing succeeded, but its history record could not be saved."
                }
                step = StepResult(
                    entry: entry,
                    outcome: .succeeded,
                    stoppingStage: "verification",
                    errorCode: nil,
                    outputFileName: url.lastPathComponent,
                    outputByteCount: record.outputByteCount,
                    duration: duration,
                    userMessage: historyWarning
                )
            } catch is CancellationError {
                let duration = Date().timeIntervalSince(startMonotonic)
                let record = SigningRecord(
                    presetID: request.presetID,
                    certificateFingerprint: request.certificateFingerprint,
                    sourceBundleIdentifier: entry.record.bundleIdentifier.rawValue,
                    sourceDisplayName: entry.record.displayName,
                    stoppingStage: nil,
                    errorCode: nil,
                    outputFileName: nil,
                    outputByteCount: nil,
                    startedAt: startedAt,
                    duration: duration,
                    sourceRecordIdentifier: entry.record.id.rawValue
                )
                let historyWarning: String?
                do {
                    try await history.append(record)
                    historyWarning = nil
                } catch {
                    historyWarning = "The operation was cancelled, but its history record could not be saved."
                }
                step = StepResult(
                    entry: entry,
                    outcome: .cancelled,
                    stoppingStage: nil,
                    errorCode: nil,
                    outputFileName: nil,
                    outputByteCount: nil,
                    duration: duration,
                    userMessage: historyWarning
                )
            } catch {
                let duration = Date().timeIntervalSince(startMonotonic)
                let zynsignError = error as? ZynSignError
                let stage: String? = zynsignError?.diagnosticDetail
                let code: String? = zynsignError.map { String(describing: $0) }
                let userMessage = zynsignError?.userMessage ?? "Signing failed."
                let record = SigningRecord(
                    presetID: request.presetID,
                    certificateFingerprint: request.certificateFingerprint,
                    sourceBundleIdentifier: entry.record.bundleIdentifier.rawValue,
                    sourceDisplayName: entry.record.displayName,
                    stoppingStage: stage,
                    errorCode: code,
                    outputFileName: nil,
                    outputByteCount: nil,
                    startedAt: startedAt,
                    duration: duration,
                    sourceRecordIdentifier: entry.record.id.rawValue
                )
                let historyWarning: String?
                do {
                    try await history.append(record)
                    historyWarning = nil
                } catch {
                    historyWarning = "The signing failure was recorded in the batch result, but its history record could not be saved."
                }
                step = StepResult(
                    entry: entry,
                    outcome: .failed,
                    stoppingStage: stage,
                    errorCode: code,
                    outputFileName: nil,
                    outputByteCount: nil,
                    duration: duration,
                    userMessage: [userMessage, historyWarning].compactMap { $0 }.joined(separator: " ")
                )
            }
            results.append(step)
        }
        return Result(steps: results)
    }

    /// Signs one entry. Resolves the entry to a signable request via
    /// the supplied factory and forwards it to the pipeline.
    private func signOne(
        entry: LibraryEntry,
        identityID: SigningIdentityIdentifier,
        profile: Data,
        outputDirectory: URL,
        optionsOverride: SignApplicationOptions
    ) async throws -> URL {
        let safeName = Self.safeOutputName(for: entry)
        let outputURL = outputDirectory.appendingPathComponent(safeName)
        let request = try requestFactory(entry, identityID, profile)
            .with(outputURL: outputURL, options: optionsOverride)
        // The pipeline returns a refusal as a result rather than throwing, so
        // the status has to be read. Taking only the return value — as this
        // did — reports a refused package as a delivered one, and a batch
        // summary that counts refusals as successes is worse than the failure
        // it hides.
        let signed = try await pipeline.signApplication(request)
        guard signed.status == .signed else {
            throw ZynSignError(
                category: .invalidInput,
                userMessage: signed.failure?.detail ?? "Signing was refused. Nothing was delivered.",
                diagnosticDetail: signed.failure?.stage.rawValue
            )
        }
        return signed.outputURL ?? outputURL
    }

    /// Signs one already-built request and records it.
    ///
    /// Written for the signing queue and never adopted by it: the queue runs
    /// through `SigningOperationExecutor` and `SigningOperationCenter`, which
    /// also commit the artifact to export storage and verify it there. This
    /// entry point has no caller, which is why it shares the coordinator's
    /// fate rather than being kept beside the queue.
    ///
    /// Does not throw for a signing refusal. Cancellation and failure are
    /// step outcomes, so the queue can continue with the next compatible
    /// app. `CancellationError` is still reported as `.cancelled`.
    func runOne(
        entry: LibraryEntry,
        request: SignApplicationRequest,
        presetID: PresetIdentifier?,
        certificateFingerprint: CertificateFingerprint?
    ) async -> StepResult {
        let startedAt = now()
        let startMonotonic = Date()
        do {
            try Task.checkCancellation()
            let signed = try await pipeline.signApplication(request)
            guard signed.status == .signed else {
                throw ZynSignError(
                    category: .invalidInput,
                    userMessage: signed.failure?.detail ?? "Signing was refused. Nothing was delivered.",
                    diagnosticDetail: signed.failure.map { "Refused at \($0.stage.rawValue)." }
                )
            }
            let duration = Date().timeIntervalSince(startMonotonic)
            let byteCount = (try? request.outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let record = SigningRecord(
                presetID: presetID,
                certificateFingerprint: certificateFingerprint,
                sourceBundleIdentifier: entry.record.bundleIdentifier.rawValue,
                sourceDisplayName: entry.record.displayName,
                stoppingStage: "verification",
                errorCode: nil,
                outputFileName: request.outputURL.lastPathComponent,
                outputByteCount: byteCount,
                startedAt: startedAt,
                duration: duration
            )
            try? await history.append(record)
            return StepResult(
                entry: entry,
                outcome: .succeeded,
                stoppingStage: "verification",
                errorCode: nil,
                outputFileName: request.outputURL.lastPathComponent,
                outputByteCount: byteCount,
                duration: duration,
                userMessage: nil
            )
        } catch is CancellationError {
            let duration = Date().timeIntervalSince(startMonotonic)
            let record = SigningRecord(
                presetID: presetID,
                certificateFingerprint: certificateFingerprint,
                sourceBundleIdentifier: entry.record.bundleIdentifier.rawValue,
                sourceDisplayName: entry.record.displayName,
                stoppingStage: nil,
                errorCode: nil,
                outputFileName: nil,
                outputByteCount: nil,
                startedAt: startedAt,
                duration: duration
            )
            try? await history.append(record)
            return StepResult(
                entry: entry,
                outcome: .cancelled,
                stoppingStage: nil,
                errorCode: nil,
                outputFileName: nil,
                outputByteCount: nil,
                duration: duration,
                userMessage: nil
            )
        } catch {
            let duration = Date().timeIntervalSince(startMonotonic)
            let zynsignError = error as? ZynSignError
            let record = SigningRecord(
                presetID: presetID,
                certificateFingerprint: certificateFingerprint,
                sourceBundleIdentifier: entry.record.bundleIdentifier.rawValue,
                sourceDisplayName: entry.record.displayName,
                stoppingStage: zynsignError?.diagnosticDetail,
                errorCode: zynsignError.map { String(describing: $0) },
                outputFileName: nil,
                outputByteCount: nil,
                startedAt: startedAt,
                duration: duration
            )
            try? await history.append(record)
            return StepResult(
                entry: entry,
                outcome: .failed,
                stoppingStage: zynsignError?.diagnosticDetail,
                errorCode: zynsignError.map { String(describing: $0) },
                outputFileName: nil,
                outputByteCount: nil,
                duration: duration,
                userMessage: zynsignError?.userMessage ?? "Signing failed."
            )
        }
    }

    /// The output filename for a batch-signed entry: the bundle identifier
    /// with a `_signed_<short-hash>` suffix to avoid collisions.
    private static func safeOutputName(for entry: LibraryEntry) -> String {
        let bundle = entry.record.bundleIdentifier.rawValue
        let safeBundle = bundle.replacingOccurrences(of: "/", with: "_")
        let short = String(entry.record.id.rawValue.prefix(8))
        return "\(safeBundle)_signed_\(short).ipa"
    }
}

private extension SignApplicationRequest {
    /// Returns a copy of this request with the output location and options
    /// replaced. Options are replaced, not dropped: a preset's DER and team
    /// preferences have to survive the coordinator rewriting the file name.
    func with(outputURL: URL, options: SignApplicationOptions) -> SignApplicationRequest {
        SignApplicationRequest(
            sourceURL: sourceURL,
            profile: profile,
            identityID: identityID,
            entitlements: entitlements,
            outputURL: outputURL,
            options: options
        )
    }
}
