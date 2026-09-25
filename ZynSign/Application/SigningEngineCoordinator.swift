import Foundation

/// One signing-engine run's inputs.
///
/// The request states the same information the pipeline needs, once: the
/// container to sign, the identity, the profile, the entitlement set, where
/// the container is delivered, and the run's options.
struct SigningEngineRequest {

    /// The imported container to sign. Read but never modified.
    let sourceURL: URL

    /// The replacement profile bytes to embed and validate.
    let profile: Data

    /// The signing identity to sign with.
    let identityID: SigningIdentityIdentifier

    /// The entitlement set to embed in the main executable.
    let entitlements: CodeSigningEntitlements

    /// Where the signed, verified container is delivered.
    let outputURL: URL

    /// The run's options.
    let options: SignApplicationOptions

    init(
        sourceURL: URL,
        profile: Data,
        identityID: SigningIdentityIdentifier,
        entitlements: CodeSigningEntitlements,
        outputURL: URL,
        options: SignApplicationOptions = SignApplicationOptions()
    ) {
        self.sourceURL = sourceURL
        self.profile = profile
        self.identityID = identityID
        self.entitlements = entitlements
        self.outputURL = outputURL
        self.options = options
    }

    /// The same request, stated in the pipeline's vocabulary.
    var applicationRequest: SignApplicationRequest {
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

/// The outcome of one signing-engine run.
///
/// Success carries the delivered container, every stage's structured outcome,
/// the run's summary, and the expectations an independent re-verification of
/// the delivered container needs. Failure carries the refusing stage with its
/// typed reason and the recovery facts: whether the original survived
/// untouched, whether the working copy was discarded, and what happened at
/// the delivery location.
struct SigningEngineResult {

    /// Whether the run delivered a container.
    let status: SigningEngineStatus

    /// The delivered container's location on the success path.
    let outputURL: URL?

    /// Every stage's structured outcome, in execution order.
    let stages: [SigningEngineStageOutcome]

    /// The run's summary on the success path.
    let summary: SigningEngineSummary?

    /// The refusing stage and its typed reason on the failure path.
    let failure: SigningEngineFailure?

    /// What an independent re-verification of the delivered container must
    /// hold it to. Carried so **Verify Again** does not need the run's inputs
    /// again.
    let expectations: SignedApplicationExpectations?

    /// The independent verification of the signed working copy.
    let verification: SigningEngineVerificationReport?

    /// The independent verification of the delivered container.
    let containerVerification: VerifySignedApplicationReport?

    /// What discarding the working copy reclaimed, and whether the original
    /// was found unchanged.
    let workingCopy: SigningWorkingCopyReport?

    /// The run's final progress snapshot, for details and diagnostics.
    let progress: SigningEngineProgress

    /// Whether re-running with the same inputs could plausibly succeed.
    var isRetryable: Bool { failure?.isRetryable ?? false }

    /// The stages that failed, in execution order.
    var failedStages: [SigningEngineStage] {
        stages.filter { $0.status == .failed }.map(\.stage)
    }

    /// The outcome recorded for one stage, when the run reached it.
    func outcome(for stage: SigningEngineStage) -> SigningEngineStageOutcome? {
        stages.first { $0.stage == stage }
    }
}

/// Executes one complete on-device signing pipeline.
///
/// The coordinator owns the order of the run and every safety property the
/// order exists to provide:
///
/// 1. **Preparing** — an isolated working copy is created under its own,
///    freshly named directory, and the original container is fingerprinted.
/// 2. **Validating** — the bundle is validated through the ordinary read-only
///    archive boundary: structure, information file, declared executable,
///    required files, nested readability, and supported layout. The run stops
///    here, before signing anything, when validation refuses.
/// 3. **Signing nested code** — frameworks, dynamic libraries, extensions, and
///    nested applications are signed through the pipeline's validated plan,
///    which orders every child before its container.
/// 4. **Signing the application** — the bundle's resources are sealed and the
///    main executable is signed with the selected identity, embedded profile,
///    and entitlements.
/// 5. **Verifying** — the signed working copy is re-read and verified against
///    freshly derived values; nothing the signing stages computed is trusted.
/// 6. **Packaging** — the verified bundle is rebuilt as a deterministic
///    `Payload/` container outside the delivery location, that container is
///    verified again, and only a container that passed is moved into place.
///
/// Failure is a value, not an exception, except for cancellation: a failing
/// run stops at the failing stage, discards its working copy, delivers
/// nothing, leaves the original untouched, and returns the stage's typed
/// reason with the recovery facts attached.
struct SigningEngineCoordinator {

    /// The signing pipeline whose stages the run drives.
    private let pipeline: SignApplicationPipeline

    /// The pre-signing bundle validator.
    private let validator: SigningEngineBundleValidator

    /// The independent verifier of the signed working copy.
    private let workingCopyVerifier: SigningEngineVerifier

    /// The independent verifier of a written container.
    private let containerVerifier: VerifySignedApplication

    /// The digest mechanism the working copy fingerprints with.
    private let digest: any MessageDigest

    /// Where working copies are created, when the caller establishes a root.
    private let workingDirectoryRoot: URL?

    /// The clock the run measures itself with. Injectable so progress and
    /// estimates are testable without waiting.
    private let now: @Sendable () -> Date

    private let fileManager: FileManager

    init(
        pipeline: SignApplicationPipeline,
        validator: SigningEngineBundleValidator,
        workingCopyVerifier: SigningEngineVerifier,
        containerVerifier: VerifySignedApplication,
        digest: any MessageDigest,
        workingDirectoryRoot: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pipeline = pipeline
        self.validator = validator
        self.workingCopyVerifier = workingCopyVerifier
        self.containerVerifier = containerVerifier
        self.digest = digest
        self.workingDirectoryRoot = workingDirectoryRoot
        self.fileManager = fileManager
        self.now = now
    }

    /// Runs one complete signing pipeline.
    ///
    /// - Parameters:
    ///   - request: The run's inputs.
    ///   - progress: Receives a snapshot whenever the run advances. Called on
    ///     the run's own execution context; a caller rendering it marshals it
    ///     to its own actor.
    /// - Returns: The run's outcome: a delivered container with every stage's
    ///   evidence, or the refusing stage with a typed reason and the recovery
    ///   facts.
    /// - Throws: `CancellationError` when the run is cancelled. Every other
    ///   failure is a returned result, never a thrown error.
    func sign(
        _ request: SigningEngineRequest,
        progress: ((SigningEngineProgress) -> Void)? = nil
    ) async throws -> SigningEngineResult {
        let tracker = SigningEngineProgressTracker()
        let startedAt = now()
        let outputExistedBeforeRun = fileManager.fileExists(atPath: request.outputURL.path)
        var stageStartedAt: [SigningEngineStage: Date] = [:]
        var stageMetrics: [SigningEngineStage: SigningEngineStageMetrics] = [:]
        var workingCopy: SigningWorkingCopy?

        func publish() {
            progress?(tracker.snapshot(elapsed: now().timeIntervalSince(startedAt)))
        }
        func note(_ detail: String, at stage: SigningEngineStage) {
            tracker.note(detail, at: stage)
            publish()
        }
        func begin(_ stage: SigningEngineStage, detail: String) {
            tracker.begin(stage)
            if stageStartedAt[stage] == nil { stageStartedAt[stage] = now() }
            note(detail, at: stage)
        }
        func finish(_ stage: SigningEngineStage, detail: String, metrics: SigningEngineStageMetrics) {
            tracker.note(detail, at: stage)
            tracker.complete(stage)
            stageMetrics[stage] = metrics
            publish()
        }
        func fail(
            _ stage: SigningEngineStage,
            _ detail: String,
            _ category: DiagnosticCategory,
            _ userMessage: String
        ) -> SigningEngineResult {
            end(
                stage: stage,
                detail: detail,
                category: category,
                userMessage: userMessage,
                tracker: tracker,
                workingCopy: workingCopy,
                outputExistedBeforeRun: outputExistedBeforeRun,
                startedAt: startedAt,
                stageStartedAt: stageStartedAt,
                stageMetrics: stageMetrics,
                now: now
            )
        }

        // Even direct engine callers must not allocate a working copy or
        // attempt a private-key operation for an option the signer lacks.
        if request.options.emitDEREntitlements {
            return fail(
                .validating,
                "DER entitlements are not embedded by this signing pipeline.",
                .unsupportedInput,
                "DER entitlements are not available in this build."
            )
        }

        do {
            // 1. Preparing — an isolated working copy, and the original's
            //    fingerprint, before anything else touches the container.
            begin(.preparing, detail: "Creating an isolated working copy")
            let copy = try SigningWorkingCopy(
                sourceURL: request.sourceURL,
                digest: digest,
                rootDirectory: workingDirectoryRoot,
                fileManager: fileManager
            )
            workingCopy = copy
            finish(
                .preparing,
                detail: "Working copy created; the original (\(copy.sourceFingerprint.byteCount) bytes) was fingerprinted and left untouched.",
                metrics: .none
            )

            // 2. Validating — structure, information file, executable,
            //    nested readability, and supported layout, all before a byte
            //    is signed. The pipeline's own pre-signing stages run inside
            //    this stage; their events carry the detail the interface
            //    shows while they run.
            begin(.validating, detail: "Validating the bundle before signing")
            let validation = try validator.validate(
                containerURL: request.sourceURL,
                existingSignaturePolicy: request.options.existingSignaturePolicy
            )
            guard validation.isAccepted else {
                let failing = validation.failure
                return fail(
                    .validating,
                    failing.map { "\($0.title): \($0.detail)" } ?? "The bundle failed validation.",
                    .unsupportedInput,
                    "This package is not one ZynSign can sign."
                )
            }

            var nestedPlanTotals: [NestedCodeKind: Int] = [:]
            let pipelineObserver: ApplicationSigningProgressObserver = { event in
                switch event {
                case .stageStarted(.integrity):
                    note("Reading the container's structure", at: .validating)
                case .stageStarted(.profile):
                    note("Validating the provisioning profile and identity", at: .validating)
                case .stageStarted(.discovery):
                    note("Discovering nested code and its signing order", at: .validating)
                case .stageStarted(.extraction):
                    note("Extracting into the working copy", at: .validating)
                case .stageCompleted(.extraction):
                    let total = nestedPlanTotals.values.reduce(0, +)
                    note(
                        "Working copy ready; \(total) nested target(s) to sign",
                        at: .validating
                    )
                    tracker.complete(.validating)
                    publish()
                case .nestedPlan(let totals):
                    nestedPlanTotals = totals
                    tracker.setNestedTotals(totals)
                    publish()
                case .nestedItemStarted(let order, let total, let kind, let path):
                    tracker.beginNestedItem(kind: kind, path: path, order: order, total: total)
                    if let stage = SigningEngineStage.nestedSigningStage(for: kind), stageStartedAt[stage] == nil {
                        stageStartedAt[stage] = now()
                    }
                    publish()
                case .nestedItemSigned(let order, let total, let kind, let path):
                    tracker.completeNestedItem(kind: kind, path: path, order: order, total: total)
                    publish()
                case .nestedItemRefused(_, _, let kind, let path):
                    tracker.refuseNestedItem(
                        kind: kind,
                        path: path,
                        detail: "The nested target could not be signed."
                    )
                    publish()
                case .stageStarted(.resourceSealing):
                    begin(.signingApplication, detail: "Sealing the bundle's resources")
                case .stageStarted(.mainExecutable):
                    note("Signing the main executable", at: .signingApplication)
                case .stageCompleted(.mainExecutable):
                    note("Main executable signed", at: .signingApplication)
                case .stageStarted(.nestedSigning),
                     .stageCompleted(.integrity),
                     .stageCompleted(.profile),
                     .stageCompleted(.discovery),
                     .stageCompleted(.nestedSigning),
                     .stageCompleted(.resourceSealing),
                     .stageStarted(.packaging),
                     .stageCompleted(.packaging),
                     .stageStarted(.verification),
                     .stageCompleted(.verification):
                    break
                }
            }

            let signed: ApplicationSigningSignedWorkingCopy
            do {
                signed = try await pipeline.signUpToMainExecutable(
                    request.applicationRequest,
                    observer: pipelineObserver,
                    workingRoot: copy.workDirectory.deletingLastPathComponent()
                )
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch let failure as ApplicationSigningFailure {
                return fail(
                    Self.engineStage(for: failure.stage, tracker: tracker),
                    "\(failure.stage.rawValue): \(failure.detail)",
                    failure.category,
                    failure.detail
                )
            } catch let error as ZynSignError {
                return fail(
                    tracker.snapshot(elapsed: 0).currentStage ?? .validating,
                    error.debugDescription,
                    error.category,
                    error.userMessage
                )
            }

            let validatingMetrics = SigningEngineStageMetrics(
                entryCount: signed.reports.integrity.entryCount,
                nestedTargetCount: signed.reports.discovery.nestedItemCount,
                signedBinaryCount: signed.reports.nested.successfullySignedCount
            )
            stageMetrics[.validating] = validatingMetrics
            note(
                "Validated \(validation.checks.count) checks; \(signed.reports.discovery.nestedItemCount) nested target(s) discovered.",
                at: .validating
            )
            for stage in SigningEngineStage.allCases where stage.isNestedSigningStage {
                guard let kind = stage.nestedCodeKind else { continue }
                stageMetrics[stage] = SigningEngineStageMetrics(
                    nestedTargetCount: signed.reports.discovery.nestedTargets.filter { $0.kind == kind }.count
                )
            }
            stageMetrics[.signingApplication] = SigningEngineStageMetrics(
                signedBinaryCount: 1,
                sealedResourceCount: signed.reports.sealing.sealedFileCount,
                signatureByteCount: signed.reports.mainExecutable.signatureByteCount
            )

            // 3. Verifying — the signed working copy, re-read and held to
            //    freshly derived values. Nothing the signing stages computed
            //    is taken on trust.
            begin(.verifying, detail: "Re-reading every signed artifact")
            let material = SigningEngineVerificationMaterial(
                bundleName: signed.bundleName,
                bundleIdentifier: signed.reports.integrity.bundleIdentifier,
                executableName: signed.reports.integrity.executableName,
                executablePath: signed.reports.integrity.executablePath,
                nestedTargets: signed.reports.discovery.nestedTargets.map { target in
                    SigningEngineVerificationMaterial.NestedTarget(
                        executablePath: target.executablePath,
                        bundleIdentifier: target.bundleIdentifier
                    )
                },
                identityID: request.identityID,
                teamIdentifier: request.options.teamIdentifier,
                profileBytes: request.profile,
                entitlements: request.entitlements,
                sealBytes: signed.expectations.sealedCodeResources
            )
            let verification = workingCopyVerifier.verify(
                bundleDirectory: signed.bundleDirectory,
                material: material
            )
            guard verification.passed else {
                return fail(
                    .verifying,
                    "Independent verification refused the signed bundle: \(verification.failedCheckNames.joined(separator: ", ")).",
                    .internalFailure,
                    "The signed bundle did not verify, so nothing was delivered."
                )
            }
            finish(
                .verifying,
                detail: "\(verification.checks.count) independent checks passed on the signed working copy.",
                metrics: SigningEngineStageMetrics(
                    verificationCheckCount: verification.checks.count,
                    verificationPassedCount: verification.passedCheckCount
                )
            )

            // 4. Packaging — only a verified bundle is packaged; the written
            //    container is verified again, and only a container that
            //    passed is moved into the delivery location. A run that
            //    fails here leaves whatever was already there untouched.
            begin(.packaging, detail: "Building the deterministic Payload/ container")
            let scratchContainer = copy.scratchURL(named: "\(signed.bundleName)-signed.ipa")
            let packagingObserver: ApplicationSigningProgressObserver = { event in
                switch event {
                case .stageStarted(.packaging):
                    note("Writing Payload/\(signed.bundleName)", at: .packaging)
                case .stageStarted(.verification):
                    note("Validating the written container", at: .packaging)
                default:
                    break
                }
            }
            let packaging: PackageSignedApplicationReport
            let containerVerification: VerifySignedApplicationReport
            do {
                packaging = try await pipeline.package(
                    signed,
                    outputURL: scratchContainer,
                    observer: packagingObserver
                )
                containerVerification = try await containerVerifier.verify(
                    containerURL: scratchContainer,
                    expectations: signed.expectations
                )
                guard containerVerification.passed else {
                    return fail(
                        .packaging,
                        "The written container failed independent verification: \(containerVerification.checks.filter { !$0.passed }.map(\.name).joined(separator: ", ")).",
                        .internalFailure,
                        "The packaged container did not verify, so nothing was delivered."
                    )
                }
                try Task.checkCancellation()
                try Self.deliver(scratchContainer, to: request.outputURL, fileManager: fileManager)
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch let failure as ApplicationSigningFailure {
                return fail(
                    Self.engineStage(for: failure.stage, tracker: tracker),
                    "\(failure.stage.rawValue): \(failure.detail)",
                    failure.category,
                    failure.detail
                )
            } catch {
                let error = error as? ZynSignError
                return fail(
                    .packaging,
                    error?.debugDescription ?? "The container could not be packaged.",
                    error?.category ?? .internalFailure,
                    error?.userMessage ?? "The signed container could not be delivered."
                )
            }
            finish(
                .packaging,
                detail: "Container written with \(packaging.entryCount) entries, verified (\(containerVerification.checks.count) checks), and delivered.",
                metrics: SigningEngineStageMetrics(
                    entryCount: packaging.entryCount,
                    verificationCheckCount: containerVerification.checks.count,
                    verificationPassedCount: containerVerification.checks.filter(\.passed).count,
                    containerByteCount: packaging.outputBytes
                )
            )

            // 5. Complete — the working copy is discarded, and its removal
            //    together with the original's preservation is reported.
            let cleanup = copy.discard()
            workingCopy = nil
            tracker.note(
                "Delivered \(request.outputURL.lastPathComponent); working copy discarded, original unchanged.",
                at: .complete
            )
            tracker.complete(.complete)
            publish()

            let summary = SigningEngineSummary(
                bundleName: signed.bundleName,
                bundleIdentifier: signed.reports.integrity.bundleIdentifier.rawValue,
                executableName: signed.reports.integrity.executableName,
                entryCount: packaging.entryCount,
                nestedTargetCount: signed.reports.discovery.nestedItemCount,
                signedBinaryCount: signed.reports.nested.successfullySignedCount + 1,
                sealedResourceCount: signed.reports.sealing.sealedFileCount,
                containerByteCount: packaging.outputBytes,
                verificationCheckCount: verification.checks.count + containerVerification.checks.count,
                verificationPassedCount: verification.passedCheckCount + containerVerification.checks.filter(\.passed).count,
                duration: now().timeIntervalSince(startedAt)
            )
            return SigningEngineResult(
                status: .signed,
                outputURL: request.outputURL,
                stages: Self.stageOutcomes(
                    from: tracker,
                    startedAt: stageStartedAt,
                    metrics: stageMetrics,
                    completedAt: now()
                ),
                summary: summary,
                failure: nil,
                expectations: signed.expectations,
                verification: verification,
                containerVerification: containerVerification,
                workingCopy: cleanup,
                progress: tracker.snapshot(elapsed: now().timeIntervalSince(startedAt))
            )
        } catch let cancellation as CancellationError {
            // Cancellation is not a failure result: the run discards its
            // working copy, delivers nothing, and rethrows.
            _ = workingCopy?.discard()
            throw cancellation
        } catch {
            return fail(
                tracker.snapshot(elapsed: 0).currentStage ?? .preparing,
                (error as? ZynSignError)?.debugDescription ?? "The signing run failed unexpectedly.",
                (error as? ZynSignError)?.category ?? .internalFailure,
                (error as? ZynSignError)?.userMessage ?? "The signing run failed."
            )
        }
    }

    /// Verifies an already delivered container again, independently.
    ///
    /// The re-verification is the same fresh read the run's packaging stage
    /// performed: the container is reopened through the archive boundary, and
    /// its structure, profile bytes, seal bytes, seal digests, executable
    /// signatures, embedded entitlements, and slot-3 binding are all
    /// re-checked against the expectations the run captured. No signing state
    /// is reused, and a failed re-verification changes nothing: the delivered
    /// container is read, never removed.
    func verifyAgain(
        containerURL: URL,
        expectations: SignedApplicationExpectations
    ) async throws -> VerifySignedApplicationReport {
        try await containerVerifier.verify(containerURL: containerURL, expectations: expectations)
    }

    // MARK: - Failure recovery

    /// Ends the run at `stage`: the stage is marked failed, the working copy
    /// is discarded, and the original's preservation is re-measured rather
    /// than assumed. The delivery location is not touched — nothing was
    /// written there, since a container is only moved into place after it has
    /// been verified.
    private func end(
        stage: SigningEngineStage,
        detail: String,
        category: DiagnosticCategory,
        userMessage: String,
        tracker: SigningEngineProgressTracker,
        workingCopy: SigningWorkingCopy?,
        outputExistedBeforeRun: Bool,
        startedAt: Date,
        stageStartedAt: [SigningEngineStage: Date],
        stageMetrics: [SigningEngineStage: SigningEngineStageMetrics],
        now: @Sendable () -> Date
    ) -> SigningEngineResult {
        tracker.fail(stage, detail: detail)
        let cleanup = workingCopy?.discard()
        let failure = SigningEngineFailure(
            stage: stage,
            detail: detail,
            category: category,
            userMessage: userMessage,
            originalUnchanged: cleanup?.originalUnchanged ?? false,
            workingCopyDiscarded: cleanup?.discarded ?? true,
            outputRemoved: cleanup?.discarded ?? true,
            outputPreexisted: outputExistedBeforeRun,
            diagnostics: Self.diagnostics(from: tracker)
        )
        return SigningEngineResult(
            status: .failed,
            outputURL: nil,
            stages: Self.stageOutcomes(
                from: tracker,
                startedAt: stageStartedAt,
                metrics: stageMetrics,
                completedAt: now()
            ),
            summary: nil,
            failure: failure,
            expectations: nil,
            verification: nil,
            containerVerification: nil,
            workingCopy: cleanup,
            progress: tracker.snapshot(elapsed: now().timeIntervalSince(startedAt))
        )
    }

    // MARK: - Delivery

    /// Moves a verified container into its delivery location.
    ///
    /// The container is written and verified outside the delivery location, so
    /// this is the only step that can replace an artifact that was already
    /// there — and it runs exclusively with a container that passed
    /// verification.
    private static func deliver(
        _ containerURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let directory = destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: containerURL, to: destinationURL)
        } catch {
            throw ZynSignError.artifactStorageFailure(
                diagnosticDetail: "The verified container could not be placed at its delivery location.",
                underlyingError: error
            )
        }
    }

    // MARK: - Internals

    /// Which engine stage a pipeline stage's failure belongs to.
    private static func engineStage(
        for stage: ApplicationSigningStage,
        tracker: SigningEngineProgressTracker
    ) -> SigningEngineStage {
        switch stage {
        case .integrity, .profile, .discovery, .extraction:
            return .validating
        case .nestedSigning:
            return tracker.snapshot(elapsed: 0).currentStage ?? .signingFrameworks
        case .resourceSealing, .mainExecutable:
            return .signingApplication
        case .packaging:
            return .packaging
        case .verification:
            return .verifying
        }
    }

    /// The stage detail lines the run had produced, for diagnostics.
    private static func diagnostics(from tracker: SigningEngineProgressTracker) -> [String] {
        tracker.snapshot(elapsed: 0).records.compactMap { record in
            record.detail.map { "\(record.stage.title): \($0)" }
        }
    }

    /// Every stage's structured outcome, derived from the tracker's final
    /// records and the metrics the run collected.
    ///
    /// A stage the run never reached is reported as skipped with an explicit
    /// reason: it did not succeed, and the interface must not imply that it
    /// did.
    private static func stageOutcomes(
        from tracker: SigningEngineProgressTracker,
        startedAt: [SigningEngineStage: Date],
        metrics: [SigningEngineStage: SigningEngineStageMetrics],
        completedAt: Date
    ) -> [SigningEngineStageOutcome] {
        tracker.snapshot(elapsed: 0).records.map { record in
            let status: SigningEngineStageStatus
            let detail: String
            switch record.state {
            case .completed:
                status = .succeeded
                detail = record.detail ?? record.stage.summary
            case .skipped:
                status = .skipped
                detail = record.detail ?? "Nothing to do."
            case .failed:
                status = .failed
                detail = record.detail ?? record.stage.summary
            case .pending, .active:
                status = .skipped
                detail = "Not reached: the run stopped at an earlier stage."
            }
            let duration = startedAt[record.stage].map { completedAt.timeIntervalSince($0) } ?? 0
            return SigningEngineStageOutcome(
                stage: record.stage,
                status: status,
                detail: detail,
                metrics: metrics[record.stage] ?? .none,
                duration: duration
            )
        }
    }
}
