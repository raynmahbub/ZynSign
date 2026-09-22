import XCTest
@testable import ZynSign

/// Filesystem-backed tests for the library artifact store.
///
/// Every test works in a temporary directory it creates and removes, with
/// synthetic byte content; no application container or real package is
/// involved.
final class FileLibraryArtifactStoreTests: XCTestCase {

    private var workDirectory: URL!
    private var stagingDirectory: URL!
    private var libraryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = try LibraryFixtures.makeTemporaryDirectory()
        stagingDirectory = workDirectory.appendingPathComponent("Staging", isDirectory: true)
        libraryDirectory = workDirectory.appendingPathComponent("Artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        stagingDirectory = nil
        libraryDirectory = nil
        try super.tearDownWithError()
    }

    private func makeStore(readChunkSize: Int = 1_048_576) -> FileLibraryArtifactStore {
        FileLibraryArtifactStore(
            stagingDirectory: stagingDirectory,
            libraryDirectory: libraryDirectory,
            readChunkSize: readChunkSize
        )
    }

    @discardableResult
    private func stage(_ content: Data, as artifact: ArtifactIdentifier) -> URL {
        ImportFixtures.writeFile(named: "\(artifact.rawValue).ipa", content: content, in: stagingDirectory)
    }

    private func libraryLocation(of artifact: ArtifactIdentifier) -> URL {
        libraryDirectory
            .appendingPathComponent(artifact.rawValue, isDirectory: false)
            .appendingPathExtension("ipa")
    }

    // MARK: - Describing

