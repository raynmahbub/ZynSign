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
            applicationInfo: ApplicationInfo.current(bundle: .main)
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
}
