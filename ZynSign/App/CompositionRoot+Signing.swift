import Foundation

/// The signing pipeline, the queue, the presets, and exports.
///
/// Part of `CompositionRoot`, which chooses every concrete
/// implementation and wires the layers together. Split out of the
/// original single file for readability; the members are unchanged.
extension CompositionRoot {

    /// Builds the Installation Workspace over the library, the signing
    /// journal, the export catalog, the installed-applications store, and
    /// the same independent verifier the signing pipeline uses — so a
    /// verification the workspace records is the verification every other
    /// screen reads.
    static func makeInstallationWorkspace(
        library: ApplicationLibrary,
        history: any SigningHistoryStore,
        exports: ExportCenter
    ) -> InstallationWorkspace {
        let installed = makeInstalledApplicationStore()
        return InstallationWorkspace(
            library: library,
            history: history,
            exports: exports,
            installed: installed,
            verification: makeVerifyExportedArtifact(),
            installedByteCount: { [installed] in
                await installed.storedByteCount()
            }
        )
    }

    /// Builds the signing queue: the job orchestration every queued signing
    /// runs through. The executor runs each job as one signing operation —
    /// the same center that delivers to the Export Center and journals every
    /// run — so a queued job is isolated, exported, verified, and recorded
    /// exactly like any other signing operation. The store persists the
    /// queue's list and its queue-owned profile copies under the library
    /// root; the working directory root it sweeps is the root the center
    /// creates its per-operation directories under.
    static func makeSigningQueue(
        operations: SigningOperationCenter,
        library: ApplicationLibrary,
        notifier: (any SigningQueueNotifying)? = nil,
        presetUsageRecorder: ((PresetUseOutcome) -> Void)? = nil
    ) -> SigningQueue {
        SigningQueue(
            executor: SigningOperationExecutor(operations: operations, library: library),
            store: makeSigningQueueStore(),
            notifier: notifier,
            artifactURLResolver: { artifactID in libraryArtifactFileURL(for: artifactID) },
            presetUsageRecorder: presetUsageRecorder
        )
    }

    /// The preset workflow the confirmation screen and the bulk planner use.
    /// It resolves references. It does not sign; confirmed work is enqueued
    /// on `SigningQueue`.
    static func makeSigningPresetWorkflow(
        presets: any SigningPresetStore,
        profiles: any ProvisioningProfileLibrary,
        identities: any IdentityStore
    ) -> SigningPresetWorkflow {
        SigningPresetWorkflow(
            presets: presets,
            profiles: profiles,
            identities: identities,
            profileDirectory: provisioningProfileCatalogLocation().deletingLastPathComponent(),
            artifactURL: { artifactID in libraryArtifactFileURL(for: artifactID) }
        )
    }

    /// Builds the file-backed signing queue store at the canonical
    /// Application Support location, sweeping the signing workspace root
    /// during recovery.
    static func makeSigningQueueStore() -> any SigningQueueStore {
        FileSigningQueueStore(
            queueDirectory: signingQueueDirectory,
            workingDirectoryRoot: signingWorkspaceRoot()
        )
    }

    /// The local notifier for settled signing jobs. Composed on iOS, where
    /// `UserNotifications` exists; elsewhere the queue posts in-app notices
    /// only, which is the whole notifier contract.
    static func makeSigningQueueNotifier() -> (any SigningQueueNotifying)? {
        #if os(iOS)
        return LocalSigningQueueNotifier()
        #else
        return UnavailableSigningQueueNotifier()
        #endif
    }

    /// Builds the file-backed signing preset store, lazily created at the
    /// canonical Application Support location.
    static func makeSigningPresetStore() -> any SigningPresetStore {
        FileSigningPresetStore(catalogLocation: signingPresetCatalogLocation())
    }

    /// Builds the file-backed signing history store, lazily created at the
    /// canonical Application Support location. It announces every change it
    /// completes, so the library re-reads the journal after a signing, a
    /// cleanup, or a cleared journal, whichever screen made the change.
    static func makeSigningHistoryStore() -> any SigningHistoryStore {
        NotifyingSigningHistoryStore(
            wrapping: FileSigningHistoryStore(
                journalLocation: signingHistoryJournalLocation(),
                capacity: AnalyticsPolicy.journalCapacity
            )
        )
    }

