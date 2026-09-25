import Foundation

/// The stages of one application signing run, in pipeline order.
enum ApplicationSigningStage: String, Equatable, CaseIterable {

    /// The source container is structurally validated and its bundle,
    /// metadata, and executable are established.
    case integrity

    /// The replacement profile is validated against the application, the
    /// identity, and the caller's configuration.
    case profile

    /// Nested code is discovered over the source container and a validated
    /// signing plan is derived.
    case discovery

    /// The source container is extracted to a working copy and the
    /// replacement profile is embedded.
    case extraction

    /// Every nested target is signed inside the working copy.
    case nestedSigning

    /// The working copy's resources are sealed and the seal is written.
    case resourceSealing

    /// The main executable is signed with the seal and the entitlements.
    case mainExecutable

    /// The working copy is rebuilt as a deterministic container.
    case packaging

    /// The rebuilt container is independently verified against the run's
    /// expectations.
    case verification
}

/// What one signing stage established on the success path.
struct ApplicationSigningIntegrityReport: Equatable {

    /// The bundle's location inside the source container.
    let bundlePath: ArchivePath

    /// The declared bundle identifier.
    let bundleIdentifier: BundleIdentifier

    /// The declared executable name.
    let executableName: String

    /// The main executable's location inside the source container.
    let executablePath: ArchivePath

    /// The source container's entry count.
    let entryCount: Int
}

/// The profile stage's evidence.
struct ApplicationSigningProfileReport: Equatable {

    /// The integrated pipeline status. Always `.valid` on the success path;
    /// anything else fails the run.
    let overallStatus: ProvisioningProfilePipelineStatus
}

/// One nested target the validated plan signs.
struct ApplicationSigningNestedTargetReport: Equatable {

    /// The target's executable location, relative to the bundle.
    let executablePath: BundlePath

    /// The target's kind, as discovery classified it by location.
    let kind: NestedCodeKind

    /// The identifier the target's container declared, when it declared one.
    let bundleIdentifier: String?
}

/// The discovery stage's evidence.
struct ApplicationSigningDiscoveryReport: Equatable {

    /// The number of nested targets the validated plan signs.
    let nestedItemCount: Int

    /// The number of signing steps, including the deferred application step.
    let stepCount: Int

    /// The nested targets themselves, in the plan's deterministic signing
    /// order. Carried so a later stage can verify each target's identifier
    /// without re-reading the source container.
    let nestedTargets: [ApplicationSigningNestedTargetReport]

    init(
        nestedItemCount: Int,
        stepCount: Int,
        nestedTargets: [ApplicationSigningNestedTargetReport] = []
    ) {
        self.nestedItemCount = nestedItemCount
        self.stepCount = stepCount
        self.nestedTargets = nestedTargets
    }
}

/// The sealing stage's evidence.
struct ApplicationSigningSealingReport: Equatable {

    /// The number of file resources sealed.
    let sealedFileCount: Int

    /// The number of nested-code seals referenced.
    let nestedSealCount: Int

    /// The number of resources recorded as omitted.
    let omittedCount: Int

    /// The serialized seal's size in bytes.
    let documentBytes: Int
}

/// The main-executable stage's evidence.
struct ApplicationSigningMainExecutableReport: Equatable {

    /// The cryptographic signature's size in bytes.
    let signatureByteCount: Int
}

/// Every stage's evidence from one successful signing run.
struct ApplicationSigningStageReports: Equatable {

    let integrity: ApplicationSigningIntegrityReport
    let profile: ApplicationSigningProfileReport
    let discovery: ApplicationSigningDiscoveryReport
    let extraction: ArchiveExtractionReport
    let nested: NestedSigningSummary
    let sealing: ApplicationSigningSealingReport
    let mainExecutable: ApplicationSigningMainExecutableReport
    let packaging: PackageSignedApplicationReport
    let verification: VerifySignedApplicationReport
}

/// The evidence every stage up to and including main-executable signing
/// established, together with the signed working copy those stages left in
/// place.
///
/// The type exists so a caller that wants to verify or package the signed
/// bundle itself — the signing engine coordinator does exactly that — can run
/// the pipeline's signing stages without giving up ownership of the working
/// copy. The caller that receives one of these owns it and must discard it;
/// `sign(_:)` does so itself.
struct ApplicationSigningSignedWorkingCopy {

    /// The working copy's own directory, removed by `discard()`.
    let workingRoot: URL

    /// The signed `<Name>.app` directory inside the working copy.
    let bundleDirectory: URL

    /// The bundle directory's own name.
    let bundleName: String

    /// Where the caller intends the container to be written.
    let outputURL: URL

    /// Whether the run created the working root itself. A caller-supplied
    /// root belongs to its caller; `discard()` removes it either way, because
    /// the holder of the copy is the one discarding it.
    let ownsWorkingRoot: Bool

    /// Every stage's evidence, in pipeline order, without packaging or
    /// verification — those have not run yet.
    let reports: ApplicationSigningSignedReports

    /// What an independent verification must hold the delivered container to.
    let expectations: SignedApplicationExpectations

    /// Removes the working copy. Idempotent.
    func discard() {
        try? FileManager.default.removeItem(at: workingRoot)
    }
}

/// The stage evidence a signed but not yet packaged working copy carries.
struct ApplicationSigningSignedReports: Equatable {

