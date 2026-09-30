import Foundation

/// The application-layer object handed to the presentation layer at launch.
///
/// `ApplicationEnvironment` is the seam between the SwiftUI shell and the
/// application layer: it carries the dependencies the presentation layer is
/// allowed to see, constructed by the composition root. Views read it from
/// the SwiftUI environment; they never construct application-layer or domain
/// objects themselves.
///
/// The environment carries the application's own descriptive information,
/// the package-import use case coordinated by the Import area, and the
/// library and bundle-inspection use cases coordinated by the Applications
/// area. Future use cases — signing — will be constructed by the
/// composition root and surfaced here, which keeps dependency substitution
/// and testing straightforward.
struct ApplicationEnvironment {
    /// App-owned Store services survive navigation between Store and Downloads.
    var storeBrowser: StoreBrowserModel? = nil

    /// Facts about the running application, shown by the shell.
    let applicationInfo: ApplicationInfo

    /// The one-shot package-import use case: one package, imported once,
    /// asking about duplicates as it goes. The interface imports through
    /// `importHub` instead; a caller that needs the single-shot capability —
    /// a test, or a future automation — reaches it here rather than
    /// constructing a second pipeline.
    let packageImport: IPAPackageImport

    /// The Smart Import Hub: the single entry point every screen, share-sheet
    /// hand-off, Open In request, and drop lands on. It owns the multi-item
    /// queue, archive handling, analysis, the preview, the Duplicate
    /// Resolution Center, the summary, the history, and interrupted-import
    /// recovery.
    let importHub: ImportHub

    /// The library use case: lists, admits, and removes the application
    /// records behind the Applications area.
    let library: ApplicationLibrary

    /// The bundle contents inspection use case: describes, read-only, the
    /// structure of a library application's bundle for the explorer. It reads
    /// the entry table and no file bytes.
    let bundleInspection: IPABundleContentsInspection

    /// The comprehensive, bounded inspection use case for the App Details
    /// metadata, archive summary, nested-code summary, and diagnostics.
    let applicationDetailsInspection: IPAApplicationDetailsInspection

    /// On-demand preview of one entry. Used only when the user opens a file,
    /// framework, or extension. It never writes the package.
    let bundleEntryInspection: IPABundleEntryInspection

    /// The signing-identity store. The certificate list and signing capability
    /// are resolved through this port; private-key bytes never leave Platform.
    let identityStore: any IdentityStore

    /// Imports PKCS#12 containers into the identity store. Presented by the
    /// Certificates settings; the store remains the owner of registrations.
    let pkcs12Importer: any SigningIdentityImporter

    /// The end-to-end signing pipeline. Composed but not invoked until the
    /// user explicitly signs an imported package with a chosen identity and
    /// provisioning profile.
    let signingPipeline: SignApplicationPipeline

    /// The signing engine: the coordinator that executes one complete signing
    /// run — isolated working copy, pre-signing bundle validation, inner-first
    /// nested signing, application signing, independent verification, and
    /// packaging — behind one entry point and one progress stream. The
    /// Signing screen drives this and nothing below it directly.
    let signingEngine: SigningEngineCoordinator

    /// The local activity journal: on-device-only analytics the Settings
    /// → Analytics screen reads. Recording goes through
    /// `recordAnalyticsEvent(category:name:succeeded:)`, which enforces the
    /// `AnalyticsPolicy` journal preference; nothing here can transmit.
    let analyticsJournal: any LocalAnalyticsRecording

    /// The signing-preset store: lets users save and reuse signing
    /// configurations. Optional so older composition paths and tests can
    /// omit it; production paths supplied by the composition root.
    let signingPresets: (any SigningPresetStore)?

    /// The signing-history store: the on-device journal of past signing
    /// runs. Optional for the same reason as `signingPresets`.
    let signingHistory: (any SigningHistoryStore)?

    /// The provisioning-profile library: lists summaries of imported
    /// `.mobileprovision` files. Optional for the same reason as
    /// `signingPresets`.
    let provisioningProfiles: ProvisioningProfileLibrary?

    /// The Export Center: the signed artifacts ZynSign produced, each with the
    /// current availability of the file behind it. It owns naming, recording,
    /// verification results, and the removal of exported artifacts — and it
    /// cannot reach the library's own artifacts, which is why deleting signed
    /// output can never delete the application it came from.
    let exportCenter: ExportCenter

    /// The signing operation runner: the one path that signs an application
    /// and delivers the result to the Export Center. It records the run's
    /// timeline, its failure when it fails, and its artifact when it
    /// succeeds, so the signing history is written by the operation that
    /// happened rather than assembled by an interface.
    let signingOperations: SigningOperationCenter

