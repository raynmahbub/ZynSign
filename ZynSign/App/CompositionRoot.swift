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
/// above all — the choice is made here, so that the layers beneath the choice
/// depend only on the port.
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
    /// ZynSign does not persist imported packages yet, and inspection neither
    /// extracts a package nor writes into the directory; it reads the entry
    /// table of the archive the directory holds. When package storage becomes a
    /// real concern, the storage decision belongs to its own task and its own
    /// documentation, not to this factory.
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

    /// Builds the package import use case, selecting the concrete intake and
    /// archive implementations.
    ///
    /// The intake copies a user-selected document into the application-owned
    /// staging directory, owning security-scoped access and cleanup; the
    /// archive boundary reads staged archives from that same directory. Both
    /// sides are bound to the same directory and the same file-extension
    /// convention here, so a staged archive is discoverable through the
    /// artifact's identifier alone and no other type knows the location.
    /// The default resource policy applies to staged archives exactly as it
    /// would to any other artifact.
    static func makePackageImport(limits: ArchiveLimits = .default) -> IPAPackageImport {
        let intake = SecurityScopedArtifactIntake(directory: importStagingDirectory)
        let readerProvider = DirectoryArtifactArchiveReaderProvider(
            directory: intake.directory,
            limits: limits
        )
        return IPAPackageImport(
            intake: intake,
            readerProvider: readerProvider,
            limits: limits
        )
    }

    /// The application-owned temporary directory user-selected packages are
    /// staged into. The directory is created on first use by the intake;
    /// nothing is created at composition time.
    private static var importStagingDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignImports", isDirectory: true)
    }
}