    let integrity: ApplicationSigningIntegrityReport
    let profile: ApplicationSigningProfileReport
    let discovery: ApplicationSigningDiscoveryReport
    let extraction: ArchiveExtractionReport
    let nested: NestedSigningSummary
    let sealing: ApplicationSigningSealingReport
    let mainExecutable: ApplicationSigningMainExecutableReport

    /// Every stage's evidence once packaging and verification have run too.
    func completed(
        packaging: PackageSignedApplicationReport,
        verification: VerifySignedApplicationReport
    ) -> ApplicationSigningStageReports {
        ApplicationSigningStageReports(
            integrity: integrity,
            profile: profile,
            discovery: discovery,
            extraction: extraction,
            nested: nested,
            sealing: sealing,
            mainExecutable: mainExecutable,
            packaging: packaging,
            verification: verification
        )
    }
}

/// Why one signing run failed.
struct ApplicationSigningFailure: Error, Equatable {

    /// The stage that refused the run or failed.
    let stage: ApplicationSigningStage

    /// What went wrong, in fixed diagnostic language. Bundle-relative
    /// locations may be named; identities, keys, and profile content never
    /// are.
    let detail: String

    /// The failure's category.
    let category: DiagnosticCategory
}

/// Whether one signing run produced a signed container.
enum ApplicationSigningStatus: String, Equatable {

    /// Every stage passed and the verified container was delivered.
    case signed

    /// A stage refused the run or failed. Nothing was delivered.
    case failed
}

/// The outcome of one application signing run.
///
/// Success carries the delivered container's location and every stage's
/// evidence. Failure carries the refusing stage and a typed reason, and no
/// container: a run that fails at any stage delivers nothing, and its
/// working copy is discarded. Cancellation is not a result — it propagates
/// as `CancellationError` like every other use case.
struct SignApplicationResult: Equatable {

    let status: ApplicationSigningStatus
    let outputURL: URL?
    let stages: ApplicationSigningStageReports?
    let failure: ApplicationSigningFailure?
}

/// Options the caller sets for one signing run.
struct SignApplicationOptions {

    /// How existing signatures are treated. Replacement is refused by the
    /// signing machinery, so the default rejects signed inputs: this
    /// pipeline signs unsigned containers.
    let existingSignaturePolicy: MachOExistingCodeSignaturePolicy

    /// The team identifier recorded in every CodeDirectory, when the caller
    /// establishes one.
    let teamIdentifier: CodeDirectoryTeamIdentifier?

    /// What the caller knows about the target device. Unavailable by
    /// default; the profile policy reads that as it reads any other
    /// missing evidence.
    let deviceContext: ProvisioningDeviceContext

    /// The platforms the application is intended for, when the caller
    /// established them explicitly.
    let intendedPlatforms: [ProvisioningProfilePlatform]?

    /// The debugging preference the profile policy evaluates.
    let getTaskAllow: SigningGetTaskAllowPreference

    /// The profile class the caller intends to use, when one is established.
    let intendedProfileClass: ProvisioningProfileClassification?

    /// Reserved for DER entitlements. This pipeline does NOT yet embed slot 7;
    /// requesting it is explicitly refused instead of silently producing an
    /// XML-only signature with a misleading v0x20400 CodeDirectory.
    let emitDEREntitlements: Bool

    init(
        existingSignaturePolicy: MachOExistingCodeSignaturePolicy = .rejectExistingSignature,
        teamIdentifier: CodeDirectoryTeamIdentifier? = nil,
        deviceContext: ProvisioningDeviceContext = .unavailable,
        intendedPlatforms: [ProvisioningProfilePlatform]? = nil,
        getTaskAllow: SigningGetTaskAllowPreference = .unspecified,
        intendedProfileClass: ProvisioningProfileClassification? = nil,
        emitDEREntitlements: Bool = false
    ) {
        self.existingSignaturePolicy = existingSignaturePolicy
        self.teamIdentifier = teamIdentifier
        self.deviceContext = deviceContext
        self.intendedPlatforms = intendedPlatforms
        self.getTaskAllow = getTaskAllow
        self.intendedProfileClass = intendedProfileClass
        self.emitDEREntitlements = emitDEREntitlements
    }
}

/// A request to sign one application container.
struct SignApplicationRequest {

    /// The source container to sign. Read but never modified.
    let sourceURL: URL

    /// The replacement profile bytes to embed and validate.
    let profile: Data

    /// The signing identity to sign with.
    let identityID: SigningIdentityIdentifier

    /// The entitlement set to embed in the main executable. The profile
    /// stage holds these claims against the profile before anything is
    /// signed.
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
}

/// Signs one application container end to end.
///
/// The pipeline composes the archive, provisioning, nested-signing,
/// resource-sealing, Mach-O signing, packaging, and verification machinery
/// into the single order a signed container requires: integrity, profile,
/// discovery, extraction, nested signing, resource sealing, main-executable
/// signing, packaging, verification. Each stage runs on the previous
/// stage's established output, and any refusal or failure ends the run with
/// a typed reason and no delivered container.
///
/// Three composition facts shape what the pipeline can sign:
///
/// - Existing signatures are rejected: the signing machinery appends
///   signatures and refuses replacement, so inputs must be unsigned.
/// - Nested targets sign without their own resource seals: the nested
///   use case takes no per-target seal input, so nested binaries carry no
///   slot-3 binding. The main seal references each nested binary by its
///   code-directory digest.
/// - Symbolic links are recorded as seal omissions: the platform's own
///   treatment of links is not established in ZynSign's record, so the
///   pipeline seals what it can state and omits the rest explicitly.
///
/// A successful run means the delivered container is exactly what the run
/// produced and internally coherent. It does not mean the signatures are
/// cryptographically valid to any trust evaluator, the platform authorizes
/// the result, or the artifact is installable: those conclusions need
/// device evidence this pipeline never claims to hold.
struct SignApplicationPipeline {

