/// The boundary through which the application layer obtains archive access for
/// an imported artifact.
///
/// A domain artifact identifies a package; it holds no bytes, no handle, and
/// no location. Something must turn that identity into a reader, and that
/// something is platform- and storage-bound: it depends on where imported
/// packages are kept and on the container implementation chosen for them.
/// Declaring the port here — in the layer that consumes it — keeps the
/// dependency pointing inward and keeps the choice of implementation in the
/// composition root.
///
/// The port returns the narrow `ArchiveReader` boundary rather than anything
/// wider, so an application use case can never reach the storage that holds an
/// artifact, only the archive it names.
protocol ArtifactArchiveReaderProvider {

    /// Produces a reader for the archive belonging to `artifact`.
    ///
    /// Fails with a typed error when no archive is available for the
    /// identifier, or when the archive cannot be opened. Callers are
    /// responsible for closing the returned reader.
    func archiveReader(for artifact: ArtifactIdentifier) throws -> any ArchiveReader
}
