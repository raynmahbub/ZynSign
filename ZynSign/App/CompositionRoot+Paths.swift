import Foundation

/// Where ZynSign keeps things on disk.
///
/// Part of `CompositionRoot`, which chooses every concrete
/// implementation and wires the layers together. Split out of the
/// original single file for readability; the members are unchanged.
extension CompositionRoot {

    /// The on-disk location of the installed-applications catalog. It lives
    /// beside the signing history and the export catalog: a record of what
    /// ZynSign did and what the user confirmed, not a file the user works
    /// with.
    static func installedApplicationsCatalogLocation() -> URL {
        libraryRootDirectory.appendingPathComponent("InstalledApplications.json", isDirectory: false)
    }

    /// The durable directory holding the signing queue's snapshot and its
    /// queue-owned profile copies, under the same library root as the
    /// catalogs. Created on first use; nothing is created at composition
    /// time.
    static var signingQueueDirectory: URL {
        libraryRootDirectory.appendingPathComponent("SigningQueue", isDirectory: true)
    }

    /// The file URL of the artifact the library holds for `id`, under the
    /// library's own storage convention. The same convention
    /// `ApplicationEnvironment.artifactFileURL(for:)` re-derives for the
    /// presentation layer; the queue receives it as a resolver so it never
    /// hard-codes a location itself.
    static func libraryArtifactFileURL(for id: ArtifactIdentifier) -> URL {
        libraryArtifactDirectory
            .appendingPathComponent(id.rawValue, isDirectory: false)
            .appendingPathExtension("ipa")
    }

    /// The on-disk location of the identity annotation catalog. Lives under
    /// Application Support so it is not part of any iCloud or iTunes
    /// backup, in the same directory as the other local workspaces.
    static func identityAnnotationsCatalogLocation() -> URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ZynSignLibrary", isDirectory: true)
            .appendingPathComponent("IdentityAnnotations.json", isDirectory: false)
    }

    /// The on-disk location of the signing preset catalog. Lives under
    /// Application Support so it is not part of any iCloud or iTunes
    /// backup.
    static func signingPresetCatalogLocation() -> URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ZynSignLibrary", isDirectory: true)
            .appendingPathComponent("SigningPresets.json", isDirectory: false)
    }

    /// The on-disk location of the signing history journal.
    static func signingHistoryJournalLocation() -> URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ZynSignLibrary", isDirectory: true)
            .appendingPathComponent("SigningHistory.json", isDirectory: false)
    }

    /// The on-disk location of the export catalog. It lives beside the
    /// signing history, in Application Support, because it is likewise a
    /// record of what ZynSign did rather than a file the user works with.
    static func exportCatalogLocation() -> URL {
        libraryRootDirectory.appendingPathComponent("Exports.json", isDirectory: false)
    }

    /// The directory exported artifacts are kept in: the application's own
    /// Documents folder, so a signed container is visible in the Files app
    /// and can be moved out by hand. Nothing else writes here.
    static func exportArtifactDirectory() -> URL {
        documentsDirectory.appendingPathComponent("Signed", isDirectory: true)
    }

    /// The root every signing operation's working directory is created under.
    /// The system may reclaim the temporary directory, which is exactly the
    /// durability a working copy deserves.
    static func signingWorkspaceRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignWork", isDirectory: true)
    }

    /// Every directory whose contents are temporary: package staging for
    /// import, and the working copies signing operations are made from.
    /// Cleanup and storage reporting both read this list, so the two can
    /// never disagree about what "temporary" covers.
    static func temporaryDirectories(preferences: ZynSignPreferences = ZynSignPreferences.shippedDefault) -> [URL] {
        [
            importStagingDirectory(preferences: preferences),
            signingWorkspaceRoot()
        ]
    }

    /// The user's Documents folder, where exported artifacts live.
    static var documentsDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
    }

    /// The on-disk location of the provisioning profile library catalog.
    static func provisioningProfileCatalogLocation() -> URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ZynSignLibrary", isDirectory: true)
            .appendingPathComponent("ProvisioningProfiles.json", isDirectory: false)
    }

    /// The application-owned temporary directory user-selected packages are
    /// staged into. The directory is created on first use by the intake;
    /// nothing is created at composition time.
    ///
    /// Which directory that is comes from the user's working-directory
    /// preference: the system temporary directory by default, or a durable
    /// workspace under Application Support. The choice is read once, because
    /// the intake owns the staging location for the whole launch — and the
    /// storage screen is given the same list, so what it measures is what the
    /// choice actually covers.
    static func importStagingDirectory(preferences: ZynSignPreferences) -> URL {
        switch preferences.advanced.workingDirectoryBehavior {
        case .temporary:
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ZynSignImports", isDirectory: true)
        case .applicationSupport:
            return libraryRootDirectory
                .appendingPathComponent("Workspace", isDirectory: true)
        }
    }

    /// The on-disk location of the preferences document. It lives beside the
    /// other library records because it is configuration about ZynSign's own
    /// behaviour rather than a file the user works with, and because a
    /// preferences document that cannot be read must not be able to stop the
    /// application launching.
    static func preferencesDocumentLocation() -> URL {
        libraryRootDirectory.appendingPathComponent("Preferences.json", isDirectory: false)
    }

    /// The on-disk location of the opt-in technical log. Same directory, same
    /// reasoning: it is a record of what ZynSign did, kept on the device.
    static func diagnosticsLogLocation() -> URL {
        libraryRootDirectory.appendingPathComponent("Diagnostics.json", isDirectory: false)
    }

    /// The directory a diagnostic report is written to before the user shares
    /// it. The user's Documents folder, because a report the user is asked to
    /// share should be somewhere they can see.
    static func diagnosticReportDirectory() -> URL {
        documentsDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// The application-owned temporary inbox dropped files are copied into
    /// while a drop is handled. Created on first use; swept at launch.
    static var importDropInboxDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignDropInbox", isDirectory: true)
    }

    /// The root of durable library storage, inside the application
    /// container's Application Support directory: a location the system
    /// does not purge, private to the application, and covered by the
    /// container's default file protection.
    static var libraryRootDirectory: URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("ZynSignLibrary", isDirectory: true)
    }

    /// The catalog file holding every library record.
    static var libraryCatalogLocation: URL {
        libraryRootDirectory.appendingPathComponent("catalog.json", isDirectory: false)
    }

    /// The directory adopted artifacts are kept in, named by identifier.
    static var libraryArtifactDirectory: URL {
        libraryRootDirectory.appendingPathComponent("Artifacts", isDirectory: true)
    }

    /// The document holding the library's collections and usage.
    static var downloadCenterRoot: URL {
        libraryRootDirectory.appendingPathComponent("DownloadCenter", isDirectory: true)
    }

    static var repositorySourceStoreURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent("ZynSignSources.json")
    }

    static var libraryOrganizationLocation: URL {
        libraryRootDirectory.appendingPathComponent("Organization.json", isDirectory: false)
    }

    /// The system caches directory, for values derived from library data.
    static var cachesDirectory: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Caches", isDirectory: true)
    }
}
