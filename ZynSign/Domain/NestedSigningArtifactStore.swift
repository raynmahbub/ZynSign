import Foundation

/// The boundary through which nested code signing reads and updates binary artifacts.
///
/// Hides filesystem and storage specifics behind bundle-relative `BundlePath` operations.
/// All reads and writes are bounded to the controlled artifact area; no arbitrary traversal,
/// symlink escape, or absolute paths are permitted.
protocol NestedSigningArtifactStore: AnyObject {

    /// Reads binary bytes at a bundle-relative path.
    func readBinary(at path: BundlePath) throws -> Data

    /// Writes binary bytes at a bundle-relative path.
    func writeBinary(_ bytes: Data, at path: BundlePath) throws
}

// MARK: - In-Memory Implementation

/// An in-memory artifact store for deterministic testing and staged operations.
final class MemoryNestedSigningArtifactStore: NestedSigningArtifactStore {

    /// The current binaries held in memory, keyed by bundle path.
    var binaries: [BundlePath: Data]

    /// Tracks which binaries have been written to during execution.
    private(set) var writtenBinaries: [BundlePath: Data] = [:]

    /// Tracks read call counts for verification.
    private(set) var readCounts: [BundlePath: Int] = [:]

    /// Optional simulated read failure for failure handling tests.
    var simulatedReadError: (any Error)?

    /// Optional simulated write failure for failure handling tests.
    var simulatedWriteError: (any Error)?

    init(binaries: [BundlePath: Data] = [:]) {
        self.binaries = binaries
    }

    func readBinary(at path: BundlePath) throws -> Data {
        readCounts[path, default: 0] += 1
        if let simulated = simulatedReadError {
            throw simulated
        }
        guard let data = binaries[path] else {
            throw NestedSigningFailure(
                reason: .artifactReadFailure,
                path: path,
                detail: "No binary found in memory store at '\(path.rawValue)'.",
                category: .storageFailure,
                mutationOccurred: false
            )
        }
        return data
    }

    func writeBinary(_ bytes: Data, at path: BundlePath) throws {
        if let simulated = simulatedWriteError {
            throw simulated
        }
        guard bytes.count <= ReadOnlyMachOParser.maximumInputBytes else {
            throw NestedSigningFailure(
                reason: .resourceLimitExceeded,
                path: path,
                detail: "Binary write exceeds maximum input limit.",
                category: .internalFailure,
                mutationOccurred: false
            )
        }
        binaries[path] = bytes
        writtenBinaries[path] = bytes
    }
}

// MARK: - File-System Implementation

/// A filesystem-backed artifact store operating strictly inside a managed bundle directory.
///
/// Defends against:
/// - Path traversal (`BundlePath` is relative and normalized by construction).
/// - Symlink escape (checks canonical path resolution).
/// - Writes outside the controlled bundle root.
/// - Incomplete writes (uses atomic writes via temporary files).
final class FileNestedSigningArtifactStore: NestedSigningArtifactStore {

    /// The root URL of the managed application bundle directory.
    let bundleURL: URL

    /// The canonical path of the bundle root for containment checks.
    private let canonicalBundlePath: String

    /// Maximum accepted binary size to defend against runaway allocations.
    let maximumBinaryBytes: Int

    init(
        bundleURL: URL,
        maximumBinaryBytes: Int = ReadOnlyMachOParser.maximumInputBytes
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.canonicalBundlePath = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        self.maximumBinaryBytes = maximumBinaryBytes
    }

    func readBinary(at path: BundlePath) throws -> Data {
        let fileURL = try resolveAndValidate(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NestedSigningFailure(
                reason: .artifactReadFailure,
                path: path,
                detail: "File at '\(path.rawValue)' does not exist.",
                category: .storageFailure,
                mutationOccurred: false
            )
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= maximumBinaryBytes else {
                throw NestedSigningFailure(
                    reason: .resourceLimitExceeded,
                    path: path,
                    detail: "File at '\(path.rawValue)' exceeds maximum binary size limit.",
                    category: .internalFailure,
                    mutationOccurred: false
                )
            }
            return data
        } catch let failure as NestedSigningFailure {
            throw failure
        } catch {
            throw NestedSigningFailure(
                reason: .artifactReadFailure,
                path: path,
                detail: "Could not read file at '\(path.rawValue)'.",
                category: .storageFailure,
                mutationOccurred: false
            )
        }
    }

    func writeBinary(_ bytes: Data, at path: BundlePath) throws {
        guard bytes.count <= maximumBinaryBytes else {
            throw NestedSigningFailure(
                reason: .resourceLimitExceeded,
                path: path,
                detail: "Output binary at '\(path.rawValue)' exceeds maximum size limit.",
                category: .internalFailure,
                mutationOccurred: false
            )
        }
        let fileURL = try resolveAndValidate(path)
        let directoryURL = fileURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw NestedSigningFailure(
                reason: .artifactWriteFailure,
                path: path,
                detail: "Failed to create directory structure for '\(path.rawValue)'.",
                category: .storageFailure,
                mutationOccurred: false
            )
        }

        // Atomic write via temporary file replacement.
        let temporaryURL = directoryURL.appendingPathComponent(".zynsign-tmp-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        do {
            try bytes.write(to: temporaryURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(
                fileURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewmetadataOnly
            )
        } catch {
            throw NestedSigningFailure(
                reason: .artifactWriteFailure,
                path: path,
                detail: "Failed to write signed binary atomically at '\(path.rawValue)'.",
                category: .storageFailure,
                mutationOccurred: false
            )
        }
    }

    /// Resolves and validates that the target path does not escape the bundle root.
    private func resolveAndValidate(_ path: BundlePath) throws -> URL {
        guard !path.isRoot else {
            throw NestedSigningFailure(
                reason: .artifactReadFailure,
                path: path,
                detail: "Cannot target the bundle root as a binary.",
                category: .invalidInput,
                mutationOccurred: false
            )
        }

        let targetURL = bundleURL.appendingPathComponent(path.rawValue).standardizedFileURL
        let canonicalTarget = targetURL.resolvingSymlinksInPath().path

        // Check symlink escape: the canonical target must be the bundle root
        // itself or lie strictly beneath it. A bare string-prefix check is
        // not enough — `/Work/App.app-evil/x` starts with `/Work/App.app`
        // without being inside it — so the boundary falls on a separator.
        let isConfined = canonicalTarget == canonicalBundlePath
            || canonicalTarget.hasPrefix(canonicalBundlePath + "/")
        guard isConfined else {
            throw NestedSigningFailure(
                reason: .invalidSigningPlan,
                path: path,
                detail: "Target path '\(path.rawValue)' escapes the bundle root via symlink or directory traversal.",
                category: .invalidInput,
                mutationOccurred: false
            )
        }

        return targetURL
    }
}