    private let identities: any IdentityStore
    private let digest: any MessageDigest
    private let profileValidation: ValidateProvisioningProfileUseCase
    private let nestedSigner: SignNestedCodeUseCase
    private let singleSigner: SignMachOUseCase
    private let packager: PackageSignedApplication
    private let verifier: VerifySignedApplication
    private let makeReader: (URL) -> any ArchiveReader
    private let limits: ArchiveLimits
    private let workingDirectoryRoot: URL?

    init(
        identities: any IdentityStore,
        digest: any MessageDigest,
        signatureVerifier: any CryptographicSignatureVerifier,
        profileValidation: ValidateProvisioningProfileUseCase,
        writer: any ArchiveWriter,
        makeReader: @escaping (URL) -> any ArchiveReader = { ZipArchiveReader(location: $0) },
        limits: ArchiveLimits = .default,
        workingDirectoryRoot: URL? = nil
    ) {
        self.identities = identities
        self.digest = digest
        self.profileValidation = profileValidation
        self.nestedSigner = SignNestedCodeUseCase(
            identities: identities,
            digest: digest,
            verifier: signatureVerifier
        )
        self.singleSigner = SignMachOUseCase(
            identities: identities,
            digest: digest,
            verifier: signatureVerifier
        )
        self.packager = PackageSignedApplication(writer: writer, limits: limits, makeReader: makeReader)
        self.verifier = VerifySignedApplication(makeReader: makeReader, digest: digest, limits: limits)
        self.makeReader = makeReader
        self.limits = limits
        self.workingDirectoryRoot = workingDirectoryRoot
    }

    /// Signs one application container.
    ///
    /// The run is the composition of the two steps a caller can also drive
    /// itself: `signUpToMainExecutable(_:observer:)`, then packaging, then
    /// independent verification of the written container. The working copy is
    /// discarded on every path, and a run that fails at any stage delivers
    /// nothing.
    ///
    /// - Parameters:
    ///   - request: The run's inputs.
    ///   - observer: Receives progress events as the run advances. `nil` runs
    ///     silently; an observer cannot influence the run.
    /// - Returns: The run's outcome: a delivered container with every
    ///   stage's evidence, or the refusing stage with a typed reason.
    /// - Throws: `CancellationError` when the run is cancelled. Every other
    ///   failure is a returned result, never a thrown error.
    func sign(
        _ request: SignApplicationRequest,
        observer: ApplicationSigningProgressObserver? = nil,
        workingRoot: URL? = nil
    ) async throws -> SignApplicationResult {
        try Task.checkCancellation()
        guard !request.options.emitDEREntitlements else {
            return SignApplicationResult(
                status: .failed, outputURL: nil, stages: nil,
                failure: ApplicationSigningFailure(
                    stage: .mainExecutable,
                    detail: "DER entitlements are not embedded by this signing pipeline.",
                    category: .unsupportedInput
                )
            )
        }
        do {
            let signed = try await signUpToMainExecutable(request, observer: observer, workingRoot: workingRoot)
            defer { signed.discard() }
            try Task.checkCancellation()
            let packaging = try await package(signed, outputURL: request.outputURL, observer: observer)
            try Task.checkCancellation()
            let verification = try await verify(
                containerURL: request.outputURL,
                expectations: signed.expectations,
                observer: observer
            )
            return SignApplicationResult(
                status: .signed,
                outputURL: request.outputURL,
                stages: signed.reports.completed(packaging: packaging, verification: verification),
                failure: nil
            )
        } catch let failure as ApplicationSigningFailure {
            return SignApplicationResult(status: .failed, outputURL: nil, stages: nil, failure: failure)
        }
    }

