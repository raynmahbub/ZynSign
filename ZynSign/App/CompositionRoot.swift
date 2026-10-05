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

    private struct FoundationServices {
        let preferences: any PreferencesStore
        let preferencesSnapshot: ZynSignPreferences
        let biometricAuthenticator: any BiometricAuthenticating
        let intake: SecurityScopedArtifactIntake
        let diagnosticHistory: any SigningDiagnosticsHistoryStore
        let library: ApplicationLibrary
        let identityStore: any IdentityStore
        let identityAnnotations: any IdentityAnnotationsStore
        let pkcs12DocumentReader: any PKCS12DocumentReading
        let appIcons: AppIconExtraction
        let droppedFiles: any DroppedFileReceiving
    }

    private struct SigningServices {
        let diagnostics: SigningDiagnosticsService
        let packageImport: IPAPackageImport
        let pkcs12Importer: any SigningIdentityImporter
        let pipeline: SignApplicationPipeline
        let engine: SigningEngineCoordinator
        let presets: any SigningPresetStore
        let history: any SigningHistoryStore
        let profiles: ProvisioningProfileLibrary
        let exports: ExportCenter
        let storage: StorageManagement
        let operations: SigningOperationCenter
        let queueNotifier: (any SigningQueueNotifying)?
        let presetWorkflow: SigningPresetWorkflow
        let queue: SigningQueue
    }

    static func makeApplicationEnvironment() -> ApplicationEnvironment {
        RecoveryStore.applyPending(at: libraryRootDirectory)
        let foundation = makeFoundationServices()
        let signing = makeSigningServices(foundation: foundation)
        var environment = makePrimaryEnvironment(foundation: foundation, signing: signing)
        attachIdentityServices(to: &environment, foundation: foundation, signing: signing)
        attachInspectionServices(to: &environment, foundation: foundation, signing: signing)
        attachStoreServices(to: &environment)
        attachDeliveryServices(to: &environment, foundation: foundation, signing: signing)
        environment.performanceEngine = makePerformanceEngine(
            appIcons: foundation.appIcons,
            preferences: foundation.preferencesSnapshot
        )
        attachWorkspaceServices(to: &environment)
        return environment
    }

    private static func makeFoundationServices() -> FoundationServices {
        // Preferences come first: the working-directory choice decides the intake staging path.
        let preferences = makePreferencesStore()
        let preferencesSnapshot = MainActor.assumeIsolated { preferences.snapshot }
        let biometricAuthenticator = makeBiometricAuthenticator()
        let intake = SecurityScopedArtifactIntake(
            directory: importStagingDirectory(preferences: preferencesSnapshot)
        )
        let diagnosticHistory = makeSigningDiagnosticsHistoryStore()
        let library = makeApplicationLibrary(intake: intake, diagnosticHistory: diagnosticHistory)
        let identityStore = makeIdentityStore()
        let identityAnnotations = makeIdentityAnnotationsStore()
        let pkcs12DocumentReader = CoordinatedPKCS12DocumentReader()
        let appIcons = makeAppIconExtraction()
        let droppedFiles = DropInboxFileReceiver(directory: importDropInboxDirectory)
        return FoundationServices(
            preferences: preferences,
            preferencesSnapshot: preferencesSnapshot,
            biometricAuthenticator: biometricAuthenticator,
            intake: intake,
            diagnosticHistory: diagnosticHistory,
            library: library,
            identityStore: identityStore,
            identityAnnotations: identityAnnotations,
            pkcs12DocumentReader: pkcs12DocumentReader,
            appIcons: appIcons,
            droppedFiles: droppedFiles
        )
    }

    private static func makeSigningServices(foundation: FoundationServices) -> SigningServices {
        let diagnostics = makeSigningDiagnostics(
            library: foundation.library,
            intake: foundation.intake,
            identities: foundation.identityStore,
            history: foundation.diagnosticHistory
        )
        let packageImport = makePackageImport(
            intake: foundation.intake,
            library: foundation.library,
            diagnostics: diagnostics
        )
        let pkcs12Importer = makePKCS12Importer(identityStore: foundation.identityStore)
        let pipeline = makeSignApplicationPipeline(identityStore: foundation.identityStore)
        let signingEngine = makeSigningEngine(identityStore: foundation.identityStore, pipeline: pipeline)
        let presets = makeSigningPresetStore()
        let history = makeSigningHistoryStore()
        let profiles = makeProvisioningProfileLibrary()
        let exports = makeExportCenter()
        let storage = makeStorageManagement(
            exports: exports,
            history: history,
            preferences: foundation.preferencesSnapshot
        )
        let operations = makeSigningOperationCenter(
            pipeline: pipeline,
            exports: exports,
            history: history
        )
        let queueNotifier = makeSigningQueueNotifier()
        let presetWorkflow = makeSigningPresetWorkflow(
            presets: presets,
            profiles: profiles,
            identities: foundation.identityStore
        )
        let queue = makeSigningQueue(
            operations: operations,
            library: foundation.library,
            notifier: queueNotifier,
            presetUsageRecorder: { outcome in
                Task { try? await presetWorkflow.record(outcome) }
            }
        )
        return SigningServices(
            diagnostics: diagnostics,
            packageImport: packageImport,
            pkcs12Importer: pkcs12Importer,
            pipeline: pipeline,
            engine: signingEngine,
            presets: presets,
            history: history,
            profiles: profiles,
            exports: exports,
            storage: storage,
            operations: operations,
            queueNotifier: queueNotifier,
            presetWorkflow: presetWorkflow,
            queue: queue
        )
    }

    private static func makePrimaryEnvironment(
        foundation: FoundationServices,
        signing: SigningServices
    ) -> ApplicationEnvironment {
        ApplicationEnvironment(
            applicationInfo: ApplicationInfo.current(bundle: .main),
            packageImport: signing.packageImport,
            importHub: makeImportHub(
                intake: foundation.intake,
                library: foundation.library,
                appIcons: foundation.appIcons,
                droppedFiles: foundation.droppedFiles,
                diagnostics: signing.diagnostics
            ),
            library: foundation.library,
            bundleInspection: makeBundleContentsInspection(intake: foundation.intake, library: foundation.library),
            applicationDetailsInspection: makeApplicationDetailsInspection(
                intake: foundation.intake,
                library: foundation.library
            ),
            bundleEntryInspection: makeBundleEntryInspection(intake: foundation.intake, library: foundation.library),
            identityStore: foundation.identityStore,
            pkcs12Importer: signing.pkcs12Importer,
            pkcs12DocumentReader: foundation.pkcs12DocumentReader,
            signingPipeline: signing.pipeline,
            signingEngine: signing.engine,
            analyticsJournal: makeAnalyticsJournal(),
            signingPresets: signing.presets,
            signingHistory: signing.history,
            provisioningProfiles: signing.profiles,
            exportCenter: signing.exports,
            signingOperations: signing.operations,
            signingQueue: signing.queue,
            storageManagement: signing.storage,
            preferencesStore: foundation.preferences,
            biometricAuthenticator: foundation.biometricAuthenticator
        )
    }

    private static func attachIdentityServices(
        to environment: inout ApplicationEnvironment,
        foundation: FoundationServices,
        signing: SigningServices
    ) {
        environment.provisioningProfileImporter = makeProvisioningProfileImporter()
        environment.profileCompatibility = ProfileCompatibilityUseCase(identityStore: foundation.identityStore)
        environment.profileSelections = UserDefaultsProfileSelectionStore()
        environment.appIcons = foundation.appIcons
        environment.signingPresetWorkflow = signing.presetWorkflow
        environment.signingDiagnostics = signing.diagnostics
        environment.identityAnnotations = foundation.identityAnnotations
        // Identity Center and the tabs share the same stores, so their snapshots agree.
        environment.identityCenter = IdentityCenterService(
            identityStore: foundation.identityStore,
            profiles: signing.profiles,
            library: foundation.library,
            annotations: foundation.identityAnnotations,
            history: signing.history
        )
        environment.libraryOrganizer = makeLibraryOrganizer()
        environment.smartWorkspace = makeSmartWorkspace(foundation: foundation, signing: signing)
        environment.applicationProvenance = makeApplicationProvenanceExtraction()
        environment.libraryExport = makeLibraryExportPreparation()
        environment.droppedFiles = foundation.droppedFiles
        environment.queueNotifier = signing.queueNotifier
    }

    private static func makeSmartWorkspace(
        foundation: FoundationServices,
        signing: SigningServices
    ) -> SmartWorkspaceService? {
        // Do not create its state store before the feature's release-train stage.
        guard ReleaseTrain.isAvailable(.smartWorkspace) else { return nil }
        return SmartWorkspaceService(
            identityStore: foundation.identityStore,
            profiles: signing.profiles,
            library: foundation.library,
            signingHistory: signing.history,
            state: FileWorkspaceStateStore(
                documentLocation: libraryRootDirectory.appendingPathComponent("SmartWorkspace.json")
            )
        )
    }

    private static func attachInspectionServices(
        to environment: inout ApplicationEnvironment,
        foundation: FoundationServices,
        signing: SigningServices
    ) {
        environment.binaryInspection = makeBinaryInspection(intake: foundation.intake, library: foundation.library)
        environment.resourceInspection = makeResourceStudioInspection(
            library: foundation.library,
            readerProvider: cachingLibraryReaderProvider()
        )
        if let binary = environment.binaryInspection {
            let bundleInspection = environment.bundleInspection
            environment.releaseReadiness = ReleaseReadinessService(
                diagnostics: signing.diagnostics,
                exports: signing.exports,
                operations: signing.operations,
                binary: binary,
                history: ReleaseReadinessHistory(
                    location: libraryRootDirectory.appendingPathComponent("ReleaseReadiness.json")
                ),
                bundles: bundleInspection,
                library: foundation.library,
                identities: foundation.identityStore
            )
        }
    }

    private static func attachStoreServices(to environment: inout ApplicationEnvironment) {
        environment.storeBrowser = StoreBrowserModel(
            repository: StoreRepository(storage: FileStoreCache(directory: FileStoreCache.root)),
            downloads: StoreDownloadQueue(directory: FileStoreCache.root.appendingPathComponent("Quarantine"))
        )
        environment.ipswFirmwareCatalog = IPSWFirmwareCatalogService(
            transport: URLSessionIPSWCatalogTransport()
        )
    }

    private static func attachDeliveryServices(
        to environment: inout ApplicationEnvironment,
        foundation: FoundationServices,
        signing: SigningServices
    ) {
        let downloadNotifier = LocalDownloadNotifier()
        let repositoryDirectory = makeRepositoryDirectory()
        let importHub = environment.importHub
        let downloadCenter = makeDownloadCenter(
            library: foundation.library,
            importHub: importHub,
            notifier: downloadNotifier,
            catalogs: { @MainActor in repositoryDirectory.catalogs }
        )
        environment.downloadCenter = downloadCenter
        environment.downloadNotifier = downloadNotifier
        environment.repositoryDirectory = repositoryDirectory
        environment.installationWorkspace = makeInstallationWorkspace(
            library: foundation.library,
            history: signing.history,
            exports: signing.exports
        )
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
