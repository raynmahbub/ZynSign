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

    /// Attaches every workspace service to an environment under
    /// construction. Called once by `makeApplicationEnvironment()`.
    static func attachWorkspaceServices(to environment: inout ApplicationEnvironment) {
        environment.tweakLibrary = makeTweakLibrary()
        environment.revocationService = makeRevocationService()
        environment.releaseFeeds = makeReleaseFeedProvider()
        environment.appProtection = makeAppProtection()
        environment.storageGauge = makeStorageGauge()
    }
}