    /// Runs every signing stage up to and including main-executable signing,
    /// leaving the signed working copy in place for the caller.
    ///
    /// The caller that receives a working copy owns it and must discard it.
    /// The stage order is the pipeline's fixed order — integrity, profile,
    /// discovery, extraction, nested signing, resource sealing, main
    /// executable — and any refusal or failure ends the run with a typed
    /// reason, discards the working copy, and leaves the source container
    /// untouched.
    ///
    /// - Parameters:
    ///   - request: The run's inputs.
    ///   - observer: Receives progress events as the run advances.
    ///   - workingRoot: A directory the run extracts into, when the caller
    ///     already owns one — the signing engine's working copy, for example.
    ///     A supplied directory is never removed by the pipeline, on any path;
    ///     its owner discards it. When `nil`, the pipeline creates its own and
    ///     removes it when the run ends or fails.
    /// - Returns: The signed working copy with every stage's evidence.
    /// - Throws: `ApplicationSigningFailure` when a stage refuses the run, and
    ///   `CancellationError` when the run is cancelled.
    func signUpToMainExecutable(
        _ request: SignApplicationRequest,
        observer: ApplicationSigningProgressObserver? = nil,
        workingRoot suppliedWorkingRoot: URL? = nil
    ) async throws -> ApplicationSigningSignedWorkingCopy {
        try Task.checkCancellation()
        // The signing engine drives this entry point directly (not sign()).
        // Refuse unsupported DER before allocating a working copy or touching
        // an archive: the signer does not serialize/bind entitlement slot 7.
        guard !request.options.emitDEREntitlements else {
            throw ApplicationSigningFailure(
                stage: .mainExecutable,
                detail: "DER entitlements are not embedded by this signing pipeline.",
                category: .unsupportedInput
            )
        }
        let ownsWorkingRoot = suppliedWorkingRoot == nil
        let workingRoot = try suppliedWorkingRoot ?? makeWorkingDirectory()
        do {
            observer?(.stageStarted(.integrity))
            let integrity = try runIntegrity(request: request)
            observer?(.stageCompleted(.integrity))
            try Task.checkCancellation()

            observer?(.stageStarted(.profile))
            let profile = try runProfile(request: request, metadata: integrity.metadata)
            observer?(.stageCompleted(.profile))
            try Task.checkCancellation()

            observer?(.stageStarted(.discovery))
            let plan = try runDiscovery(request: request, integrity: integrity)
            observer?(.nestedPlan(Self.nestedTotals(of: plan)))
            observer?(.stageCompleted(.discovery))
            try Task.checkCancellation()

            observer?(.stageStarted(.extraction))
            let extraction = try await runExtraction(
                request: request,
                integrity: integrity,
                workingRoot: workingRoot
            )
            observer?(.stageCompleted(.extraction))
            try Task.checkCancellation()

            observer?(.stageStarted(.nestedSigning))
            let nested = try runNestedSigning(
                request: request,
                plan: plan,
                bundleDirectory: extraction.bundleDirectory,
                observer: observer
            )
            observer?(.stageCompleted(.nestedSigning))
            try Task.checkCancellation()

            observer?(.stageStarted(.resourceSealing))
            let sealing = try runSealing(
                plan: plan,
                nested: nested,
                integrity: integrity,
                bundleDirectory: extraction.bundleDirectory
            )
            observer?(.stageCompleted(.resourceSealing))
            try Task.checkCancellation()

            observer?(.stageStarted(.mainExecutable))
            let main = try runMainExecutable(
                request: request,
                integrity: integrity,
                sealed: sealing.seal,
                bundleDirectory: extraction.bundleDirectory
            )
            observer?(.stageCompleted(.mainExecutable))

            guard let bundleName = integrity.report.bundlePath.components.last else {
                throw ApplicationSigningFailure(
                    stage: .mainExecutable,
                    detail: "The bundle name cannot be recovered for packaging.",
                    category: .internalFailure
                )
            }
            return ApplicationSigningSignedWorkingCopy(
                workingRoot: workingRoot,
                bundleDirectory: extraction.bundleDirectory,
                bundleName: bundleName,
                outputURL: request.outputURL,
                ownsWorkingRoot: ownsWorkingRoot,
                reports: ApplicationSigningSignedReports(
                    integrity: integrity.report,
                    profile: profile,
                    discovery: ApplicationSigningDiscoveryReport(
                        nestedItemCount: plan.items.count,
                        stepCount: plan.stepCount,
                        nestedTargets: plan.items.map { item in
                            ApplicationSigningNestedTargetReport(
                                executablePath: item.executablePath,
                                kind: item.kind,
                                bundleIdentifier: item.bundleIdentifier?.rawValue
                            )
                        }
                    ),
                    extraction: extraction.report,
                    nested: nested.summary,
                    sealing: sealing.report,
                    mainExecutable: main
                ),
                expectations: SignedApplicationExpectations(
                    bundlePath: integrity.report.bundlePath,
                    bundleIdentifier: integrity.report.bundleIdentifier,
                    executableName: integrity.report.executableName,
                    executablePath: integrity.report.executablePath,
                    profile: request.profile,
                    sealedCodeResources: sealing.seal.bytes,
                    entitlements: request.entitlements,
                    nestedExecutablePaths: plan.items.map { $0.executablePath }
                )
            )
        } catch {
            if ownsWorkingRoot {
                try? FileManager.default.removeItem(at: workingRoot)
            }
            throw error
        }
    }

    /// Rebuilds a signed working copy as a deterministic container.
    ///
    /// - Parameters:
    ///   - workingCopy: The signed working copy to package. Read but never
    ///     modified.
    ///   - outputURL: Where the container is written. Any partial file is
    ///     removed when packaging fails.
    ///   - observer: Receives the packaging stage's progress events.
    /// - Throws: `ApplicationSigningFailure` when packaging refuses.
    func package(
        _ workingCopy: ApplicationSigningSignedWorkingCopy,
        outputURL: URL,
        observer: ApplicationSigningProgressObserver? = nil
    ) async throws -> PackageSignedApplicationReport {
        observer?(.stageStarted(.packaging))
        do {
            let report = try await packager.package(PackageSignedApplicationRequest(
                bundleDirectory: workingCopy.bundleDirectory,
                bundleName: workingCopy.bundleName,
                outputURL: outputURL
            ))
            observer?(.stageCompleted(.packaging))
            return report
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw map(error, stage: .packaging, detail: "The signed bundle could not be packaged.")
        }
    }

