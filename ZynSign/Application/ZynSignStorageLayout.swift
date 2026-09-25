import Foundation

/// Every location ZynSign owns, named in one place.
///
/// ZynSign keeps all of its durable files inside the application container,
/// and all of its scratch files inside the directories the system designates
/// for them. Naming those locations here — rather than at each call site —
/// is what lets the Storage Manager report what is actually on disk, lets the
/// cleanup actions act on exactly what they say they act on, and keeps the
/// composition root and the Settings area from disagreeing about where
/// something lives.
///
/// Nothing here creates anything: locations are resolved, and the stores that
/// own them create their directories on first use. No location is shared with
/// another application, and none is part of an iCloud or iTunes backup unless
/// the system puts it there.
enum ZynSignStorageLayout {

    // MARK: - Names

    /// The root of durable library storage, inside Application Support.
    static let libraryDirectoryName = "ZynSignLibrary"

    /// The directory adopted artifacts are kept in, named by identifier.
    static let artifactsDirectoryName = "Artifacts"

    /// The catalog holding every library record.
    static let catalogFileName = "catalog.json"

    /// The catalog of saved signing presets.
    static let signingPresetsFileName = "SigningPresets.json"

    /// The journal of past signing runs.
    static let signingHistoryFileName = "SigningHistory.json"

    /// The catalog of imported provisioning profiles.
    static let provisioningProfilesFileName = "ProvisioningProfiles.json"

    /// The user's preferences document.
    static let preferencesFileName = "Preferences.json"

    /// The opt-in technical log.
    static let diagnosticsFileName = "Diagnostics.json"

    /// The directory signed packages are written to, inside Documents.
    static let signedDirectoryName = "Signed"

    /// The staging directory user-selected packages are copied into.
    static let importStagingDirectoryName = "ZynSignImports"

    /// The directory exported reports and certificates are written to.
    static let exportDirectoryName = "ZynSign-Export"

    /// The directory extracted application icons are cached in.
    static let iconCacheDirectoryName = "ZynSignAppIcons"

    /// The prefix every ZynSign-owned temporary entry carries.
    ///
    /// The temporary and caches directories are shared with the system, so
    /// both measurement and cleanup are restricted to entries ZynSign itself
    /// created. Nothing outside this prefix is ever measured or removed.
    static let temporaryEntryPrefix = "zynsign"

    /// The durable workspace under Application Support, when the user's
    /// working-directory preference asks for one.
    static let workspaceDirectoryName = "Workspace"

    // MARK: - Standard directories

    /// The application's Application Support directory, with the documented
    /// fallback when the system cannot name one.
    static func applicationSupport(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// The application's Documents directory, with the documented fallback.
    static func documents(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
    }

    /// The system temporary directory.
    static func temporary(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
    }

    /// The system caches directory, with the documented fallback.
    static func caches(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
    }

    // MARK: - Library locations

    /// The root of durable library storage.
    static func libraryRoot(fileManager: FileManager = .default) -> URL {
        applicationSupport(fileManager: fileManager)
            .appendingPathComponent(libraryDirectoryName, isDirectory: true)
    }

    /// The directory adopted artifacts are kept in.
    static func artifactsDirectory(fileManager: FileManager = .default) -> URL {
        libraryRoot(fileManager: fileManager)
            .appendingPathComponent(artifactsDirectoryName, isDirectory: true)
    }

    /// The catalog file holding every library record.
    static func libraryCatalog(fileManager: FileManager = .default) -> URL {
        libraryRoot(fileManager: fileManager).appendingPathComponent(catalogFileName, isDirectory: false)
    }

    /// The signing preset catalog.
    static func signingPresetsCatalog(fileManager: FileManager = .default) -> URL {
        libraryRoot(fileManager: fileManager).appendingPathComponent(signingPresetsFileName, isDirectory: false)
    }

    /// The signing history journal.
    static func signingHistoryJournal(fileManager: FileManager = .default) -> URL {
        libraryRoot(fileManager: fileManager).appendingPathComponent(signingHistoryFileName, isDirectory: false)
    }

    /// The provisioning profile catalog.
    static func provisioningProfilesCatalog(fileManager: FileManager = .default) -> URL {
        libraryRoot(fileManager: fileManager).appendingPathComponent(provisioningProfilesFileName, isDirectory: false)
    }

    /// The user's preferences document.
    static func preferencesDocument(fileManager: FileManager = .default) -> URL {
        libraryRoot(fileManager: fileManager).appendingPathComponent(preferencesFileName, isDirectory: false)
    }

    /// The opt-in technical log.
    static func diagnosticsLog(fileManager: FileManager = .default) -> URL {
        libraryRoot(fileManager: fileManager).appendingPathComponent(diagnosticsFileName, isDirectory: false)
    }

    /// The on-device activity journal.
    static func analyticsJournal(fileManager: FileManager = .default) -> URL {
        applicationSupport(fileManager: fileManager)
            .appendingPathComponent("ZynSignAnalytics", isDirectory: true)
            .appendingPathComponent("events.jsonl", isDirectory: false)
    }

    // MARK: - Working locations

    /// The directory signed packages are written to.
    static func signedArtifactsDirectory(fileManager: FileManager = .default) -> URL {
        documents(fileManager: fileManager).appendingPathComponent(signedDirectoryName, isDirectory: true)
    }

    /// The staging directory user-selected packages are copied into.
    static func importStagingDirectory(fileManager: FileManager = .default) -> URL {
        temporary(fileManager: fileManager).appendingPathComponent(importStagingDirectoryName, isDirectory: true)
    }

    /// The staging directory the user's working-directory preference names.
    ///
    /// One definition, so the composition root that builds the intake and the
    /// Advanced settings row that describes it can never disagree about where
    /// staging happens.
    static func importStagingDirectory(
        preferences: ZynSignPreferences,
        fileManager: FileManager = .default
    ) -> URL {
        switch preferences.advanced.workingDirectoryBehavior {
        case .temporary:
            return importStagingDirectory(fileManager: fileManager)
        case .applicationSupport:
            return libraryRoot(fileManager: fileManager)
                .appendingPathComponent(workspaceDirectoryName, isDirectory: true)
        }
    }

    /// The directory exported reports and certificates are written to.
    static func exportDirectory(fileManager: FileManager = .default) -> URL {
        temporary(fileManager: fileManager).appendingPathComponent(exportDirectoryName, isDirectory: true)
    }

    /// The directory extracted application icons are cached in.
    static func iconCacheDirectory(fileManager: FileManager = .default) -> URL {
        caches(fileManager: fileManager).appendingPathComponent(iconCacheDirectoryName, isDirectory: true)
    }

    /// Whether `name` names an entry ZynSign itself created.
    ///
    /// Measurement and cleanup in shared directories — the temporary
    /// directory and the caches directory — are restricted by this test, so
    /// neither can ever touch another application's files or the system's.
    static func isZynSignOwnedEntry(_ name: String) -> Bool {
        name.lowercased().hasPrefix(temporaryEntryPrefix)
    }
}
