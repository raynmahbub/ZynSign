import Foundation

/// Coordinates a batch signing run: signing multiple applications with
/// the same identity and profile in sequence, recording each result in
/// the signing history, and emitting progress the UI can observe.
///
/// The coordinator does not replace the signing pipeline; it sequences
/// `SignApplicationPipeline` invocations and collects their results. The
/// pipeline itself remains the single source of truth for what "a signed
/// application" means.
///
/// Sequential execution is deliberate: signing is CPU- and I/O-heavy,
/// and parallel runs would multiply peak memory and battery cost. A
/// failed signing of one entry does not stop the run; the remaining
/// entries are still attempted, so a single bad bundle does not waste
/// the rest of the user's setup.
actor BatchSigningCoordinator {

    /// The single-entry pipeline reused for every batch step.
    private let pipeline: SignApplicationPipeline

    /// The signing history store that records every batch step.
    private let history: any SigningHistoryStore

    /// The factory that resolves an identity-store call into a
    /// `SignApplicationRequest`. Provided by the composition root so
    /// the coordinator does not know about the identity store.
    private let requestFactory: @Sendable (LibraryEntry, SigningIdentityIdentifier, Data) throws -> SignApplicationRequest

    /// The clock used to record timestamps. Injectable for tests.
    private let now: @Sendable () -> Date

    init(
        pipeline: SignApplicationPipeline,
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
                    duration: duration
                )
                try? await history.append(record)
                step = StepResult(
                    entry: entry,
                    outcome: .succeeded,
                    stoppingStage: "verification",
                    errorCode: nil,
                    outputFileName: url.lastPathComponent,
                    outputByteCount: record.outputByteCount,
                    duration: duration,
                    userMessage: nil
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
                    duration: duration
                )
                try? await history.append(record)
                step = StepResult(
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
                    duration: duration
                )
                try? await history.append(record)
                step = StepResult(
                    entry: entry,
                    outcome: .failed,
                    stoppingStage: stage,
                    errorCode: code,
                    outputFileName: nil,
                    outputByteCount: nil,
                    duration: duration,
                    userMessage: userMessage
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
        _ = try await pipeline.sign(request)
        return outputURL
    }

    /// Signs one already-built request and records it. The professional
    /// signing queue uses this so a preset's options, entitlements, and
    /// output location are the ones the queue prepared — not a second
    /// factory that could drop them.
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
            let signed = try await pipeline.sign(request)
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