    /// Verifies a written container independently against the run's
    /// expectations.
    ///
    /// The verification is the same one the single-call run performs: a fresh
    /// read of the delivered container through the archive boundary, sharing
    /// no signing state. A container that fails is removed and reported,
    /// never delivered.
    ///
    /// - Throws: `ApplicationSigningFailure` at the verification stage when
    ///   the container does not hold up.
    func verify(
        containerURL: URL,
        expectations: SignedApplicationExpectations,
        observer: ApplicationSigningProgressObserver? = nil
    ) async throws -> VerifySignedApplicationReport {
        observer?(.stageStarted(.verification))
        let report: VerifySignedApplicationReport
        do {
            report = try await verifier.verify(containerURL: containerURL, expectations: expectations)
        } catch let cancellation as CancellationError {
            try? FileManager.default.removeItem(at: containerURL)
            throw cancellation
        } catch {
            try? FileManager.default.removeItem(at: containerURL)
            throw map(error, stage: .verification, detail: "The signed container could not be verified.")
        }
        guard report.passed else {
            try? FileManager.default.removeItem(at: containerURL)
            throw ApplicationSigningFailure(
                stage: .verification,
                detail: "Independent verification refused the signed container.",
                category: .internalFailure
            )
        }
        observer?(.stageCompleted(.verification))
        return report
    }

    /// How many nested targets each kind contributes, for progress reporting.
    static func nestedTotals(of plan: NestedSigningPlan) -> [NestedCodeKind: Int] {
        var totals: [NestedCodeKind: Int] = [:]
        for item in plan.items {
            totals[item.kind, default: 0] += 1
        }
        return totals
    }

    // MARK: - Working directories

    private func makeWorkingDirectory() throws -> URL {
        let root = (workingDirectoryRoot ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("zynsign-signing-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw ApplicationSigningFailure(
                stage: .extraction,
                detail: "The signing working copy could not be created.",
                category: (error as? ZynSignError)?.category ?? .storageFailure
            )
        }
        return root
    }

    // MARK: - Integrity

    private struct IntegrityContext {
        let report: ApplicationSigningIntegrityReport
        let metadata: ApplicationMetadata
    }

    private func runIntegrity(request: SignApplicationRequest) throws -> IntegrityContext {
        let reader = makeReader(request.sourceURL)
        defer { reader.close() }
        let table: [ArchiveEntry]
        do {
            table = try reader.readEntryTable()
        } catch {
            throw map(error, stage: .integrity, detail: "The source container could not be read.")
        }
        let inspection = IPAStructureValidator(limits: limits).validate(entryTable: table)
        guard inspection.isValid, let bundlePath = inspection.bundle?.bundlePath else {
            throw ApplicationSigningFailure(
                stage: .integrity,
                detail: "The source container failed structural validation.",
                category: .invalidInput
            )
        }
        guard let informationPath = bundlePath.appending(component: "Info.plist") else {
            throw ApplicationSigningFailure(
                stage: .integrity,
                detail: "The bundle information location cannot be named.",
                category: .invalidInput
            )
        }
        let informationBytes: Data
        do {
            informationBytes = try reader.readEntryData(at: informationPath, maximumBytes: limits.maximumInspectionReadBytes)
        } catch {
            throw map(error, stage: .integrity, detail: "The bundle information file could not be read.")
        }
        let examination = ApplicationMetadataReader.read(from: informationBytes)
        guard let metadata = examination.metadata, examination.isValid else {
            throw ApplicationSigningFailure(
                stage: .integrity,
                detail: "The bundle information file failed metadata validation.",
                category: .invalidInput
            )
        }
        guard let executableName = metadata.executableName,
              let executablePath = bundlePath.appending(component: executableName),
              table.first(where: { $0.path == executablePath })?.kind == .regularFile else {
            throw ApplicationSigningFailure(
                stage: .integrity,
                detail: "The declared executable is not a regular file inside the bundle.",
                category: .invalidInput
            )
        }
        return IntegrityContext(
            report: ApplicationSigningIntegrityReport(
                bundlePath: bundlePath,
                bundleIdentifier: metadata.identity.bundleIdentifier,
                executableName: executableName,
                executablePath: executablePath,
                entryCount: table.count
            ),
            metadata: metadata
        )
    }

    // MARK: - Profile

    private func runProfile(
        request: SignApplicationRequest,
        metadata: ApplicationMetadata
    ) throws -> ApplicationSigningProfileReport {
        let profileRequest = ValidateProvisioningProfileRequest(
            profile: .bytes(request.profile),
            profileOrigin: .supplied,
            applicationMetadata: metadata,
            signingIdentityID: request.identityID,
            signingConfiguration: SigningConfiguration(
                entitlements: ProvisioningProfileEntitlements(values: request.entitlements.values),
                getTaskAllow: request.options.getTaskAllow,
                intendedProfileClass: request.options.intendedProfileClass
            ),
            deviceContext: request.options.deviceContext,
            intendedPlatforms: request.options.intendedPlatforms
        )
        let result: ProvisioningProfilePipelineResult
        do {
            result = try profileValidation.validate(profileRequest)
        } catch {
            throw map(error, stage: .profile, detail: "The replacement profile could not be validated.")
        }
        guard result.overallStatus == .valid else {
            throw ApplicationSigningFailure(
                stage: .profile,
                detail: "The replacement profile is not established as compatible.",
                category: .invalidInput
            )
        }
        return ApplicationSigningProfileReport(overallStatus: result.overallStatus)
    }

    // MARK: - Discovery

