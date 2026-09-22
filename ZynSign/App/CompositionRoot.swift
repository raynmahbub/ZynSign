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
    static func makeApplicationEnvironment() -> ApplicationEnvironment {
        ApplicationEnvironment(
            applicationInfo: ApplicationInfo.current(bundle: .main),
            packageImport: makePackageImport()
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

    /// Builds the package import use case, selecting the concrete intake,
    /// archive, and persistence implementations.
    ///
    /// The intake copies a user-selected document into the application-owned
    /// staging directory, owning security-scoped access and cleanup. The
    /// library adopts accepted packages out of that directory into durable
    /// library storage and records them in the catalog. The archive boundary
    /// searches library storage first and staging second, so an artifact is
    /// readable by identifier both while it is being examined and after it
    /// has been recorded. All four are bound to the same directories and the
    /// same file-extension convention here, and no other type knows the
    /// locations. The default resource policy applies to every archive.
    static func makePackageImport(limits: ArchiveLimits = .default) -> IPAPackageImport {
        let intake = SecurityScopedArtifactIntake(directory: importStagingDirectory)
        let readerProvider = DirectoryArtifactArchiveReaderProvider(
            directories: [libraryArtifactDirectory, intake.directory],
            fileExtension: intake.fileExtension,
            limits: limits
        )
        return IPAPackageImport(
            intake: intake,
            readerProvider: readerProvider,
            library: makeApplicationLibrary(intake: intake),
            limits: limits
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