    /// The signing queue: the job orchestration every queued signing runs
    /// through. It owns scheduling, priorities, per-job progress,
    /// cancellation, retries, notices, and persistence, and it runs each job
    /// through `signingOperations` — so a queued job is isolated, exported,
    /// verified, and journaled exactly like any other signing operation.
    /// Screens enqueue through it and observe it; none of them owns a
    /// signing task of its own once a job is queued.
    let signingQueue: SigningQueue

    /// The storage use case: what ZynSign is using, and the cleanups the
    /// storage screen may run. It never removes an imported application.
    let storageManagement: StorageManagement

    /// Imports `.mobileprovision` files into the provisioning-profile
    /// library. Presented by the Profiles tab; `nil` where the composition
    /// root supplies no profile storage, and treated as read-only after
    /// construction.
    var provisioningProfileImporter: ProvisioningProfileImporter? = nil

    /// The Smart Compatibility Engine and Profile Matching use case: the
    /// pre-sign checks, the Compatibility Summary, and the automatic
    /// profile suggestion for an app. Optional so older composition paths
    /// and tests can omit it; production paths supply it.
    var profileCompatibility: ProfileCompatibilityUseCase? = nil

    /// The profile-selection store behind "Use for Signing" and the
    /// per-app manual override. Optional for the same reason.
    var profileSelections: (any ProfileSelectionStore)? = nil

    /// Extracts application icons from the packages the library holds, for
    /// the Home and Library cards. `nil` where no reader provider is
    /// composed; treated as read-only after construction.
    var appIcons: AppIconExtraction? = nil

    /// Recommendation, confirmation, and usage recording for signing presets.
    /// `nil` in tests that do not install presets. Production composition
    /// installs it. One-tap and bulk preset signing enqueue through
    /// `signingQueue`; this workflow does not sign.
    var signingPresetWorkflow: SigningPresetWorkflow? = nil

    /// Shared read-only analyzer for import, per-app health and signing.
    /// Profile/entitlement evidence stays in memory; only redacted issue
    /// codes enter its bounded on-device journal.
    var signingDiagnostics: SigningDiagnosticsService? = nil

    var releaseReadiness: ReleaseReadinessService? = nil

    /// The local-only annotation store behind the Certificates area.
    var identityAnnotations: (any IdentityAnnotationsStore)? = nil

    /// The Developer Identity Center: one read of each store per snapshot,
    /// every signing relationship answered from it. The dashboard, the
    /// team workspace, the health center, the conflict list, the forecast,
    /// the timeline, and the signing screen's recommendation all read this
    /// one service. Optional for the same reasons as its peers.
    var identityCenter: IdentityCenterService? = nil

    /// The user's preferences: one document, loaded once at launch and
    /// written whole whenever a setting changes. The Settings Control Center
    /// reads and writes through this port, and the shell reads it once to
    /// decide where ZynSign stages its work.
    let preferencesStore: any PreferencesStore

    /// The boundary through which ZynSign asks the user to authenticate. The
    /// platform implementation owns LocalAuthentication and nothing else
    /// does; the application learns only whether an attempt succeeded.
    let biometricAuthenticator: any BiometricAuthenticating

    /// The library-organization use case: collections and usage. `nil`
    /// where no organization storage is composed, in which case the library
    /// offers no collections; treated as read-only after construction.
    var libraryOrganizer: LibraryOrganizer? = nil

    /// The Installation Workspace use case: joins the library, the signing
    /// journal, the export catalog, and the installed-applications records
    /// into candidates, evaluates readiness, runs verification on demand,
    /// and records the attempts and confirmations behind the Installed Apps
    /// Library. `nil` where no composition supplies it, in which case the
    /// interface does not offer the workspace; treated as read-only after
    /// construction.
    var installationWorkspace: InstallationWorkspace? = nil

    /// Reads the developer and team each library package declares, for
    /// search and the Team filter. `nil` where no reader provider is
    /// composed; treated as read-only after construction.
    var applicationProvenance: ApplicationProvenanceExtraction? = nil

    /// Prepares library package files for the share sheet under readable
    /// names. `nil` where no export location is composed, in which case the
    /// library offers no Export; treated as read-only after construction.
    var libraryExport: LibraryExportPreparation? = nil

    /// The tweak library: imported payloads the user keeps for staging,
    /// with records, groups, and fingerprint-based duplicate detection.
    /// `nil` where no tweak storage is composed; treated as read-only after
    /// construction.
    var tweakLibrary: TweakLibraryService? = nil

    /// The revocation exposure service: checks whether a certificate's
    /// revocation channels are reachable right now and keeps the most
    /// recent result per certificate. Optional for the same reason as its
    /// peers.
    var revocationService: CertificateRevocationService? = nil

