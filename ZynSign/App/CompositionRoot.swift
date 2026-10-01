import Foundation

/// The composition root for ZynSign.
///
/// This is the single place where application-layer objects are constructed
/// and wired together. The application entry point calls into it and nothing
/// else; views receive dependencies through the SwiftUI environment and never
/// construct application-layer or domain objects themselves.
///
/// Concrete implementations are selected here and nowhere below. Where a
/// capability has more than one possible implementation — the archive reader
/// and the persistence stores above all — the choice is made here, so that
/// the layers beneath the choice depend only on the port.
enum CompositionRoot {

    /// The environment used by contexts that render ZynSign's views without
    /// the application's own: SwiftUI previews, and tests that build a screen
    /// or a model directly.
    ///
    /// It is one instance, built at most once per process, because the
    /// environment keys that fall back to it (`\.applicationEnvironment`,
    /// `\.settingsCenter`, `\.appLock`) would otherwise each construct a
    /// complete application graph — separate stores, separate file caches,
    /// separate background schedulers — and a preview (or a section presented
    /// on its own) would read preferences and a library that the rest of the
    /// pass does not share. The running application never reads it: the shell
    /// installs the environment built once in `ZynSignApp` before any view is
    /// rendered.
    ///
    /// Built on the main actor, like `makeApplicationEnvironment()` itself,
    /// and never as the side effect of a view reading an environment default:
    /// a caller that needs it asks for it explicitly.
    static let fallbackEnvironment: ApplicationEnvironment = makeApplicationEnvironment()

    static func backupFileURL(for item: BackupHistoryItem) -> URL {
        libraryRootDirectory.appendingPathComponent("Recovery/Backups/" + item.fileName)
    }

