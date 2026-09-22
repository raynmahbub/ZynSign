import XCTest
@testable import ZynSign

/// End-to-end tests of the persistence lifecycle over the real platform
/// implementations, wired the way the composition root wires them but over
/// a temporary directory the test owns.
///
/// A "session" is one set of freshly constructed intake, stores, library,
/// and import use case over the same locations — what a relaunch produces.
/// Nothing is shared between sessions except the files on disk. Every
/// package is generated in memory by the fixture builder; no application
/// container or real package is involved.
final class LibraryPersistenceLifecycleTests: XCTestCase {

    private struct Session {
        let library: ApplicationLibrary
        let importing: IPAPackageImport
        let readerProvider: DirectoryArtifactArchiveReaderProvider
    }

    private var workDirectory: URL!
    private var sourceDirectory: URL!
    private var stagingDirectory: URL!
    private var catalogLocation: URL!
    private var artifactDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = try LibraryFixtures.makeTemporaryDirectory()
        sourceDirectory = workDirectory.appendingPathComponent("Sources", isDirectory: true)
        stagingDirectory = workDirectory.appendingPathComponent("Staging", isDirectory: true)
        let libraryRoot = workDirectory.appendingPathComponent("Library", isDirectory: true)
        catalogLocation = libraryRoot.appendingPathComponent("catalog.json", isDirectory: false)
        artifactDirectory = libraryRoot.appendingPathComponent("Artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        sourceDirectory = nil
        stagingDirectory = nil
        catalogLocation = nil
        artifactDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Mirrors `CompositionRoot.makePackageImport()` over the test's directories.
    private func makeSession() -> Session {
        let intake = SecurityScopedArtifactIntake(directory: stagingDirectory)
        let readerProvider = DirectoryArtifactArchiveReaderProvider(
            directories: [artifactDirectory, intake.directory],
            fileExtension: intake.fileExtension
        )
        let library = ApplicationLibrary(
            records: FileApplicationRecordStore(catalogLocation: catalogLocation),
            artifacts: FileLibraryArtifactStore(
                stagingDirectory: intake.directory,
                libraryDirectory: artifactDirectory,
                fileExtension: intake.fileExtension
            )
        )
        let importing = IPAPackageImport(intake: intake, readerProvider: readerProvider, library: library)
        return Session(library: library, importing: importing, readerProvider: readerProvider)
    }

    /// Writes a synthetic, structurally valid package to the source
    /// directory. Different bundle names produce different bytes with the
    /// same declared metadata.
    private func writeSource(name: String = "Example.ipa", bundleName: String = "Example.app") -> URL {
        let container = ZipFixtureBuilder.archive(ZipFixtureBuilder.validPackage(bundleName: bundleName))
        return ImportFixtures.writeFile(named: name, content: Data(container), in: sourceDirectory)
    }

    private func artifactFileNames() -> Set<String> {
        ImportFixtures.fileNames(in: artifactDirectory)
    }

    private func stagedFileNames() -> Set<String> {
        ImportFixtures.fileNames(in: stagingDirectory)
    }

    private func recordedAdmission(_ result: PackageImportResult, file: StaticString = #filePath, line: UInt = #line) throws -> ApplicationRecord {
        guard case .recorded(let record, _) = result.admission else {
            XCTFail("Expected a recorded admission, got \(String(describing: result.admission))", file: file, line: line)
            throw ZynSignError.libraryRecordNotFound(diagnosticDetail: "test expectation failed")
        }
        return record
    }

    // MARK: - Import, relaunch, read

    func testImportedPackageIsRecordedAndReadableInANewSession() async throws {
        let source = writeSource()
        let first = makeSession()

        let result = try await first.importing.importArtifact(from: source)
        let record = try recordedAdmission(result)

        // The staged copy was moved, not copied or left behind, and the
        // catalog was written.
        XCTAssertTrue(stagedFileNames().isEmpty)
        XCTAssertEqual(artifactFileNames(), ["\(record.artifact.artifactID.rawValue).ipa"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogLocation.path))
        XCTAssertEqual(record.artifact.byteCount, try Data(contentsOf: source).count)
        XCTAssertEqual(record.artifact.fingerprint, LibraryFixtures.fingerprint(of: try Data(contentsOf: source)))

        // A new session shares nothing in memory with the first.
        let second = makeSession()
        let entries = try await second.library.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.record, record)
        XCTAssertEqual(entries.first?.artifactAvailability, .available)
        XCTAssertEqual(entries.first?.record.bundleIdentifier.rawValue, "com.example.synthetic")

        // The recorded artifact is reachable by identifier through the
        // archive boundary, now from library storage.
        let reader = try second.readerProvider.archiveReader(for: record.artifact.artifactID)
        defer { reader.close() }
        let paths = try reader.readEntryTable().compactMap { $0.path?.rawValue }
        XCTAssertTrue(paths.contains("Payload/Example.app"))
    }

    // MARK: - Duplicates across sessions