    private func runDiscovery(
        request: SignApplicationRequest,
        integrity: IntegrityContext
    ) throws -> NestedSigningPlan {
        let reader = makeReader(request.sourceURL)
        defer { reader.close() }
        let table: [ArchiveEntry]
        do {
            table = try reader.readEntryTable()
        } catch {
            throw map(error, stage: .discovery, detail: "The source container could not be re-read for discovery.")
        }
        let source = ArchiveNestedCodeInspectionSource(reader: reader, limits: limits)
        let discovery = NestedCodeDiscovery.discover(
            entryTable: table,
            request: NestedCodeDiscoveryRequest(
                bundlePath: integrity.report.bundlePath,
                applicationIdentity: NestedCodeBundleIdentity(metadata: integrity.metadata)
            ),
            limits: .default,
            source: source
        )
        guard case .plan(let signingPlan) = discovery else {
            throw ApplicationSigningFailure(
                stage: .discovery,
                detail: "Nested code discovery refused the source container.",
                category: .invalidInput
            )
        }
        if !signingPlan.unsupportedItems.isEmpty {
            throw ApplicationSigningFailure(
                stage: .discovery,
                detail: "The container carries nested code this signing does not support.",
                category: .unsupportedInput
            )
        }
        do {
            return try NestedSigningPlanValidator.validate(plan: signingPlan)
        } catch let failure as NestedSigningFailure {
            throw ApplicationSigningFailure(stage: .discovery, detail: failure.detail, category: failure.category)
        } catch {
            throw map(error, stage: .discovery, detail: "The nested signing plan failed validation.")
        }
    }

    // MARK: - Extraction

    private struct ExtractionContext {
        let report: ArchiveExtractionReport
        let bundleDirectory: URL
    }

    private func runExtraction(
        request: SignApplicationRequest,
        integrity: IntegrityContext,
        workingRoot: URL
    ) async throws -> ExtractionContext {
        let reader = makeReader(request.sourceURL)
        defer { reader.close() }
        let destination = workingRoot.appendingPathComponent("work", isDirectory: true)
        let policy = ArchiveExtractionPolicy(
            maximumExtractedBytes: limits.maximumTotalUncompressedBytes,
            maximumLinkTargetBytes: limits.maximumEntryNameLength,
            symlinkPolicy: .recreateWithinRoot
        )
        let report: ArchiveExtractionReport
        do {
            report = try await DirectoryArchiveExtractor(
                destination: destination,
                policy: policy,
                readBound: limits.maximumEntryBytes
            ).extract(reader: reader)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw map(error, stage: .extraction, detail: "The source container could not be extracted.")
        }
        var bundleDirectory = destination
        for component in integrity.report.bundlePath.components {
            bundleDirectory.appendPathComponent(component)
        }
        do {
            try request.profile.write(to: bundleDirectory.appendingPathComponent("embedded.mobileprovision"), options: .atomic)
        } catch {
            throw map(error, stage: .extraction, detail: "The replacement profile could not be embedded.")
        }
        return ExtractionContext(report: report, bundleDirectory: bundleDirectory)
    }

    // MARK: - Nested signing

    private func runNestedSigning(
        request: SignApplicationRequest,
        plan: NestedSigningPlan,
        bundleDirectory: URL,
        observer: ApplicationSigningProgressObserver? = nil
    ) throws -> NestedSigningResult {
        let store = DirectoryBundleBinaryStore(
            bundleDirectory: bundleDirectory,
            maximumBinaryBytes: limits.maximumEntryBytes
        )
        let nestedObserver: NestedSigningProgressObserver? = observer.map { report in
            { progress in
                switch progress.phase {
                case .signing:
                    report(.nestedItemStarted(
                        order: progress.order,
                        total: progress.total,
                        kind: progress.kind,
                        path: progress.executablePath
                    ))
                case .signed:
                    report(.nestedItemSigned(
                        order: progress.order,
                        total: progress.total,
                        kind: progress.kind,
                        path: progress.executablePath
                    ))
                case .refused:
                    report(.nestedItemRefused(
                        order: progress.order,
                        total: progress.total,
                        kind: progress.kind,
                        path: progress.executablePath
                    ))
                }
            }
        }
        let result = nestedSigner.sign(
            NestedSigningRequest(
                plan: plan,
                identityID: request.identityID,
                existingSignaturePolicy: request.options.existingSignaturePolicy,
                teamIdentifier: request.options.teamIdentifier,
                mutationStrategy: .directMutation
            ),
            store: store,
            observer: nestedObserver
        )
        guard result.isSuccess else {
            let detail = result.itemResults.first {
                if case .failed(_) = $0.status {
                    return true
                }
                return false
            }.flatMap { itemResult -> String? in
                if case .failed(let failure) = itemResult.status {
                    return failure.detail
                }
                return nil
            } ?? "Nested signing failed."
            let category = result.itemResults.first {
                if case .failed(_) = $0.status {
                    return true
                }
                return false
            }.flatMap { itemResult -> DiagnosticCategory? in
                if case .failed(let failure) = itemResult.status {
                    return failure.category
                }
                return nil
            } ?? .internalFailure
            throw ApplicationSigningFailure(stage: .nestedSigning, detail: detail, category: category)
        }
        return result
    }

    // MARK: - Resource sealing

    private struct SealingContext {
        let seal: SealedCodeResources
        let report: ApplicationSigningSealingReport
    }

