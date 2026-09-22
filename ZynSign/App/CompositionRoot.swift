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

    /// Builds the application environment for a fresh launch.
    ///
    /// One library use case is constructed per launch and shared by the
    /// import use case, the bundle inspection use case, and the environment,
    /// so the Import area and the Applications area act on the same records
    /// and the same storage wherever they admit, list, inspect, or remove
    /// entries.
    static func makeApplicationEnvironment() -> ApplicationEnvironment {
        let intake = SecurityScopedArtifactIntake(directory: importStagingDirectory)
        let library = makeApplicationLibrary(intake: intake)
        return ApplicationEnvironment(
            applicationInfo: ApplicationInfo.current(bundle: .main),
            packageImport: makePackageImport(intake: intake, library: library),
            library: library,
            bundleInspection: makeBundleContentsInspection(intake: intake, library: library)
        )
    }

    /// Builds the package inspection use case, selecting the concrete archive
    /// implementation.
    ///
    /// The selected implementation reads ZIP containers from `artifactDirectory`
    /// and applies the default resource policy. Nothing else in the application
    /// knows which implementation was chosen: the use case depends only on the
    /// archive ports, so a different container engine or storage convention can
    /// be substituted here alone.
    ///
    /// The directory is supplied by the caller rather than created here.
    /// Inspection neither extracts a package nor writes into the directory; it
    /// reads the entry table of the archive the directory holds.
    static func makeArchiveInspection(
        artifactDirectory: URL,
        limits: ArchiveLimits = .default
    ) -> IPAArchiveInspection {
        IPAArchiveInspection(
            readerProvider: DirectoryArtifactArchiveReaderProvider(
                directory: artifactDirectory,
                limits: limits
            ),
            limits: limits
        )
    }

    /// Builds the bundle metadata inspection use case, selecting the
    /// concrete archive implementation.
    ///
    /// It reads the bundle's information file from the same storage
    /// convention as structural inspection and applies the same resource
    /// policy, so the two halves of the inspection stage stay consistent
    /// when the composition root is the only place that changes them.
    static func makeBundleMetadataInspection(
        artifactDirectory: URL,
        limits: ArchiveLimits = .default
    ) -> IPABundleMetadataInspection {
        IPABundleMetadataInspection(
            readerProvider: DirectoryArtifactArchiveReaderProvider(
                directory: artifactDirectory,
                limits: limits
            ),
            limits: limits
        )
    }

    /// Builds the package import use case over the given intake and library,
    /// selecting the concrete archive implementation.
    ///
    /// The library is the one the environment carries, so packages an import
    /// admits are the records the Applications area lists and removes. The
    /// archive boundary searches library storage first and staging second,
    /// so an artifact is readable by identifier both while it is being
    /// examined and after it has been recorded. Everything is bound to the
    /// same directories and the same file-extension convention here, and no
    /// other type knows the locations. The default resource policy applies
    /// to every archive.
    static func makePackageImport(
        intake: SecurityScopedArtifactIntake,
        library: ApplicationLibrary,
        limits: ArchiveLimits = .default
    ) -> IPAPackageImport {
        let readerProvider = DirectoryArtifactArchiveReaderProvider(
            directories: [libraryArtifactDirectory, intake.directory],
            fileExtension: intake.fileExtension,
            limits: limits
        )
        return IPAPackageImport(
            intake: intake,
            readerProvider: readerProvider,
            library: library,
            limits: limits
        )
    }

    /// Builds the bundle contents inspection use case over the given library,
    /// selecting the concrete archive implementation.
    ///
    /// The explorer describes applications the library holds, so its archive
    /// boundary reads library storage only, under the same file-extension
    /// convention and the same resource policy as import. It is the same
    /// reader implementation import uses, chosen here and nowhere below;
    /// inspection reads a package's entry table and never writes.
    static func makeBundleContentsInspection(
        intake: SecurityScopedArtifactIntake,
        library: ApplicationLibrary,
        limits: ArchiveLimits = .default
    ) -> IPABundleContentsInspection {
        IPABundleContentsInspection(
            library: library,
            readerProvider: DirectoryArtifactArchiveReaderProvider(
                directory: libraryArtifactDirectory,
                fileExtension: intake.fileExtension,
                limits: limits
            )
        )
    }

    /// Builds the library use case over the selected persistence
    /// implementations: a versioned catalog file for records, and
    /// application-owned artifact storage fed from the intake's staging
    /// directory for the bytes behind them. Nothing is created on disk at
    /// composition time; both stores create their directories on first use.
    private static func makeApplicationLibrary(intake: SecurityScopedArtifactIntake) -> ApplicationLibrary {
        ApplicationLibrary(
            records: FileApplicationRecordStore(catalogLocation: libraryCatalogLocation),
            artifacts: FileLibraryArtifactStore(
                stagingDirectory: intake.directory,
                libraryDirectory: libraryArtifactDirectory,
                fileExtension: intake.fileExtension
            )
        )
    }

    /// The application-owned temporary directory user-selected packages are
    /// staged into. The directory is created on first use by the intake;
    /// nothing is created at composition time.
    private static var importStagingDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignImports", isDirectory: true)
    }

    /// The root of durable library storage, inside the application
    /// container's Application Support directory: a location the system
    /// does not purge, private to the application, and covered by the
    /// container's default file protection.
    private static var libraryRootDirectory: URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("ZynSignLibrary", isDirectory: true)
    }

    /// The catalog file holding every library record.
    private static var libraryCatalogLocation: URL {
        libraryRootDirectory.appendingPathComponent("catalog.json", isDirectory: false)
    }

    /// The directory adopted artifacts are kept in, named by identifier.
    private static var libraryArtifactDirectory: URL {
        libraryRootDirectory.appendingPathComponent("Artifacts", isDirectory: true)
    }
}