    func testReimportingTheSameFileInANewSessionIsRecognisedAndKeepsOneCopy() async throws {
        let source = writeSource()
        let first = makeSession()
        let firstResult = try await first.importing.importArtifact(from: source)
        let firstRecord = try recordedAdmission(firstResult)

        let second = makeSession()
        let result = try await second.importing.importArtifact(from: source)

        XCTAssertEqual(result.admission, .alreadyRecorded(existing: firstRecord))
        XCTAssertTrue(stagedFileNames().isEmpty)
        XCTAssertEqual(artifactFileNames().count, 1)
        let entries = try await second.library.entries()
        XCTAssertEqual(entries.map { $0.record }, [firstRecord])
    }

    func testRebuiltPackageWithTheSameDeclaredMetadataIsKeptAlongsideTheOriginal() async throws {
        let session = makeSession()
        let firstResult = try await session.importing.importArtifact(from: writeSource(name: "Original.ipa"))
        let firstRecord = try recordedAdmission(firstResult)

        let result = try await session.importing.importArtifact(
            from: writeSource(name: "Rebuilt.ipa", bundleName: "Rebuilt.app")
        )

        guard case .recorded(let record, let relation) = result.admission else {
            return XCTFail("Expected a recorded admission, got \(String(describing: result.admission))")
        }
        XCTAssertEqual(relation, .sameDeclaredVersion([firstRecord]))
        XCTAssertEqual(record.identity, firstRecord.identity)
        XCTAssertNotEqual(record.artifact.fingerprint, firstRecord.artifact.fingerprint)
        XCTAssertEqual(artifactFileNames().count, 2)
        let entries = try await makeSession().library.entries()
        XCTAssertEqual(entries.map { $0.record.id }, [firstRecord.id, record.id])
    }

    // MARK: - Removal

    func testRemovingAnEntryDeletesTheRecordAndItsArtifactForGood() async throws {
        let session = makeSession()
        let result = try await session.importing.importArtifact(from: writeSource())
        let record = try recordedAdmission(result)

        try await session.library.remove(recordWithID: record.id)

        XCTAssertTrue(artifactFileNames().isEmpty)
        let entries = try await session.library.entries()
        XCTAssertTrue(entries.isEmpty)
        let afterRelaunch = try await makeSession().library.entries()
        XCTAssertTrue(afterRelaunch.isEmpty)
        let orphans = try await makeSession().library.orphanedArtifacts()
        XCTAssertTrue(orphans.isEmpty)
    }

    // MARK: - Missing and orphaned artifacts

    func testMissingArtifactIsReportedInANewSessionAndNeverRecreated() async throws {
        let source = writeSource()
        let firstResult = try await makeSession().importing.importArtifact(from: source)
        let record = try recordedAdmission(firstResult)
        let artifactLocation = artifactDirectory
            .appendingPathComponent(record.artifact.artifactID.rawValue, isDirectory: false)
            .appendingPathExtension("ipa")
        try FileManager.default.removeItem(at: artifactLocation)

        let session = makeSession()
        let entries = try await session.library.entries()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.record, record)
        XCTAssertEqual(entries.first?.artifactAvailability, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactLocation.path))
        XCTAssertThrowsError(try session.readerProvider.archiveReader(for: record.artifact.artifactID))

        // Importing the same bytes again records them anew rather than
        // repairing the stale record, which stays for diagnosis.
        let reimportResult = try await session.importing.importArtifact(from: source)
        let again = try recordedAdmission(reimportResult)
        XCTAssertNotEqual(again.id, record.id)
        XCTAssertEqual(again.artifact.fingerprint, record.artifact.fingerprint)
        let afterReimport = try await session.library.entries()
        XCTAssertEqual(afterReimport.map { $0.artifactAvailability }, [.missing, .available])
    }

    func testStrayArtifactsAreDetectedAndRemovedOnlyOnRequest() async throws {
        let session = makeSession()
        let result = try await session.importing.importArtifact(from: writeSource())
        let record = try recordedAdmission(result)
        let orphan = ArtifactIdentifier()
        ImportFixtures.writeFile(named: "\(orphan.rawValue).ipa", content: Data("left behind".utf8), in: artifactDirectory)

        let orphans = try await session.library.orphanedArtifacts()
        XCTAssertEqual(orphans, [orphan])
        XCTAssertEqual(artifactFileNames().count, 2)

        let removed = try await session.library.removeOrphanedArtifacts()

        XCTAssertEqual(removed, [orphan])
        XCTAssertEqual(artifactFileNames(), ["\(record.artifact.artifactID.rawValue).ipa"])
        let entries = try await session.library.entries()
        XCTAssertEqual(entries.first?.artifactAvailability, .available)
    }

    // MARK: - Rejected imports

    func testRejectedPackageLeavesNoRecordAndNoArtifact() async throws {
        let session = makeSession()
        let source = ImportFixtures.writeFile(
            named: "Broken.ipa",
            content: Data(ZipFixtureBuilder.notAnArchive()),
            in: sourceDirectory
        )

        let result = try await session.importing.importArtifact(from: source)

        XCTAssertFalse(result.isAccepted)
        XCTAssertNil(result.admission)
        XCTAssertTrue(stagedFileNames().isEmpty)
        XCTAssertTrue(artifactFileNames().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogLocation.path))
        let entries = try await session.library.entries()
        XCTAssertTrue(entries.isEmpty)
    }
}