    /// The repository release feed provider: the feeds the user added and
    /// the releases those feeds list. Optional for the same reason.
    var releaseFeeds: GitHubReleaseSourceProvider? = nil

    /// The per-application protection coordinator: per-app lock, the
    /// concealed vault, and the visibility decisions listings apply.
    /// Optional for the same reason.
    var appProtection: AppProtectionService? = nil

    /// The storage gauge: volume capacity, free-space pressure, and the
    /// application's own footprint, classified for the Files screen.
    /// Optional for the same reason.
    var storageGauge: StorageGaugeService? = nil

    /// Receives files dropped onto ZynSign into a ZynSign-owned inbox, from
    /// which they are handed to `importHub`. `nil` where drops are not
    /// supported; treated as read-only after construction.
    var droppedFiles: (any DroppedFileReceiving)? = nil

    /// The local-notification boundary for settled signing jobs, held as
    /// the port. Optional: `nil` means the queue posts in-app notices only.
    /// The composition root installs the platform notifier, which is
    /// observable; the Settings screen that binds the user's notification
    /// preference reaches the concrete type through a presentation-side
    /// cast.
    var queueNotifier: (any SigningQueueNotifying)? = nil

    /// The Download Center: queue, validation, updates, and import handoff.
    /// `nil` where a composition does not install it. Production installs it.
    /// Screens observe it; they do not own transfers.
    var downloadCenter: DownloadCenter? = nil

    /// Configured repositories and the catalogs last validated from them.
    /// Shared by the App Store and the update engine.
    var repositoryDirectory: RepositoryDirectory? = nil

    /// Local notifications for download outcomes. Optional. In-app notices
    /// are posted either way. Off unless the user turns them on.
    var downloadNotifier: (any DownloadNotifying)? = nil

    /// The Binary & Signature Inspector use case: inspects, read-only, every
    /// executable in a library application's bundle — Mach-O structure,
    /// load commands, and code signature — and verifies each signature on
    /// the device. `nil` where no composition supplies it, in which case the
    /// interface does not offer the inspector; treated as read-only after
    /// construction.
    var binaryInspection: IPABinaryInspection? = nil

    /// The Resource & Asset Studio inspection use case: inspects app icons,
    /// launch assets, images, fonts, media, and localization tables in an
    /// imported IPA bundle. `nil` where no composition supplies it; treated
    /// as read-only after construction.
    var resourceInspection: IPAResourceStudioInspection? = nil

    /// The Performance Engine: the background scheduler, thumbnail and
    /// metadata caches, memory manager, cache policies, benchmarks, and
    /// launch timeline behind Settings → Advanced → Performance. `nil` in
    /// compositions that do not measure themselves (most tests), in which
    /// case every screen falls back to uncached reads and the Performance
    /// page says the engine is not composed; treated as read-only after
    /// construction.
    var performanceEngine: PerformanceEngine? = nil

    /// Nova: the Smart Workspace 3.0 use case — greeting, widget order,
    /// last session, and the Nova Assistant's recommendations, read from
    /// the same stores the tabs read. `nil` in compositions that do not
    /// compose it (most tests); Home then shows the classic dashboard.
    var smartWorkspace: SmartWorkspaceService? = nil

    /// Records one local activity event when the journal preference allows.
    ///
    /// This is the only recording path the presentation layer uses. It
    /// checks `AnalyticsPolicy.isJournalEnabled` so a call site cannot
    /// bypass the preference, and it constructs the event itself so a call
    /// site cannot attach an identifier or free-form text.
    func recordAnalyticsEvent(
        category: LocalAnalyticsEvent.Category,
        name: String,
        succeeded: Bool
    ) {
        // Nothing is recorded before the release that ships the journal, so
        // users never find history they could not see or clear.
        guard ReleaseTrain.isAvailable(.activityJournal), AnalyticsPolicy.isJournalEnabled else { return }
        analyticsJournal.record(
            LocalAnalyticsEvent(category: category, name: name, succeeded: succeeded)
        )
    }

    /// Returns the file URL of the artifact the library holds for `id`, when
    /// the library holds one. The location is the library artifact directory
    /// plus the identifier and the canonical `ipa` extension; no part of a
    /// selected document's name reaches the file system.
    func artifactFileURL(for id: ArtifactIdentifier) -> URL {
        // The directory is the same one the composition root binds to the
        // intake and the library. Re-deriving it here keeps the location
        // convention in one place without exposing the store's internals to
        // the presentation layer.
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ZynSignLibrary", isDirectory: true)
            .appendingPathComponent("Artifacts", isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: false)
            .appendingPathExtension("ipa")
    }
}