    static func makeApplicationEnvironment() -> ApplicationEnvironment {
        RecoveryStore.applyPending(at: libraryRootDirectory)
        // The preferences are read before anything else is built, because the
        // working-directory choice decides where staging happens and the
        // storage screen measures what the choice covers.
        let preferences = makePreferencesStore()
        let preferencesSnapshot = MainActor.assumeIsolated { preferences.snapshot }
        let biometricAuthenticator = makeBiometricAuthenticator()
        let intake = SecurityScopedArtifactIntake(
            directory: importStagingDirectory(preferences: preferencesSnapshot)
        )
        let diagnosticHistory = makeSigningDiagnosticsHistoryStore()
        let library = makeApplicationLibrary(intake: intake, diagnosticHistory: diagnosticHistory)
        let identityStore = makeIdentityStore()
        let identityAnnotationsStore = makeIdentityAnnotationsStore()
        let pkcs12DocumentReader = CoordinatedPKCS12DocumentReader()
        let diagnostics = makeSigningDiagnostics(
            library: library, intake: intake, identities: identityStore,
            history: diagnosticHistory
        )
        let packageImport = makePackageImport(intake: intake, library: library, diagnostics: diagnostics)
        let pkcs12Importer = makePKCS12Importer(identityStore: identityStore)
        let pipeline = makeSignApplicationPipeline(identityStore: identityStore)
        let signingEngine = makeSigningEngine(identityStore: identityStore, pipeline: pipeline)
        let presets = makeSigningPresetStore()
        let history = makeSigningHistoryStore()
        let profiles = makeProvisioningProfileLibrary()
        let exports = makeExportCenter()
        let storage = makeStorageManagement(
            exports: exports,
            history: history,
            preferences: preferencesSnapshot
        )
        let appIcons = makeAppIconExtraction()
        let droppedFiles = DropInboxFileReceiver(directory: importDropInboxDirectory)
        let signingOperations = makeSigningOperationCenter(
            pipeline: pipeline,
            exports: exports,
            history: history
        )
        let queueNotifier = makeSigningQueueNotifier()
        let signingPresetWorkflow = makeSigningPresetWorkflow(
            presets: presets,
            profiles: profiles,
            identities: identityStore
        )
        let signingQueue = makeSigningQueue(
            operations: signingOperations,
            library: library,
            notifier: queueNotifier,
            presetUsageRecorder: { outcome in
                Task { try? await signingPresetWorkflow.record(outcome) }
            }
        )
        var environment = ApplicationEnvironment(
            applicationInfo: ApplicationInfo.current(bundle: .main),
            packageImport: packageImport,
            importHub: makeImportHub(
                intake: intake,
                library: library,
                appIcons: appIcons,
                droppedFiles: droppedFiles,
                diagnostics: diagnostics
            ),
            library: library,
            bundleInspection: makeBundleContentsInspection(intake: intake, library: library),
            applicationDetailsInspection: makeApplicationDetailsInspection(intake: intake, library: library),
            bundleEntryInspection: makeBundleEntryInspection(intake: intake, library: library),
            identityStore: identityStore,
            pkcs12Importer: pkcs12Importer,
            pkcs12DocumentReader: pkcs12DocumentReader,
            signingPipeline: pipeline,
            signingEngine: signingEngine,
            analyticsJournal: makeAnalyticsJournal(),
            signingPresets: presets,
            signingHistory: history,
            provisioningProfiles: profiles,
            exportCenter: exports,
            signingOperations: signingOperations,
            signingQueue: signingQueue,
            storageManagement: storage,
            preferencesStore: preferences,
            biometricAuthenticator: biometricAuthenticator
        )
        environment.provisioningProfileImporter = makeProvisioningProfileImporter()
        environment.profileCompatibility = ProfileCompatibilityUseCase(identityStore: identityStore)
        environment.profileSelections = UserDefaultsProfileSelectionStore()
        // The hub seeds icons it extracts during analysis into this same
        // instance, so the cards show them without a second extraction.
        environment.appIcons = appIcons
        environment.signingPresetWorkflow = signingPresetWorkflow
        environment.signingDiagnostics = diagnostics
        environment.identityAnnotations = identityAnnotationsStore
        // The Identity Center reads the same stores the tabs read — one
        // identity store, one profile library, one library, one
        // annotation store, one journal — so its snapshot can never
        // disagree with what those tabs show.
        environment.identityCenter = IdentityCenterService(
            identityStore: identityStore,
            profiles: profiles,
            library: library,
            annotations: identityAnnotationsStore,
            history: history
        )
        environment.libraryOrganizer = makeLibraryOrganizer()
        // Nova: the Smart Workspace reads the identity store, the profile
        // library, the application library, and the signing history the
        // tabs already read; only its own small state file is new.
        //
        // Gated on its own stage. The workspace is staged for rc2, so at
        // every earlier stop the service must not be constructed at all:
        // building it unconditionally made a Release build write
        // `SmartWorkspace.json` on every signing session and every
        // application detail view, from dev1 onward, on behalf of a screen
        // nothing could reach. `nil` is a supported state — both call
        // sites already read it through `?.`.
        environment.smartWorkspace = ReleaseTrain.isAvailable(.smartWorkspace)
            ? SmartWorkspaceService(
                identityStore: identityStore,
                profiles: profiles,
                library: library,
                signingHistory: history,
                state: FileWorkspaceStateStore(
                    documentLocation: libraryRootDirectory.appendingPathComponent("SmartWorkspace.json")
                )
            )
            : nil
        environment.applicationProvenance = makeApplicationProvenanceExtraction()
        environment.libraryExport = makeLibraryExportPreparation()
        environment.droppedFiles = droppedFiles
        environment.queueNotifier = queueNotifier
        environment.binaryInspection = makeBinaryInspection(intake: intake, library: library)
        environment.storeBrowser = StoreBrowserModel(
            repository: StoreRepository(storage: FileStoreCache(directory: FileStoreCache.root)),
            downloads: StoreDownloadQueue(directory: FileStoreCache.root.appendingPathComponent("Quarantine"))
        )
        let resourceReader = cachingLibraryReaderProvider()
        environment.resourceInspection = makeResourceStudioInspection(library: library, readerProvider: resourceReader)
        if let binary = environment.binaryInspection {
            let historyURL = libraryRootDirectory.appendingPathComponent("ReleaseReadiness.json")
            environment.releaseReadiness = ReleaseReadinessService(
                diagnostics: diagnostics, exports: exports, operations: signingOperations,
                binary: binary, history: ReleaseReadinessHistory(location: historyURL),
                bundles: environment.bundleInspection, library: library, identities: identityStore)
        }
        let downloadNotifier = LocalDownloadNotifier()
        let repositoryDirectory = makeRepositoryDirectory()
        let downloadCenter = makeDownloadCenter(
            library: library,
            importHub: environment.importHub,
            notifier: downloadNotifier,
            catalogs: { @MainActor in repositoryDirectory.catalogs }
        )
        environment.downloadNotifier = downloadNotifier
        environment.repositoryDirectory = repositoryDirectory
        environment.downloadCenter = downloadCenter
        environment.installationWorkspace = makeInstallationWorkspace(
            library: library,
            history: history,
            exports: exports
        )
        environment.performanceEngine = makePerformanceEngine(
            appIcons: appIcons,
            preferences: preferencesSnapshot
        )
        attachWorkspaceServices(to: &environment)
        return environment
    }

    // MARK: - Performance Engine

    /// The one entry-table cache every read-only inspector of library
    /// packages shares, so the explorer, App Details, the binary inspector,
    /// provenance, and icons each scan a package's central directory once
    /// between them rather than once each.
    static let sharedEntryTables = InspectionResultCache<[ArchiveEntry]>()

    /// The background scheduler the engine, the thumbnail cache, and the
    /// metadata index run on. One per process.
    static let sharedScheduler = BackgroundWorkScheduler()
}