    private func runSealing(
        plan: NestedSigningPlan,
        nested: NestedSigningResult,
        integrity: IntegrityContext,
        bundleDirectory: URL
    ) throws -> SealingContext {
        guard let mainExecutable = BundlePath(integrity.report.executablePath, relativeTo: integrity.report.bundlePath) else {
            throw ApplicationSigningFailure(
                stage: .resourceSealing,
                detail: "The main executable cannot be located inside the bundle.",
                category: .internalFailure
            )
        }
        var nestedSeals: [NestedCodeResourceSeal] = []
        for item in plan.items {
            guard let itemResult = nested.result(for: item.id),
                  case .signed(let details) = itemResult.status else {
                throw ApplicationSigningFailure(
                    stage: .resourceSealing,
                    detail: "A nested target has no established signature to seal.",
                    category: .internalFailure
                )
            }
            do {
                nestedSeals.append(try NestedCodeResourceSeal(
                    path: item.executablePath,
                    codeDirectoryDigest: details.codeDirectoryDigest
                ))
            } catch {
                throw map(error, stage: .resourceSealing, detail: "A nested-code seal could not be constructed.")
            }
        }
        let nestedContainers = Set(plan.items.map { $0.bundlePath })
        for container in nestedContainers {
            guard !container.components.isEmpty else {
                throw ApplicationSigningFailure(
                    stage: .resourceSealing,
                    detail: "A nested container cannot be located inside the bundle.",
                    category: .internalFailure
                )
            }
        }
        let store = WorkingCopyResourceContentStore(
            bundleDirectory: bundleDirectory,
            nestedContainers: nestedContainers
        )
        let listing: [ResourceListingEntry]
        do {
            listing = try store.listEntries()
        } catch {
            throw mapSealError(error, stage: .resourceSealing)
        }
        // The main executable and the signature directory are sealed by
        // reference, not by content: the executable by its own CodeDirectory
        // and the seal it carries, the signature directory not at all. The
        // store already keeps nested-container contents out of the walk; the
        // container directories themselves are excluded here so the seal
        // records the decision as an omission.
        var excluded: Set<BundlePath> = []
        for entry in listing {
            if entry.path == mainExecutable {
                excluded.insert(entry.path)
                continue
            }
            if entry.path.components.first == "_CodeSignature" {
                excluded.insert(entry.path)
                continue
            }
            if nestedContainers.contains(entry.path) {
                excluded.insert(entry.path)
            }
        }
        let document: CodeResourcesDocument
        do {
            document = try CodeResourcesGenerator(messageDigest: digest).generate(
                from: store,
                configuration: ResourceSealingConfiguration(symlinkPolicy: .exclude, excludedPaths: excluded),
                nestedCode: nestedSeals
            )
        } catch {
            throw mapSealError(error, stage: .resourceSealing)
        }
        let bytes: Data
        do {
            bytes = try CodeResourcesSerializer().serialize(document)
        } catch {
            throw map(error, stage: .resourceSealing, detail: "The resource seal could not be serialized.")
        }
        let seal: SealedCodeResources
        do {
            seal = try SealedCodeResources(bytes: bytes)
        } catch {
            throw map(error, stage: .resourceSealing, detail: "The resource seal could not be adopted for signing.")
        }
        do {
            let signatureDirectory = bundleDirectory.appendingPathComponent("_CodeSignature", isDirectory: true)
            try FileManager.default.createDirectory(at: signatureDirectory, withIntermediateDirectories: true)
            try seal.bytes.write(to: signatureDirectory.appendingPathComponent("CodeResources"), options: .atomic)
        } catch {
            throw map(error, stage: .resourceSealing, detail: "The resource seal could not be written.")
        }
        var sealedFileCount = 0
        var nestedSealCount = 0
        for entry in document.files2 {
            switch entry {
            case .file:
                sealedFileCount += 1
            case .nestedCode:
                nestedSealCount += 1
            }
        }
        return SealingContext(
            seal: seal,
            report: ApplicationSigningSealingReport(
                sealedFileCount: sealedFileCount,
                nestedSealCount: nestedSealCount,
                omittedCount: document.omitted.count,
                documentBytes: bytes.count
            )
        )
    }

    // MARK: - Main executable

