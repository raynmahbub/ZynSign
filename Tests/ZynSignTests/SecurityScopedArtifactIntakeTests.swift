import XCTest
@testable import ZynSign

/// Filesystem-backed tests for the platform intake.
///
/// The tests use only a temporary directory the test creates and removes,
/// and containers generated in memory by the fixture builder. No real
/// package, provider, or system document-picker environment is involved;
/// security-scoped grants are exercised through the no-scope-required path,
/// which is the behaviour a plain file URL produces.
final class SecurityScopedArtifactIntakeTests: XCTestCase {

    private var workDirectory: URL!
    private var stagingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignIntakeTests-\(UUID().uuidString)", isDirectory: true)
        stagingDirectory = workDirectory.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        stagingDirectory = nil
        try super.tearDownWithError()
    }

    private func makeIntake(copyChunkSize: Int = 1_048_576) -> SecurityScopedArtifactIntake {
        SecurityScopedArtifactIntake(
            directory: stagingDirectory,
            copyChunkSize: copyChunkSize
        )
    }

    private func writeSource(name: String = "Example.ipa") -> URL {
        let container = ZipFixtureBuilder.archive(ZipFixtureBuilder.validPackage())
        return ImportFixtures.writeFile(
            named: name,
            content: Data(container),
            in: workDirectory
        )
    }

    // MARK: - Staging

    func testStagedArchiveIsPlacedUnderTheArtifactIdentifier() throws {
        let intake = makeIntake()
        let artifact = IPAArtifact()
        let source = writeSource()

        try intake.stageDocument(at: source, as: artifact.id)

        let stagedURL = stagingDirectory
            .appendingPathComponent(artifact.id.rawValue)
            .appendingPathExtension("ipa")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(
            FileManager.default.contents(atPath: stagedURL.path),
            FileManager.default.contents(atPath: source.path)
        )
    }

    func testStagedArchiveLocationsAreUniqueAndInsideTheStagingDirectory() throws {
        let intake = makeIntake()
        let source = writeSource()
        let first = IPAArtifact()
        let second = IPAArtifact()

        try intake.stageDocument(at: source, as: first.id)
        try intake.stageDocument(at: source, as: second.id)

        let firstURL = stagingDirectory
            .appendingPathComponent(first.id.rawValue)
            .appendingPathExtension("ipa")
        let secondURL = stagingDirectory
            .appendingPathComponent(second.id.rawValue)
            .appendingPathExtension("ipa")
        XCTAssertNotEqual(firstURL, secondURL)
        let stagingPath = stagingDirectory.standardizedFileURL.path
        for url in [firstURL, secondURL] {
            XCTAssertTrue(
                url.standardizedFileURL.path.hasPrefix(stagingPath),
                "Staged archive \(url) escaped the staging directory."
            )
        }
    }

    func testStagedArchiveIsReadableThroughTheEstablishedArchiveBoundary() throws {
        let intake = makeIntake()
        let source = writeSource()
        let artifact = IPAArtifact()

        try intake.stageDocument(at: source, as: artifact.id)

        // The composition root binds the reader provider to the same
        // directory and extension; this mirrors that binding.
        let provider = DirectoryArtifactArchiveReaderProvider(directory: stagingDirectory)
        let reader = try provider.archiveReader(for: artifact.id)
        defer { reader.close() }

        let entryTable = try reader.readEntryTable()
        let acceptedPaths = entryTable.compactMap { $0.path }
        XCTAssertTrue(acceptedPaths.contains { IPALayout.isPayloadRoot($0) })
        XCTAssertTrue(acceptedPaths.contains { $0.rawValue == "Payload/Example.app" })

        let informationPath = try XCTUnwrap(IPALayout.bundleInformationPath(
            within: try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app"))
        ))
        let plistData = try reader.readEntryData(
            at: informationPath,
            maximumBytes: ArchiveLimits.default.maximumInspectionReadBytes
        )
        XCTAssertEqual(plistData, Data(ZipFixtureBuilder.syntheticPlist))
    }

    // MARK: - Refusals

    func testMissingSourceIsRefusedAndStagesNothing() throws {
        let intake = makeIntake()
        let missing = workDirectory.appendingPathComponent("Gone.ipa")

        XCTAssertThrowsError(try intake.stageDocument(at: missing, as: IPAArtifact().id)) { error in
            guard let zynSignError = error as? ZynSignError else {
                return XCTFail("Expected a typed error, got \(error)")
            }
            XCTAssertEqual(zynSignError.category, .storageFailure)
            XCTAssertEqual(zynSignError.userMessage, ZynSignError.selectedFileUnavailable().userMessage)
        }
        XCTAssertTrue(ImportFixtures.fileNames(in: stagingDirectory).isEmpty)
    }

    func testDirectorySelectedAsDocumentIsRefusedAndStagesNothing() throws {
        let intake = makeIntake()
        let directory = workDirectory.appendingPathComponent("Folder.ipa", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try intake.stageDocument(at: directory, as: IPAArtifact().id)) { error in
            guard let zynSignError = error as? ZynSignError else {
                return XCTFail("Expected a typed error, got \(error)")
            }
            XCTAssertEqual(zynSignError.category, .unsupportedInput)
        }
        XCTAssertTrue(ImportFixtures.fileNames(in: stagingDirectory).isEmpty)
    }

    // MARK: - Discarding

    func testDiscardRemovesOnlyTheNamedArchive() throws {
        let intake = makeIntake()
        let source = writeSource()
        let first = IPAArtifact()
        let second = IPAArtifact()
        try intake.stageDocument(at: source, as: first.id)
        try intake.stageDocument(at: source, as: second.id)

        intake.discardStagedDocument(for: first.id)

        XCTAssertEqual(
            ImportFixtures.fileNames(in: stagingDirectory),
            ["\(second.id.rawValue).ipa"]
        )

        // Discarding an identifier with no staged archive does nothing.
        intake.discardStagedDocument(for: first.id)
        intake.discardStagedDocument(for: ArtifactIdentifier())
        XCTAssertEqual(
            ImportFixtures.fileNames(in: stagingDirectory),
            ["\(second.id.rawValue).ipa"]
        )
    }

    // MARK: - Leftover lifecycle

    func testLeftoversFromAPreviousProcessAreClearedBeforeTheFirstStaging() throws {
        // The stale file is planted directly, before any intake use, so the
        // staging directory — otherwise created lazily by the intake — must
        // exist first.
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let staleName = "\(UUID().uuidString).ipa"
        ImportFixtures.writeFile(named: staleName, content: Data([0x50]), in: stagingDirectory)

        let intake = makeIntake()
        try intake.stageDocument(at: writeSource(), as: IPAArtifact().id)

        XCTAssertEqual(ImportFixtures.fileNames(in: stagingDirectory).contains(staleName), false)
        XCTAssertEqual(ImportFixtures.fileNames(in: stagingDirectory).count, 1)
    }

    // MARK: - Cancellation

    func testCancelledStagingLeavesNothingBehind() async throws {
        let intake = makeIntake()
        let source = writeSource()

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try intake.stageDocument(at: source, as: IPAArtifact().id)
            }
            group.cancelAll()
            do {
                try await group.waitForAll()
                XCTFail("Expected the cancelled staging to throw.")
            } catch {
                // The intake reports cancellation as a typed outcome.
                XCTAssertTrue(error is ZynSignError || error is CancellationError)
            }
        }

        XCTAssertTrue(ImportFixtures.fileNames(in: stagingDirectory).isEmpty)
    }
}
