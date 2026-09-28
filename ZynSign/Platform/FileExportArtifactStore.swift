import CryptoKit
import Foundation

/// The platform implementation of `ExportArtifactStore`: the signed
/// containers ZynSign produced, kept under predictable names in one directory
/// of the application's own Documents folder.
///
/// The directory is the one a user can see in the Files app — ZynSign is
/// configured to share its Documents folder — which is deliberate: the signed
/// artifacts are the product of the application, and a person who wants to
/// move one out by hand can. Everything this type does stays inside that
/// directory, and nothing it does can reach library storage, the intake's
/// staging directory, or any other location.
///
/// - **Naming** is the naming policy's: an artifact is written under the name
///   the caller chose from the names this directory already holds, and only a
///   safe single path component with the package extension is accepted as a
///   name. A record's stored name is data, never a path.
/// - **Measuring** streams the staged container once in bounded chunks,
///   counting bytes and feeding a SHA-256 digest. The whole file is never
///   held in memory, and the fingerprint identifies bytes and nothing else.
/// - **Committing** renames the staged container into this directory. Within
///   the container the two locations share a volume, so the move is a rename
///   that either happens or does not; a destination that already exists is
///   refused rather than overwritten, whatever produced it.
/// - **Observing** reads file attributes only. It never creates, repairs, or
///   replaces a file.
/// - **Removing** deletes one file, is idempotent, and reports the bytes it
///   freed.
///
/// The directory is created on first commit; nothing is created at
/// construction time. The type holds no mutable state and is safe to share.
final class FileExportArtifactStore: ExportArtifactStore, Sendable {

    /// The directory exported artifacts are kept in.
    let exportsDirectory: URL

    /// The extension an exported artifact carries.
    let fileExtension: String

    /// How many bytes one read step moves while measuring an artifact.
    let readChunkSize: Int

    /// Creates a store over `exportsDirectory`, which need not exist yet.
    init(
        exportsDirectory: URL,
        fileExtension: String = "ipa",
        readChunkSize: Int = 1_048_576
    ) {
        self.exportsDirectory = exportsDirectory
        self.fileExtension = fileExtension
        self.readChunkSize = max(1, readChunkSize)
    }

    // MARK: - ExportArtifactStore

    func heldFileNames() throws -> Set<String> {
        guard let contents = try? Self.directoryContents(of: exportsDirectory) else { return [] }
        var held: Set<String> = []
        for item in contents {
            let name = item.lastPathComponent
            guard Self.isSafeFileName(name, fileExtension: fileExtension), Self.isRegularFile(at: item) else {
                continue
            }
            held.insert(name)
        }
        return held
    }

    func artifactLocation(forFileName fileName: String) throws -> URL {
        guard Self.isSafeFileName(fileName, fileExtension: fileExtension) else {
            throw ZynSignError.exportArtifactUnavailable(
                diagnosticDetail: "A stored export name was not a safe file name, so no location was resolved for it."
            )
        }
        return exportsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    func measure(_ location: URL) throws -> StagedExportMeasurement {
        guard Self.isRegularFile(at: location) else {
            throw ZynSignError.exportArtifactUnavailable(
                diagnosticDetail: "The staged container could not be measured because no regular file is held at its location."
            )
        }
        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: location)
        } catch {
            throw ZynSignError.exportStorageFailure(
                diagnosticDetail: "The staged container could not be opened for measurement.",
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
            throw ZynSignError.exportStorageFailure(
                diagnosticDetail: "The staged container could not be read while being measured.",
                underlyingError: error
            )
        }
        guard let fingerprint = ArtifactFingerprint(algorithm: .sha256, digestBytes: Array(hasher.finalize())) else {
            throw ZynSignError.exportStorageFailure(
                diagnosticDetail: "The digest computed for the staged container had an unexpected length."
            )
        }
        return StagedExportMeasurement(byteCount: byteCount, fingerprint: fingerprint)
    }

    @discardableResult
    func commit(_ location: URL, as fileName: String) throws -> URL {
        let destination = try artifactLocation(forFileName: fileName)
        guard Self.isRegularFile(at: location) else {
            throw ZynSignError.exportArtifactUnavailable(
                diagnosticDetail: "There is no staged container to commit."
            )
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ZynSignError.exportArtifactConflict(
                diagnosticDetail: "Export storage already holds a file named '\(fileName)'; it was not overwritten."
            )
        }
        do {
            try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        } catch {
            throw ZynSignError.exportStorageFailure(
                diagnosticDetail: "The export directory could not be created.",
                underlyingError: error
            )
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            throw ZynSignError.exportStorageFailure(
                diagnosticDetail: "The signed container could not be moved into export storage.",
                underlyingError: error
            )
        }
        return destination
    }

    func observeArtifact(named fileName: String) -> StoredExportObservation {
        guard let location = try? artifactLocation(forFileName: fileName) else { return .absent }
        guard let values = try? location.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return .absent
        }
        return .present(byteCount: max(0, values.fileSize ?? 0))
    }

    @discardableResult
    func removeArtifact(named fileName: String) throws -> Int {
        let location = try artifactLocation(forFileName: fileName)
        guard let values = try? location.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return 0
        }
        let byteCount = max(0, values.fileSize ?? 0)
        do {
            try FileManager.default.removeItem(at: location)
        } catch {
            throw ZynSignError.exportStorageFailure(
                diagnosticDetail: "The exported artifact could not be removed from export storage.",
                underlyingError: error
            )
        }
        return byteCount
    }

    // MARK: - Names

    /// Whether `name` is a name this store may hold: a single path component,
    /// not empty, not a traversal, and carrying the package extension.
    ///
    /// The rule is deliberately about shape rather than about the naming
    /// policy's output: a user who placed a package in the shared Documents
    /// folder from the Files app is a file this store must still be able to
    /// see — and avoid overwriting — but the naming policy is what decides
    /// what ZynSign itself writes.
    static func isSafeFileName(_ name: String, fileExtension: String = "ipa") -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        guard !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { return false }
        guard !name.hasPrefix(".") else { return false }
        guard !name.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        guard name.contains(".") else { return false }
        return (name as NSString).pathExtension.lowercased() == fileExtension.lowercased()
    }

    // MARK: - File system

    private static func isRegularFile(at location: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func directoryContents(of directory: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw ZynSignError.exportStorageFailure(
                diagnosticDetail: "The export directory could not be listed.",
                underlyingError: error
            )
        }
    }
}