    private func runMainExecutable(
        request: SignApplicationRequest,
        integrity: IntegrityContext,
        sealed: SealedCodeResources,
        bundleDirectory: URL
    ) throws -> ApplicationSigningMainExecutableReport {
        guard let executableRelative = BundlePath(
            integrity.report.executablePath,
            relativeTo: integrity.report.bundlePath
        ) else {
            throw ApplicationSigningFailure(
                stage: .mainExecutable,
                detail: "The main executable cannot be located inside the bundle.",
                category: .internalFailure
            )
        }
        let store = DirectoryBundleBinaryStore(
            bundleDirectory: bundleDirectory,
            maximumBinaryBytes: limits.maximumEntryBytes
        )
        let originalBytes: Data
        do {
            originalBytes = try store.readBinary(at: executableRelative)
        } catch {
            throw map(error, stage: .mainExecutable, detail: "The main executable could not be read.")
        }
        let identifier: CodeDirectoryIdentifier
        do {
            identifier = try CodeDirectoryIdentifier(rawValue: integrity.report.bundleIdentifier.rawValue)
        } catch {
            throw map(error, stage: .mainExecutable, detail: "The bundle identifier cannot be a CodeDirectory identifier.")
        }
        let codeLimit: UInt64
        do {
            let layout = try MachOCodeSignatureRegionLayout(
                appendingSerializedSuperBlobLength: 1,
                toFileLength: originalBytes.count
            )
            codeLimit = UInt64(layout.offset)
        } catch {
            throw map(error, stage: .mainExecutable, detail: "The main executable admits no signature region.")
        }
        let hashConfiguration: CodeDirectoryHashConfiguration
        do {
            hashConfiguration = try CodeDirectoryHashConfiguration(hashType: .sha256)
        } catch {
            throw map(error, stage: .mainExecutable, detail: "The CodeDirectory hash configuration could not be constructed.")
        }
        // This path emits XML only. The explicit refusal in sign(_:) keeps an
        // unsupported DER request from silently changing the version without
        // embedding and verifying the corresponding slot-7 blob.
        let cdVersion: CodeDirectoryVersion = .v20200
        let signingResult: MachOSigningResult
        do {
            signingResult = try singleSigner.sign(MachOSigningRequest(
                artifact: originalBytes,
                identityID: request.identityID,
                codeDirectory: CodeDirectoryConstructionRequest(
                    version: cdVersion,
                    identifier: identifier,
                    teamIdentifier: request.options.teamIdentifier,
                    hashConfiguration: hashConfiguration,
                    pageSize: .exponent(12),
                    codeLimit: codeLimit
                ),
                algorithm: .rsaPKCS1SHA256Digest,
                existingSignaturePolicy: request.options.existingSignaturePolicy,
                policy: .singleImageCryptographicExperiment,
                metadata: MachOSigningMetadata(
                    entitlements: request.entitlements,
                    resourceSeal: sealed
                )
            ))
        } catch let signingError as MachOSigningError {
            throw mapMachOSigningError(signingError)
        } catch {
            throw map(error, stage: .mainExecutable, detail: "The main executable could not be signed.")
        }
        do {
            try store.writeBinary(signingResult.artifact, at: executableRelative)
        } catch {
            throw map(error, stage: .mainExecutable, detail: "The signed main executable could not be written.")
        }
        return ApplicationSigningMainExecutableReport(signatureByteCount: signingResult.cryptographicSignature.count)
    }

    // MARK: - Error mapping

    private func map(_ error: any Error, stage: ApplicationSigningStage, detail: String) -> ApplicationSigningFailure {
        if let failure = error as? ApplicationSigningFailure {
            return failure
        }
        if let failure = error as? NestedSigningFailure {
            return ApplicationSigningFailure(stage: stage, detail: failure.detail, category: failure.category)
        }
        let category = (error as? ZynSignError)?.category ?? .internalFailure
        return ApplicationSigningFailure(stage: stage, detail: detail, category: category)
    }

    private func mapSealError(_ error: any Error, stage: ApplicationSigningStage) -> ApplicationSigningFailure {
        guard let sealError = error as? ResourceSealError else {
            return map(error, stage: stage, detail: "The working copy could not be sealed.")
        }
        switch sealError {
        case .unsealablePath, .unsupportedEntryKind, .resourceTooLarge, .resourceCountExceeded,
             .totalSealedBytesExceeded, .symbolicLinkRejected, .duplicateResourcePath, .resourceUnavailable:
            return ApplicationSigningFailure(
                stage: stage,
                detail: "The working copy carries resources this sealing refuses.",
                category: .invalidInput
            )
        case .traversalFailure, .digestFailure, .unsupportedDigestAlgorithm, .integerOverflow:
            return ApplicationSigningFailure(
                stage: stage,
                detail: "The working copy could not be sealed.",
                category: .internalFailure
            )
        }
    }

    private func mapMachOSigningError(_ error: MachOSigningError) -> ApplicationSigningFailure {
        switch error {
        case .invalidMachO, .invalidCodeLimit:
            return ApplicationSigningFailure(
                stage: .mainExecutable,
                detail: "The main executable is not a signable Mach-O image.",
                category: .invalidInput
            )
        case .unsupportedMachOForm:
            return ApplicationSigningFailure(
                stage: .mainExecutable,
                detail: "The main executable uses a Mach-O form this signing does not support.",
                category: .unsupportedInput
            )
        case .unsupportedConfiguration, .unsupportedHashType, .unsupportedSigningAlgorithm:
            return ApplicationSigningFailure(
                stage: .mainExecutable,
                detail: "The main executable signing configuration is not supported.",
                category: .unsupportedInput
            )
        case .identityUnavailable, .certificateUnavailable, .signingCapabilityFailure:
            return ApplicationSigningFailure(
                stage: .mainExecutable,
                detail: "The signing identity is not available for signing.",
                category: .capabilityUnavailable
            )
        case .resourceSeal(let sealError):
            return mapSealError(sealError, stage: .mainExecutable)
        case .resourceLimitExceeded:
            return ApplicationSigningFailure(
                stage: .mainExecutable,
                detail: "The main executable exceeds a signing resource bound.",
                category: .invalidInput
            )
        case .layout(.existingSignatureRejected), .layout(.replacementUnsupported):
            return ApplicationSigningFailure(
                stage: .mainExecutable,
                detail: "The main executable already carries a signature, which this signing does not replace.",
                category: .unsupportedInput
            )
        case .codeDirectoryConstruction, .codeDirectorySerialization, .entitlements,
             .requirements, .digestFailure, .signatureBlobConstruction, .superBlobConstruction,
             .layout, .mutation, .postSignVerification:
            return ApplicationSigningFailure(
                stage: .mainExecutable,
                detail: "The main executable could not be signed.",
                category: .internalFailure
            )
        }
    }
}
