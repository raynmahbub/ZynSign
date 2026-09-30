import Foundation

/// The application library and its stores.
///
/// Part of `CompositionRoot`, which chooses every concrete
/// implementation and wires the layers together. Split out of the
/// original single file for readability; the members are unchanged.
extension CompositionRoot {

    /// Wraps a library-directory reader provider in the shared entry-table
    /// cache. Only read-only inspectors of *library* packages use this;
    /// import and staging paths open their archives uncached, because a
    /// staged file is expected to change.
    static func cachingLibraryReaderProvider(
        fileExtension: String = "ipa",
        limits: ArchiveLimits = .default
    ) -> any ArtifactArchiveReaderProvider {
        CachingArtifactArchiveReaderProvider(
            underlying: DirectoryArtifactArchiveReaderProvider(
                directory: libraryArtifactDirectory,
                fileExtension: fileExtension,
                limits: limits
            ),
            entryTables: sharedEntryTables,
            stamps: FileArtifactStampProvider(directories: [libraryArtifactDirectory], fileExtension: fileExtension)
        )
    }

    /// Builds the installed-applications store at the canonical Application
    /// Support location. It announces every change it completes, so the
    /// workspace re-reads the catalog after an attempt, a confirmation, or a
    /// cleanup, whichever screen made the change.
    static func makeInstalledApplicationStore() -> any InstalledApplicationStore {
        NotifyingInstalledApplicationStore(
            wrapping: FileInstalledApplicationStore(
                catalogLocation: installedApplicationsCatalogLocation(),
                capacity: 1000
            )
        )
    }

    /// Builds the library-organization use case over a versioned document
    /// beside the library catalog, so collections and usage live with the
    /// library they describe without ever rewriting its catalog.
    static func makeLibraryOrganizer() -> LibraryOrganizer {
        LibraryOrganizer(store: FileLibraryOrganizationStore(documentLocation: libraryOrganizationLocation))
    }

    /// Builds the provenance reader over the same storage convention the
    /// library artifacts live in. Embedded profiles are decoded with the
    /// bounded CMS structure reader ZynSign's profile readers use; results are
    /// cached in the system caches directory, which the system may reclaim
    /// — the right durability for values derived from immutable bytes.
    static func makeApplicationProvenanceExtraction() -> ApplicationProvenanceExtraction {
        ApplicationProvenanceExtraction(
            readerProvider: cachingLibraryReaderProvider(),
            cacheLocation: cachesDirectory.appendingPathComponent("ZynSignProvenance.json", isDirectory: false),
            profilePayload: { data in
                (try? CMSStructureReader.read(data))?.encapsulatedContent
            }
        )
    }

    /// Builds the export preparation over the library's artifact directory,
    /// placing readable file names in a temporary directory the share sheet
    /// reads from and that is cleared after every export.
    static func makeLibraryExportPreparation() -> LibraryExportPreparation {
        let artifactDirectory = libraryArtifactDirectory
        return LibraryExportPreparation(
            exportRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("ZynSignExports", isDirectory: true),
            artifactLocation: { artifact in
                artifactDirectory
                    .appendingPathComponent(artifact.rawValue, isDirectory: false)
                    .appendingPathExtension("ipa")
            }
        )
    }

    /// Builds the library use case over the selected persistence
    /// implementations: a versioned catalog file for records, and
    /// application-owned artifact storage fed from the intake's staging
    /// directory for the bytes behind them. Nothing is created on disk at
    /// composition time; both stores create their directories on first use.
    static func makeApplicationLibrary(
        intake: SecurityScopedArtifactIntake,
        diagnosticHistory: any SigningDiagnosticsHistoryStore
    ) -> ApplicationLibrary {
        ApplicationLibrary(
            records: FileApplicationRecordStore(catalogLocation: libraryCatalogLocation),
            artifacts: FileLibraryArtifactStore(
                stagingDirectory: intake.directory,
                libraryDirectory: libraryArtifactDirectory,
                fileExtension: intake.fileExtension
            ),
            diagnosticHistory: diagnosticHistory
        )
    }
}
