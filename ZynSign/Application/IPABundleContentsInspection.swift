import Foundation

/// The bundle contents inspection use case: it describes the structure of a
/// library application's bundle for the explorer.
///
/// The library keeps each application as the package it was imported from,
/// so the application bundle lives inside that container and is reached
/// through the same archive boundary import uses. This use case looks the
/// record up, confirms that the library still holds the package the record
/// vouches for, opens the package through the `ArtifactArchiveReaderProvider`
/// the composition root selected, reads its entry table, and hands the
/// table to the domain, which derives the bundle's structure from it.
///
/// Three properties are deliberate.
///
/// **It reads structure only.** The entry table is metadata the container
/// keeps about its entries — names, kinds, declared sizes. No entry's
/// content is read, nothing is extracted to any filesystem, nothing is
/// hashed, and no file inside the bundle is parsed. Enumerating a bundle
/// whose files are large costs no more than enumerating one whose files are
/// small.
///
/// **It changes nothing.** The package, the record, and the library are read
/// and left as they were. There is no path through this type that writes.
///
/// **It concludes nothing.** The result is a description of what the package
/// records inside the bundle. It is not a verdict on the application's
/// signature, provenance, trust, or installability, and later stages must
/// not treat it as one.
///
/// Errors are typed. A record that is gone, a package the library no longer
/// holds, a package that has changed since import, a container that cannot
/// be read, and a container with no single application bundle each reach
/// the caller as a distinct `ZynSignError`; anything else is normalised into
/// one so that no platform error text reaches the presentation layer.
struct IPABundleContentsInspection {

    private let library: ApplicationLibrary
    private let readerProvider: any ArtifactArchiveReaderProvider

    /// Creates the use case over the library and the archive boundary the
    /// composition root selected.
    init(library: ApplicationLibrary, readerProvider: any ArtifactArchiveReaderProvider) {
        self.library = library
        self.readerProvider = readerProvider
    }

    /// Describes the bundle of the application recorded under `id`.
    ///
    /// The reader is closed on every path, including failure. Cancellation
    /// is honoured before the library is consulted and again before the
    /// table is interpreted; nothing here needs to run to completion,
    /// because nothing here changes state.
    func inspect(recordWithID id: ApplicationRecordIdentifier) async throws -> BundleContents {
        do {
            try Task.checkCancellation()

            guard let entry = try await library.entry(withID: id) else {
                throw ZynSignError.libraryRecordNotFound(
                    diagnosticDetail: "No record '\(id.rawValue)' exists to inspect."
                )
            }
            switch entry.artifactAvailability {
            case .available:
                break
            case .missing:
                throw ZynSignError.bundleArtifactMissing(
                    diagnosticDetail: "The library holds no artifact '\(entry.record.artifact.artifactID.rawValue)' for record '\(id.rawValue)'."
                )
            case .inconsistent(let recorded, let observed):
                throw ZynSignError.bundleArtifactInconsistent(
                    diagnosticDetail: "Artifact '\(entry.record.artifact.artifactID.rawValue)' holds \(observed) bytes; record '\(id.rawValue)' expects \(recorded)."
                )
            }

            let record = entry.record
            let reader = try readerProvider.archiveReader(for: record.artifact.artifactID)
            defer { reader.close() }

            let entryTable = try reader.readEntryTable()
            try Task.checkCancellation()

            switch ApplicationBundleDiscovery.discover(in: entryTable).outcome {
            case .exactlyOne(let bundlePath):
                return BundleContents(
                    entryTable: entryTable,
                    bundlePath: bundlePath,
                    declaredExecutableName: record.executableName
                )
            case .ambiguous(let candidates):
                throw ZynSignError.ambiguousArtifact(
                    diagnosticDetail: "The package for record '\(id.rawValue)' holds \(candidates.count) application bundles in its payload directory."
                )
            case .missingPayloadDirectory, .none:
                throw ZynSignError.missingApplicationBundle(
                    diagnosticDetail: "The package for record '\(id.rawValue)' holds no application bundle in its payload directory."
                )
            }
        } catch {
            throw Self.normalized(error)
        }
    }

    /// Passes ZynSign's own errors and cancellation through unchanged and
    /// wraps anything else, so that callers never see a foreign error and
    /// no platform error text is presented as a fact about the package.
    private static func normalized(_ error: any Error) -> any Error {
        if error is ZynSignError || error is CancellationError {
            return error
        }
        return ZynSignError.bundleInspectionFailure(
            diagnosticDetail: "Bundle inspection failed with \(String(describing: type(of: error))).",
            underlyingError: error
        )
    }
}
