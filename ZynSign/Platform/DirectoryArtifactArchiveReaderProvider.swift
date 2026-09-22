import Foundation

/// An `ArtifactArchiveReaderProvider` that finds each artifact's archive in a
/// directory the platform layer supplies.
///
/// This is the concrete selection the composition root makes for the archive
/// boundary: imported packages are ZIP containers, so the reader produced here
/// is a `ZipArchiveReader`. Replacing the container engine, the storage
/// convention, or both means replacing this type; no application use case
/// changes.
///
/// The provider reads nothing and writes nothing. It resolves a location and
/// hands back an unopened reader, so asking for access to an artifact costs a
/// single file-existence check.
struct DirectoryArtifactArchiveReaderProvider: ArtifactArchiveReaderProvider {

    /// The directory holding imported archives.
    let directory: URL

    /// The file extension each archive carries.
    let fileExtension: String

    /// The resource policy handed to each reader.
    let limits: ArchiveLimits

    /// Creates a provider over `directory`.
    init(
        directory: URL,
        fileExtension: String = "ipa",
        limits: ArchiveLimits = .default
    ) {
        self.directory = directory
        self.fileExtension = fileExtension
        self.limits = limits
    }

    func archiveReader(for artifact: ArtifactIdentifier) throws -> any ArchiveReader {
        let location = location(for: artifact)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ZynSignError.artifactNotAvailable(
                diagnosticDetail: "No archive is held for artifact '\(artifact.rawValue)'."
            )
        }
        return ZipArchiveReader(location: location, limits: limits)
    }

    /// Resolves where an artifact's archive is kept.
    ///
    /// The file name is the artifact's own identifier — an opaque, freshly
    /// minted value ZynSign generates and never derives from package content.
    /// No part of an imported package's metadata contributes to the name, so a
    /// package cannot influence where its archive is looked for.
    private func location(for artifact: ArtifactIdentifier) -> URL {
        directory
            .appendingPathComponent(artifact.rawValue, isDirectory: false)
            .appendingPathExtension(fileExtension)
    }
}
