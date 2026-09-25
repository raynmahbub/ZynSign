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
    /// Facts about the running application, shown by the shell.
    let applicationInfo: ApplicationInfo

    /// The package-import use case: one package, imported once. It is
    /// composed once and handed to the import queue, which is the only path
    /// the interface imports through; a caller that needs the capability
    /// without scheduling — a test, or a future single-shot import — reaches
    /// it here rather than constructing a second pipeline.
    let packageImport: IPAPackageImport

    /// The import queue: the entry point every screen, share-sheet hand-off,
    /// and drop lands on. It owns scheduling, per-job progress and
    /// cancellation, retries, the duplicate question, and the batch summary,
    /// and it runs imports through `packageImport`.
    let packageImportQueue: PackageImportQueue

    /// The library use case: lists, admits, and removes the application
    /// records behind the Applications area.
    let library: ApplicationLibrary

    /// The bundle contents inspection use case: describes, read-only, the
    /// structure of a library application's bundle for the explorer.
    let bundleInspection: IPABundleContentsInspection

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

    /// The signing queue: the job orchestration every queued signing runs
    /// through. It owns scheduling, priorities, per-job progress,
    /// cancellation, retries, notices, and persistence, and it runs jobs
    /// through the pipeline's executor. Screens enqueue through it and
    /// observe it; none of them owns a signing task of its own once a job
    /// is queued. The inline Smart Sign screen keeps its direct pipeline
    /// path for the single, foreground, configured-by-hand run.
    let signingQueue: SigningQueue

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

    /// Imports `.mobileprovision` files into the provisioning-profile
    /// library. Presented by the Profiles tab; `nil` where the composition
    /// root supplies no profile storage, and treated as read-only after
    /// construction.
    var provisioningProfileImporter: ProvisioningProfileImporter? = nil

    /// Extracts application icons from the packages the library holds, for
    /// the Home and Library cards. `nil` where no reader provider is
    /// composed; treated as read-only after construction.
    var appIcons: AppIconExtraction? = nil

    /// The local-notification boundary for settled signing jobs, held as
    /// the port. Optional: `nil` means the queue posts in-app notices
    /// only. The composition root installs the platform notifier, which is
    /// observable; screens that bind the user's notification preference
    /// reach the concrete type through a presentation-side cast, the same
    /// way the signing screen holds the Live Activity service.
    var queueNotifier: (any SigningQueueNotifying)? = nil

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

    /// Returns the file URL of a delivered signed container by its file
    /// name, under the same `Documents/Signed` convention the signing
    /// queue and the inline signing screen both deliver to. A label the
    /// queue captured becomes a location only here, so no screen names a
    /// path itself.
    func signedOutputFileURL(named fileName: String) -> URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.temporaryDirectory
        return documents
            .appendingPathComponent("Signed", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Returns the file URL of an imported provisioning profile's original
    /// bytes by the file name its summary recorded, under the same library
    /// storage convention the profile importer writes to. The queue's
    /// configuration sheet reads a chosen library profile's bytes through
    /// this location; the summary itself never carries them.
    func provisioningProfileFileURL(named sourceFileName: String) -> URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ZynSignLibrary", isDirectory: true)
            .appendingPathComponent(sourceFileName, isDirectory: false)
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
