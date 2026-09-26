import Foundation
import XCTest
@testable import ZynSign

// MARK: - Entry construction

/// Builds an `ArchiveEntry` from a literal name.
///
/// The name must satisfy ZynSign's safety rules; a name that does not is a
/// defect in the test, so the helper fails loudly rather than quietly
/// producing an entry the test did not mean to build.
func makeEntry(
    _ name: String,
    kind: ArchiveEntryKind = .regularFile,
    uncompressedSize: Int = 0,
    compressedSize: Int = 0
) -> ArchiveEntry {
    guard let path = ArchivePath(rawValue: name) else {
        preconditionFailure("Test fixture used an unsafe archive path: \(name)")
    }
    return ArchiveEntry(
        path: path,
        kind: kind,
        uncompressedSize: uncompressedSize,
        compressedSize: compressedSize
    )
}

/// Builds an `ArchiveEntry` whose recorded name ZynSign must refuse.
func makeRejectedEntry(
    _ rawName: String,
    kind: ArchiveEntryKind = .regularFile,
    uncompressedSize: Int = 0,
    compressedSize: Int = 0
) -> ArchiveEntry {
    ArchiveEntry(
        rejectedName: rawName,
        kind: kind,
        uncompressedSize: uncompressedSize,
        compressedSize: compressedSize
    )
}

/// A validated archive path from a literal name.
func makePath(_ name: String) -> ArchivePath {
    guard let path = ArchivePath(rawValue: name) else {
        preconditionFailure("Test fixture used an unsafe archive path: \(name)")
    }
    return path
}

/// The entry table of a minimal, structurally valid application package.
func validPackageEntryTable(bundleName: String = "Example.app") -> [ArchiveEntry] {
    [
        makeEntry(IPALayout.payloadDirectoryName, kind: .directory),
        makeEntry("\(IPALayout.payloadDirectoryName)/\(bundleName)", kind: .directory),
        makeEntry("\(IPALayout.payloadDirectoryName)/\(bundleName)/Info.plist", uncompressedSize: 128, compressedSize: 96),
        makeEntry("\(IPALayout.payloadDirectoryName)/\(bundleName)/Example", uncompressedSize: 4096, compressedSize: 2048),
    ]
}

// MARK: - Archive reader double

/// An in-memory `ArchiveReader` standing in for a container.
///
/// It exists so that application-layer orchestration can be exercised without
/// a filesystem, and so that container failures can be produced on demand
/// rather than simulated by corrupting real bytes.
final class SyntheticArchiveReader: ArchiveReader {

    enum Failure: Error, Equatable {
        case entryTableUnreadable
        case contentUnreadable
    }

    private let table: [ArchiveEntry]
    private let contentByPath: [String: Data]
    private let failure: Failure?

    /// How many times `close()` was called.
    private(set) var closeCount = 0

    /// The paths content was requested for, in order.
    private(set) var requestedPaths: [ArchivePath] = []

    init(
        entryTable: [ArchiveEntry],
        contentByPath: [String: Data] = [:],
        failure: Failure? = nil
    ) {
        self.table = entryTable
        self.contentByPath = contentByPath
        self.failure = failure
    }

    func readEntryTable() throws -> [ArchiveEntry] {
        if let failure = failure, failure == .entryTableUnreadable {
            throw ZynSignError.unreadableArtifact(diagnosticDetail: "synthetic container failure")
        }
        return table
    }

    func containsEntry(at path: ArchivePath) throws -> Bool {
        table.contains { $0.path == path }
    }

    func entryKind(at path: ArchivePath) throws -> ArchiveEntryKind? {
        table.first { $0.path == path }?.kind
    }

    func readEntryData(at path: ArchivePath, maximumBytes: Int) throws -> Data {
        requestedPaths.append(path)
        if let failure = failure, failure == .contentUnreadable {
            throw ZynSignError.archiveEntryUnreadable(diagnosticDetail: "synthetic container failure")
        }
        guard let content = contentByPath[path.rawValue] else {
            throw ZynSignError.invalidArtifact(diagnosticDetail: "synthetic container has no entry at '\(path.rawValue)'")
        }
        guard content.count <= maximumBytes else {
            throw ZynSignError.archiveResourceLimitExceeded(diagnosticDetail: "synthetic container refused an oversized read")
        }
        return content
    }

    func readEntryPrefix(at path: ArchivePath, maximumBytes: Int) throws -> Data {
        requestedPaths.append(path)
        if let failure = failure, failure == .contentUnreadable {
            throw ZynSignError.archiveEntryUnreadable(diagnosticDetail: "synthetic container failure")
        }
        guard let content = contentByPath[path.rawValue] else {
            throw ZynSignError.invalidArtifact(diagnosticDetail: "synthetic container has no entry at '\(path.rawValue)'")
        }
        guard maximumBytes >= 0 else { return Data() }
        if content.count <= maximumBytes {
            return content
        }
        return Data(content.prefix(maximumBytes))
    }

    func close() {
        closeCount += 1
    }
}

// MARK: - Reader provider double

/// An `ArtifactArchiveReaderProvider` that returns a prepared outcome.
struct SyntheticArchiveReaderProvider: ArtifactArchiveReaderProvider {

    let result: Result<any ArchiveReader, any Error>

    static func providing(_ reader: any ArchiveReader) -> SyntheticArchiveReaderProvider {
        SyntheticArchiveReaderProvider(result: .success(reader))
    }

    static func failing(with error: any Error) -> SyntheticArchiveReaderProvider {
        SyntheticArchiveReaderProvider(result: .failure(error))
    }

    func archiveReader(for artifact: ArtifactIdentifier) throws -> any ArchiveReader {
        try result.get()
    }
}
