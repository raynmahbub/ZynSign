import CryptoKit
import Foundation

/// The platform implementation of `LibraryArtifactStore`: durable,
/// application-owned artifact storage fed from the import staging directory.
///
/// This type owns the bytes behind library records. It knows two
/// directories — the staging directory the intake copies selected documents
/// into, and the library directory adopted artifacts live in — and the one
/// file-name convention both share: the artifact's identifier plus the
/// package extension. The composition root binds this type, the intake, and
/// the archive-reader provider to the same directories and the same
/// convention, so an artifact is discoverable by identifier alone and no
/// domain or application type sees a URL.
///
/// Every file name is an identifier ZynSign minted: no part of a selected
/// document's name or content reaches the file system through this type, so
/// a package cannot influence where its bytes are kept.
///
/// - **Describing** streams the staged archive once in bounded chunks,
///   counting bytes and feeding a SHA-256 digest. The whole file is never
///   held in memory. The resulting fingerprint identifies bytes and nothing
///   else — it is not a signature and confers no trust.
/// - **Adopting** renames the staged archive into the library directory.
///   Within the application container the two directories share a volume,
///   so the move is a rename that either happens or does not; a destination
///   that already exists is refused rather than overwritten.
/// - **Observing** reads file attributes only. It never creates, repairs, or
///   replaces a file.
/// - **Removing** deletes the artifact's file if present.
/// - **Enumerating** lists the library directory and reports only files
///   whose names are valid identifiers with the package extension; anything
///   else in the directory is ignored rather than treated as an artifact.
///
/// The library directory is created on first adoption; nothing is created at
/// construction time. The type holds no mutable state and is safe to share.
final class FileLibraryArtifactStore: LibraryArtifactStore, Sendable {

    /// The directory the intake stages selected documents into.
    let stagingDirectory: URL

    /// The application-owned directory adopted artifacts are kept in.
    let libraryDirectory: URL

    /// The file extension a staged or adopted archive carries.
    let fileExtension: String

    /// How many bytes one read step moves while describing an archive.
    let readChunkSize: Int

    /// Creates a store over the two directories, neither of which need
    /// exist yet.
    init(
        stagingDirectory: URL,
        libraryDirectory: URL,
        fileExtension: String = "ipa",
        readChunkSize: Int = 1_048_576
    ) {
        self.stagingDirectory = stagingDirectory
        self.libraryDirectory = libraryDirectory
        self.fileExtension = fileExtension
        self.readChunkSize = max(1, readChunkSize)
    }

    // MARK: - LibraryArtifactStore

    func describeStagedArtifact(_ artifact: ArtifactIdentifier) throws -> ArtifactReference {
        let source = stagedLocation(for: artifact)
        guard Self.isRegularFile(at: source) else {
            throw ZynSignError.artifactNotAvailable(
                diagnosticDetail: "No staged archive is held for artifact '\(artifact.rawValue)'."
            )
        }
        let (byteCount, fingerprint) = try measure(source, artifact: artifact)
        return ArtifactReference(artifactID: artifact, byteCount: byteCount, fingerprint: fingerprint)
    }

    func adoptStagedArtifact(_ artifact: ArtifactIdentifier) throws {
        let source = stagedLocation(for: artifact)
        let destination = libraryLocation(for: artifact)
        guard Self.isRegularFile(at: source) else {
            throw ZynSignError.artifactNotAvailable(
                diagnosticDetail: "No staged archive is held for artifact '\(artifact.rawValue)', so there is nothing to adopt."
            )
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "Library storage already holds an artifact under identifier '\(artifact.rawValue)'; it will not be overwritten."
            )
        }
        do {
            try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        } catch {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "The library artifact directory could not be created.",
                underlyingError: error
            )
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "The staged archive for artifact '\(artifact.rawValue)' could not be moved into library storage.",
                underlyingError: error
            )
        }
    }

    func removeArtifact(_ artifact: ArtifactIdentifier) throws {
        let location = libraryLocation(for: artifact)
        guard FileManager.default.fileExists(atPath: location.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: location)
        } catch {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "The artifact '\(artifact.rawValue)' could not be removed from library storage.",
                underlyingError: error
            )
        }
    }

    func observeArtifact(_ artifact: ArtifactIdentifier) -> StoredArtifactObservation {
        let location = libraryLocation(for: artifact)
        guard let values = try? location.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return .absent
        }
        return .present(byteCount: max(0, values.fileSize ?? 0))
    }

    func heldArtifactIdentifiers() throws -> Set<ArtifactIdentifier> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: libraryDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: libraryDirectory,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "The library artifact directory could not be listed.",
                underlyingError: error
            )
        }
        var held: Set<ArtifactIdentifier> = []
        for item in contents where item.pathExtension.lowercased() == fileExtension.lowercased() {
            let stem = item.deletingPathExtension().lastPathComponent
            guard let identifier = ArtifactIdentifier(rawValue: stem), Self.isRegularFile(at: item) else {
                continue
            }
            held.insert(identifier)
        }
        return held
    }

    // MARK: - Measuring

    /// Streams the file at `source`, returning its byte count and SHA-256
    /// fingerprint. Read failures are mapped onto typed errors whose
    /// rendering carries the identifier only.
    private func measure(_ source: URL, artifact: ArtifactIdentifier) throws -> (Int, ArtifactFingerprint) {
        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: source)
        } catch {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "The staged archive for artifact '\(artifact.rawValue)' could not be opened for reading.",
                underlyingError: error
            )
        }
        defer { try? reader.close() }

        var hasher = SHA256()
        var byteCount = 0
        do {
            while true {
                guard let chunk = try reader.read(upToCount: readChunkSize), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                byteCount += chunk.count
            }
        } catch {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "The staged archive for artifact '\(artifact.rawValue)' could not be read.",
                underlyingError: error
            )
        }

        let digest = Array(hasher.finalize())
        guard let fingerprint = ArtifactFingerprint(algorithm: .sha256, digestBytes: digest) else {
            throw ZynSignError.libraryStorageFailure(
                diagnosticDetail: "The digest computed for artifact '\(artifact.rawValue)' had an unexpected length."
            )
        }
        return (byteCount, fingerprint)
    }

    // MARK: - Locations

    private static func isRegularFile(at location: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Where the intake keeps a staged archive: the same convention as
    /// `SecurityScopedArtifactIntake`, bound together by the composition
    /// root.
    private func stagedLocation(for artifact: ArtifactIdentifier) -> URL {
        stagingDirectory
            .appendingPathComponent(artifact.rawValue, isDirectory: false)
            .appendingPathExtension(fileExtension)
    }

    /// Where an adopted artifact is kept: the same convention, in the
    /// library directory, which is also where the archive-reader provider
    /// looks first.
    private func libraryLocation(for artifact: ArtifactIdentifier) -> URL {
        libraryDirectory
            .appendingPathComponent(artifact.rawValue, isDirectory: false)
            .appendingPathExtension(fileExtension)
    }
}
