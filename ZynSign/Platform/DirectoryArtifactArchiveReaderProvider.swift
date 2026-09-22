import Foundation

/// An `ArtifactArchiveReaderProvider` that finds each artifact's archive in
/// one of the directories the platform layer supplies.
///
/// This is the concrete selection the composition root makes for the archive
/// boundary: imported packages are ZIP containers, so the reader produced here
/// is a `ZipArchiveReader`. Replacing the container engine, the storage
/// convention, or both means replacing this type; no application use case
/// changes.
///
/// An artifact lives in exactly one place at a time — the import staging
/// directory until the library adopts it, the library artifact directory
/// afterwards — so the provider is given the directories in the order they
/// should be searched and resolves the first that holds a regular file for
/// the identifier. The composition root lists library storage first.
///
/// The provider reads nothing and writes nothing. It resolves a location and
/// hands back an unopened reader, so asking for access to an artifact costs
/// one file-existence check per directory searched.
struct DirectoryArtifactArchiveReaderProvider: ArtifactArchiveReaderProvider {

    /// The directories holding imported archives, in search order.
    let directories: [URL]

    /// The file extension each archive carries.
    let fileExtension: String

    /// The resource policy handed to each reader.
    let limits: ArchiveLimits

    /// Creates a provider over a single directory.
    init(
        directory: URL,
        fileExtension: String = "ipa",
        limits: ArchiveLimits = .default
    ) {
        self.init(directories: [directory], fileExtension: fileExtension, limits: limits)
    }

    /// Creates a provider that searches `directories` in order.
    init(
        directories: [URL],
        fileExtension: String = "ipa",
        limits: ArchiveLimits = .default
    ) {
        self.directories = directories
        self.fileExtension = fileExtension
        self.limits = limits
    }

    func archiveReader(for artifact: ArtifactIdentifier) throws -> any ArchiveReader {
        for directory in directories {
            let location = location(for: artifact, in: directory)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return ZipArchiveReader(location: location, limits: limits)
            }
        }
        throw ZynSignError.artifactNotAvailable(
            diagnosticDetail: "No archive is held for artifact '\(artifact.rawValue)'."
        )
    }

    /// Resolves where an artifact's archive would be kept in `directory`.
    ///
    /// The file name is the artifact's own identifier — an opaque, freshly
    /// minted value ZynSign generates and never derives from package content.
    /// No part of an imported package's metadata contributes to the name, so a
    /// package cannot influence where its archive is looked for.
    private func location(for artifact: ArtifactIdentifier, in directory: URL) -> URL {
        directory
            .appendingPathComponent(artifact.rawValue, isDirectory: false)
            .appendingPathExtension(fileExtension)
    }
}