    /// Builds the Export Center over the file-backed export catalog and the
    /// signed-output directory. The two are bound here and nowhere else: the
    /// catalog records names, the directory holds bytes, and this factory is
    /// what makes them describe the same artifacts.
    static func makeExportCenter() -> ExportCenter {
        ExportCenter(
            records: FileExportRecordStore(catalogLocation: exportCatalogLocation()),
            artifacts: FileExportArtifactStore(exportsDirectory: exportArtifactDirectory())
        )
    }

    /// Builds the independent verifier over the same digest, archive-reader,
    /// and signature-inspection mechanisms the rest of the application uses,
    /// with the CMS-backed profile decoder so an embedded profile's container
    /// signature is actually evaluated rather than skipped.
    static func makeVerifyExportedArtifact(
        digest: any MessageDigest = makeMessageDigest()
    ) -> VerifyExportedArtifact {
        VerifyExportedArtifact(
            digest: digest,
            profileDecoder: CMSProvisioningProfilePayloadDecoder(verifier: makeProvisioningProfileCMSVerifier())
        )
    }

    /// Builds the signing operation runner: the pipeline, the Export Center,
    /// the signing journal, the independent verifier, the per-operation
    /// workspace, and the volume's free-space figure, composed so one call
    /// signs an application and records everything that happened.
    static func makeSigningOperationCenter(
        pipeline: SignApplicationPipeline,
        exports: ExportCenter,
        history: any SigningHistoryStore,
        verification: VerifyExportedArtifact = makeVerifyExportedArtifact()
    ) -> SigningOperationCenter {
        SigningOperationCenter(
            pipeline: pipeline,
            exports: exports,
            history: history,
            verification: verification,
            workspaces: FileSigningWorkspace(root: signingWorkspaceRoot()),
            capacity: FileVolumeStorageCapacity(location: documentsDirectory)
        )
    }

    /// Builds the storage use case over the measured locations and the ports
    /// that own each kind of storage. Imported applications are reported but
    /// never removed by anything composed here.
    static func makeStorageManagement(
        exports: ExportCenter,
        history: any SigningHistoryStore,
        preferences: ZynSignPreferences = ZynSignPreferences.shippedDefault
    ) -> StorageManagement {
        StorageManagement(
            reporting: FileStorageFootprint(
                importedApplicationsDirectory: libraryArtifactDirectory,
                exportedArtifactsDirectory: exportArtifactDirectory(),
                temporaryDirectories: temporaryDirectories(preferences: preferences),
                historyFiles: [
                    signingHistoryJournalLocation(),
                    exportCatalogLocation(),
                    installedApplicationsCatalogLocation(),
                ]
            ),
            temporaryData: FileTemporaryStorage(
                directories: temporaryDirectories(preferences: preferences)
            ),
            exports: exports,
            history: history
        )
    }

    /// Builds the cryptographic signing use case over the given identity
    /// store.
    ///
    /// The engine is the pure capability engine, and the identity store is
    /// the ZS-016 boundary that owns the key: the use case resolves the
    /// capability, the engine asks it for a signature, and only signature
    /// bytes cross. Nothing built here is installed in the application
    /// environment — the identity store is not composed into the app until
    /// its device validation completes, and no interface consumes a
    /// signature result yet.
    static func makeCryptographicSigningUseCase(
        identityStore: any IdentityStore,
        engine: any CryptographicSigningEngine = CapabilitySigningEngine()
    ) -> CryptographicSigningUseCase {
        CryptographicSigningUseCase(identityStore: identityStore, engine: engine)
    }

    /// Builds the digest mechanism for this target.
    ///
    /// CryptoKit's hashing primitives are documented for the deployment
    /// target, so the platform implementation is the only candidate; the
    /// factory keeps the choice in the composition root, where every other
    /// mechanism selection happens.
    static func makeMessageDigest() -> any MessageDigest {
        CryptoKitMessageDigest()
    }

    /// Builds the signature-verification mechanism for this target.
    ///
    /// On iOS the mechanism uses the documented Security key primitives
    /// under the operations `SigningAlgorithm` selects; on any other target
    /// it reports verification as unavailable rather than skipping it
    /// silently. Nothing built here is installed in the application
    /// environment, because no interface consumes a verification outcome
    /// yet.
    static func makeCryptographicSignatureVerifier() -> any CryptographicSignatureVerifier {
        #if os(iOS)
        return AppleSignatureVerifier()
        #else
        return UnavailableCryptographicSignatureVerifier()
        #endif
    }