    func testDescribingMeasuresSizeAndFingerprintOfTheStagedArchive() throws {
        let store = makeStore()
        let artifact = ArtifactIdentifier()
        let content = Data("abc".utf8)
        stage(content, as: artifact)

        let reference = try store.describeStagedArtifact(artifact)

        XCTAssertEqual(reference.artifactID, artifact)
        XCTAssertEqual(reference.byteCount, 3)
        XCTAssertEqual(reference.fingerprint.algorithm, .sha256)
        XCTAssertEqual(
            reference.fingerprint.hexDigest,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingDirectory.appendingPathComponent("\(artifact.rawValue).ipa").path))
    }

    func testDescribingReadsInBoundedChunksWithoutChangingTheResult() throws {
        let store = makeStore(readChunkSize: 7)
        let artifact = ArtifactIdentifier()
        let content = Data((0..<1_000).map { UInt8($0 % 251) })
        stage(content, as: artifact)

        let reference = try store.describeStagedArtifact(artifact)

        XCTAssertEqual(reference.byteCount, 1_000)
        XCTAssertEqual(reference.fingerprint, LibraryFixtures.fingerprint(of: content))
    }

    func testDescribingAnEmptyArchiveProducesAZeroSizeReference() throws {
        let store = makeStore()
        let artifact = ArtifactIdentifier()
        stage(Data(), as: artifact)

        let reference = try store.describeStagedArtifact(artifact)

        XCTAssertEqual(reference.byteCount, 0)
        XCTAssertEqual(reference.fingerprint, LibraryFixtures.fingerprint(of: Data()))
    }

    func testDescribingAnUnstagedArtifactFails() {
        let store = makeStore()

        XCTAssertThrowsError(try store.describeStagedArtifact(ArtifactIdentifier())) { error in
            XCTAssertEqual((error as? ZynSignError)?.userMessage, ZynSignError.artifactNotAvailable().userMessage)
        }
    }

    // MARK: - Adopting

    func testAdoptingMovesTheArchiveFromStagingIntoLibraryStorage() throws {
        let store = makeStore()
        let artifact = ArtifactIdentifier()
        let content = Data("synthetic package".utf8)
        let stagedLocation = stage(content, as: artifact)

        try store.adoptStagedArtifact(artifact)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedLocation.path))
        XCTAssertEqual(try Data(contentsOf: libraryLocation(of: artifact)), content)
        XCTAssertEqual(store.observeArtifact(artifact), .present(byteCount: content.count))
        XCTAssertEqual(try store.heldArtifactIdentifiers(), [artifact])
    }

    func testAdoptingCreatesTheLibraryDirectoryOnFirstUse() throws {
        let store = makeStore()
        let artifact = ArtifactIdentifier()
        stage(Data("x".utf8), as: artifact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryDirectory.path))

        try store.adoptStagedArtifact(artifact)

        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryDirectory.path))
    }

    func testAdoptingAnUnstagedArtifactFailsAndCreatesNothing() {
        let store = makeStore()

        XCTAssertThrowsError(try store.adoptStagedArtifact(ArtifactIdentifier())) { error in
            XCTAssertEqual((error as? ZynSignError)?.userMessage, ZynSignError.artifactNotAvailable().userMessage)
        }
        XCTAssertEqual(store.observeArtifact(ArtifactIdentifier()), .absent)
    }

    func testAdoptingRefusesToOverwriteAHeldArtifact() throws {
        let store = makeStore()
        let artifact = ArtifactIdentifier()
        let original = Data("original".utf8)
        stage(original, as: artifact)
        try store.adoptStagedArtifact(artifact)
        let stagedAgain = stage(Data("replacement".utf8), as: artifact)

        XCTAssertThrowsError(try store.adoptStagedArtifact(artifact)) { error in
            XCTAssertEqual((error as? ZynSignError)?.category, .storageFailure)
            XCTAssertEqual((error as? ZynSignError)?.userMessage, ZynSignError.libraryStorageFailure().userMessage)
        }

        XCTAssertEqual(try Data(contentsOf: libraryLocation(of: artifact)), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedAgain.path))
    }

    // MARK: - Observing and removing

    func testObservingReportsAbsentUntilAdoptedAndAbsentAgainAfterRemoval() throws {
        let store = makeStore()
        let artifact = ArtifactIdentifier()
        stage(Data("12345".utf8), as: artifact)
        XCTAssertEqual(store.observeArtifact(artifact), .absent)

        try store.adoptStagedArtifact(artifact)
        XCTAssertEqual(store.observeArtifact(artifact), .present(byteCount: 5))

        try store.removeArtifact(artifact)
        XCTAssertEqual(store.observeArtifact(artifact), .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryLocation(of: artifact).path))
    }

    func testObservingReflectsChangesMadeBehindTheStoresBack() throws {
        let store = makeStore()
        let artifact = ArtifactIdentifier()
        stage(Data("0123456789".utf8), as: artifact)
        try store.adoptStagedArtifact(artifact)

        try Data("012".utf8).write(to: libraryLocation(of: artifact))
        XCTAssertEqual(store.observeArtifact(artifact), .present(byteCount: 3))

        try FileManager.default.removeItem(at: libraryLocation(of: artifact))
        XCTAssertEqual(store.observeArtifact(artifact), .absent)
    }

    func testRemovingAnArtifactThatIsNotHeldSucceeds() throws {
        let store = makeStore()

        XCTAssertNoThrow(try store.removeArtifact(ArtifactIdentifier()))
    }

    func testRemovingLeavesOtherArtifactsInPlace() throws {
        let store = makeStore()
        let kept = ArtifactIdentifier()
        let removed = ArtifactIdentifier()
        stage(Data("kept".utf8), as: kept)
        stage(Data("removed".utf8), as: removed)
        try store.adoptStagedArtifact(kept)
        try store.adoptStagedArtifact(removed)

        try store.removeArtifact(removed)

        XCTAssertEqual(try store.heldArtifactIdentifiers(), [kept])
    }

    // MARK: - Enumerating

    func testEnumeratingAMissingLibraryDirectoryIsEmpty() throws {
        let store = makeStore()

        XCTAssertEqual(try store.heldArtifactIdentifiers(), [])
    }

    func testEnumeratingIgnoresEntriesThatAreNotArtifacts() throws {
        let store = makeStore()
        let artifact = ArtifactIdentifier()
        stage(Data("held".utf8), as: artifact)
        try store.adoptStagedArtifact(artifact)

        ImportFixtures.writeFile(named: "notes.txt", content: Data("stray".utf8), in: libraryDirectory)
        ImportFixtures.writeFile(named: "not-an-identifier.ipa", content: Data("stray".utf8), in: libraryDirectory)
        ImportFixtures.writeFile(named: "\(ArtifactIdentifier().rawValue).zip", content: Data("stray".utf8), in: libraryDirectory)
        try FileManager.default.createDirectory(
            at: libraryDirectory.appendingPathComponent("\(ArtifactIdentifier().rawValue).ipa", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(try store.heldArtifactIdentifiers(), [artifact])
    }

    func testEnumeratingReportsArtifactsPlacedByAnEarlierProcess() throws {
        let first = ArtifactIdentifier()
        let second = ArtifactIdentifier()
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        ImportFixtures.writeFile(named: "\(first.rawValue).ipa", content: Data("a".utf8), in: libraryDirectory)
        ImportFixtures.writeFile(named: "\(second.rawValue).ipa", content: Data("bb".utf8), in: libraryDirectory)

        let store = makeStore()

        XCTAssertEqual(try store.heldArtifactIdentifiers(), [first, second])
        XCTAssertEqual(store.observeArtifact(second), .present(byteCount: 2))
    }

    // MARK: - Reading adopted artifacts

    func testAdoptedArchiveIsReadableThroughTheArchiveBoundaryInLibraryOrder() throws {
        let store = makeStore()
        let artifact = ArtifactIdentifier()
        let container = ZipFixtureBuilder.archive(ZipFixtureBuilder.validPackage())
        stage(Data(container), as: artifact)
        let provider = DirectoryArtifactArchiveReaderProvider(directories: [libraryDirectory, stagingDirectory])

        // Before adoption the archive is found in staging.
        let stagedReader = try provider.archiveReader(for: artifact)
        XCTAssertFalse(try stagedReader.readEntryTable().isEmpty)
        stagedReader.close()

        try store.adoptStagedArtifact(artifact)

        // After adoption it is found in library storage, under the same identifier.
        let adoptedReader = try provider.archiveReader(for: artifact)
        defer { adoptedReader.close() }
        let acceptedPaths = try adoptedReader.readEntryTable().compactMap { $0.path }
        XCTAssertTrue(acceptedPaths.contains { $0.rawValue == "Payload/Example.app" })

        XCTAssertThrowsError(try provider.archiveReader(for: ArtifactIdentifier())) { error in
            XCTAssertEqual((error as? ZynSignError)?.userMessage, ZynSignError.artifactNotAvailable().userMessage)
        }
    }
}
