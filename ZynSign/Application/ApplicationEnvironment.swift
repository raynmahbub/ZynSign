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

    /// The package-import use case, coordinated by the Import area.
    let packageImport: IPAPackageImport

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

    /// The local activity journal: on-device-only analytics the Settings
    /// → Analytics screen reads. Recording goes through
    /// `recordAnalyticsEvent(category:name:succeeded:)`, which enforces the
    /// `AnalyticsPolicy` journal preference; nothing here can transmit.
    let analyticsJournal: any LocalAnalyticsRecording

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