    /// Builds the nested code signing use case over the given identity store.
    ///
    /// Signs nested Mach-O code in dependency-aware order, using the existing
    /// single Mach-O signing capability and cryptographic verification abstractions.
    /// Nothing built here is installed in the application environment, because no
    /// interface consumes nested signing results yet.
    static func makeNestedCodeSigningUseCase(
        identityStore: any IdentityStore,
        digest: any MessageDigest = makeMessageDigest(),
        verifier: any CryptographicSignatureVerifier = makeCryptographicSignatureVerifier(),
        parser: any MachOParsing = ReadOnlyMachOParser(),
        writer: MachOCodeSignatureWriter = MachOCodeSignatureWriter()
    ) -> SignNestedCodeUseCase {
        SignNestedCodeUseCase(
            identities: identityStore,
            digest: digest,
            verifier: verifier,
            parser: parser,
            writer: writer
        )
    }

    /// Selects the concrete archive writer: the deterministic stored-only
    /// ZIP writer. Nothing beneath the composition root names the format.
    static func makeArchiveWriter() -> any ArchiveWriter {
        ZipArchiveWriter()
    }

    /// Builds the signed-application packaging use case over the selected
    /// writer and the ordinary archive reader. Nothing built here is
    /// installed in the application environment — no interface packages a
    /// signed bundle yet.
    static func makePackageSignedApplication(
        writer: any ArchiveWriter = makeArchiveWriter(),
        limits: ArchiveLimits = .default
    ) -> PackageSignedApplication {
        PackageSignedApplication(writer: writer, limits: limits)
    }

    /// Builds the signed-application verifier over the ordinary archive
    /// reader and the target digest mechanism. Nothing built here is
    /// installed in the application environment — no interface verifies a
    /// signed container yet.
    static func makeVerifySignedApplication(
        digest: any MessageDigest = makeMessageDigest(),
        limits: ArchiveLimits = .default
    ) -> VerifySignedApplication {
        VerifySignedApplication(digest: digest, limits: limits)
    }

    /// Builds the signing engine over the pipeline the environment exposes.
    ///
    /// The engine's validator reads the source container through the ordinary
    /// archive boundary; its working-copy verifier re-reads the signed bundle
    /// and its container verifier reopens the written container. All three
    /// are composed over the same reader, digest, and limits the rest of the
    /// application uses, so no signing path has a private implementation of
    /// reading, hashing, or verification.
    static func makeSigningEngine(
        identityStore: any IdentityStore,
        pipeline: SignApplicationPipeline,
        digest: any MessageDigest = makeMessageDigest(),
        signatureVerifier: any CryptographicSignatureVerifier = makeCryptographicSignatureVerifier(),
        limits: ArchiveLimits = .default,
        workingDirectoryRoot: URL? = nil
    ) -> SigningEngineCoordinator {
        SigningEngineCoordinator(
            pipeline: pipeline,
            validator: SigningEngineBundleValidator(
                makeReader: { ZipArchiveReader(location: $0, limits: limits) },
                limits: limits
            ),
            workingCopyVerifier: SigningEngineVerifier(
                identities: identityStore,
                digest: digest,
                cryptographicVerifier: signatureVerifier,
                maximumBinaryBytes: limits.maximumEntryBytes
            ),
            containerVerifier: makeVerifySignedApplication(digest: digest, limits: limits),
            digest: digest,
            workingDirectoryRoot: workingDirectoryRoot
        )
    }

    /// Builds the end-to-end application signing pipeline over the given
    /// identity store.
    ///
    /// The pipeline, the packager, and the verifier are composed over the
    /// same writer, reader, digest, and profile machinery the rest of the
    /// application uses. Nothing built here is installed in the application
    /// environment: the pipeline is constructible and covered by tests, but
    /// no signing interface is composed until device validation completes,
    /// and no installation channel exists anywhere in the product.
    static func makeSignApplicationPipeline(
        identityStore: any IdentityStore,
        digest: any MessageDigest = makeMessageDigest(),
        signatureVerifier: any CryptographicSignatureVerifier = makeCryptographicSignatureVerifier(),
        certificateParser: any CertificateParser = AppleCertificateParser(),
        clock: any EvaluationClock = SystemEvaluationClock(),
        writer: any ArchiveWriter = makeArchiveWriter(),
        limits: ArchiveLimits = .default
    ) -> SignApplicationPipeline {
        SignApplicationPipeline(
            identities: identityStore,
            digest: digest,
            signatureVerifier: signatureVerifier,
            profileValidation: makeProvisioningProfilePipeline(
                certificateParser: certificateParser,
                clock: clock,
                identityStore: identityStore
            ),
            writer: writer,
            limits: limits
        )
    }
}
