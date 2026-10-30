import Foundation

/// Workspace services: the tweak library, revocation exposure checks,
/// repository release feeds, per-application protection, and the storage
/// gauge.
///
/// Part of `CompositionRoot`, which chooses every concrete implementation
/// and wires the layers together. Each factory here returns `nil`-safe
/// values the environment attaches as optional services, so a platform
/// without one of them degrades to the interface simply not offering it.
extension CompositionRoot {

    /// The tweak library for this launch: records and payload bytes under
    /// the library root's `Tweaks` workspace.
    static func makeTweakLibrary() -> TweakLibraryService {
        let store = FileTweakLibrary(directory: libraryRootDirectory.appendingPathComponent("Tweaks", isDirectory: true))
        return TweakLibraryService(store: store, payloads: store, digest: makeMessageDigest())
    }

    /// The revocation exposure service for this launch: a bounded URLSession
    /// probe and a file-backed report catalog next to the other workspace
    /// catalogs.
    static func makeRevocationService() -> CertificateRevocationService {
        CertificateRevocationService(
            probe: URLSessionRevocationProbe(),
            reports: FileRevocationReportStore(
                location: libraryRootDirectory.appendingPathComponent("RevocationReports.json", isDirectory: false)
            )
        )
    }

    /// The repository release feed provider for this launch.
    static func makeReleaseFeedProvider() -> GitHubReleaseSourceProvider {
        GitHubReleaseSourceProvider(
            transport: URLSessionReleaseFeedTransport(),
            catalog: FileReleaseFeedCatalog(
                location: libraryRootDirectory.appendingPathComponent("ReleaseFeeds.json", isDirectory: false)
            )
        )
    }

    /// The per-application protection coordinator for this launch.
    static func makeAppProtection() -> AppProtectionService {
        AppProtectionService(
            store: FileAppProtectionStore(
                location: libraryRootDirectory.appendingPathComponent("AppProtection.json", isDirectory: false)
            )
        )
    }

    /// The storage gauge for this launch.
    static func makeStorageGauge() -> StorageGaugeService {
        StorageGaugeService()
    }

    /// The local transfer service for this launch.
    ///
    /// The workspace lives beside the other ZynSign workspaces, so what a
    /// session received is the same kind of file as everything else the app
    /// stores — visible to Files, included in the storage gauge, and not
    /// hidden in a temporary directory the system may reclaim. The listener is
    /// created per session and torn down with it.
    static func makeLocalTransferService() -> LocalTransferService {
        LocalTransferService(
            stagingDirectory: libraryRootDirectory
                .appendingPathComponent("LocalTransfer", isDirectory: true),
            random: SystemSecureRandomSource(),
            makeTransport: { NetworkLocalTransferServer() }
        )
    }

    /// Attaches every workspace service to an environment under
    /// construction. Called once by `makeApplicationEnvironment()`.
    static func attachWorkspaceServices(to environment: inout ApplicationEnvironment) {
        environment.tweakLibrary = makeTweakLibrary()
        environment.tweakAutoInjectRules = FileTweakAutoInjectStore(
            location: libraryRootDirectory.appendingPathComponent("TweakAutoInjectRules.json", isDirectory: false)
        )
        environment.packageModifier = PackageModificationService()
        environment.revocationService = makeRevocationService()
        environment.releaseFeeds = makeReleaseFeedProvider()
        environment.selfUpdateChecker = SelfUpdateChecker(transport: URLSessionReleaseFeedTransport())
        environment.portableWorkspaceSync = PortableWorkspaceSyncService()
        environment.appProtection = makeAppProtection()
        environment.storageGauge = makeStorageGauge()
        environment.localTransfer = makeLocalTransferService()
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? libraryRootDirectory
        environment.lanWebWorkspace = LANWebWorkspaceService(
            rootDirectory: documentsDir.appendingPathComponent("WebWorkspace", isDirectory: true),
            makeTransport: { NetworkLANWebWorkspaceServer() }
        )
        environment.guestContainerHost = GuestContainerHostService(
            documentsDirectory: documentsDir,
            runtimeLoader: PosixGuestRuntimeLoader()
        )
        let endpointConfig = DeviceBridgeEndpointConfig()
        let digest = makeMessageDigest()
        environment.deviceBridgeController = DeviceBridgeController(
            recordStore: KeychainPairingRecordStore(digest: digest),
            digest: digest,
            endpointConfig: endpointConfig,
            isTransportComposed: NetworkDeviceBridgeTransport.supportsAuthenticatedSessions,
            makeTransport: { NetworkDeviceBridgeTransport(endpointConfig: endpointConfig) }
        )
        let identityStore = environment.identityStore
        let profileImporter = environment.provisioningProfileImporter
        let profileLibrary = environment.provisioningProfiles
        environment.appleAccountProvisioner = AppleAccountProvisioningService(
            portalClient: URLSessionAppleDeveloperPortalClient(),
            csrProvisioner: KeychainCSRIdentityProvisioner(identityStore: identityStore),
            profileImporter: profileImporter,
            profileLibrary: profileLibrary,
            settingsURL: libraryRootDirectory.appendingPathComponent("AppleProvisioningConfig.json", isDirectory: false)
        )
    }
}
