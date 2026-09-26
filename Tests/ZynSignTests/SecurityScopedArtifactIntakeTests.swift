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

    func testStagingLeavesOtherWorkingCopiesAlone() throws {
        // A working copy an interrupted import may resume from must survive
        // later stagings; only the launch-time sweep decides what goes.
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let survivorName = "\(UUID().uuidString).ipa"
        ImportFixtures.writeFile(named: survivorName, content: Data([0x50]), in: stagingDirectory)

        let intake = makeIntake()
        try intake.stageDocument(at: writeSource(), as: IPAArtifact().id)

        XCTAssertTrue(ImportFixtures.fileNames(in: stagingDirectory).contains(survivorName))
        XCTAssertEqual(ImportFixtures.fileNames(in: stagingDirectory).count, 2)
    }

    func testTheSweepRemovesLeftoversExceptTheCopiesKept() throws {
        let intake = makeIntake()
        let kept = IPAArtifact().id
        let leftover = IPAArtifact().id
        try intake.stageDocument(at: writeSource(), as: kept)
        try intake.stageDocument(at: writeSource(), as: leftover)
        ImportFixtures.writeFile(named: "partial-copy.tmp", content: Data([0x01]), in: stagingDirectory)

        intake.sweepStagedDocuments(keeping: [kept])

        XCTAssertEqual(ImportFixtures.fileNames(in: stagingDirectory), ["\(kept.rawValue).ipa"])
    }

    func testTheStagedSizeIsReportedOnlyForExistingWorkingCopies() throws {
        let intake = makeIntake()
        let artifact = IPAArtifact().id
        let source = writeSource()
        XCTAssertNil(intake.stagedByteCount(for: artifact))

        try intake.stageDocument(at: source, as: artifact)
        let expected = try Data(contentsOf: source).count
        XCTAssertEqual(intake.stagedByteCount(for: artifact), expected)

        intake.discardStagedDocument(for: artifact)
        XCTAssertNil(intake.stagedByteCount(for: artifact))
    }

    // MARK: - Archive entries

    func testAnArchiveEntryIsStagedAsItsOwnWorkingCopy() throws {
        let package = Array(ImportHubFixtures.package())
        let archive = ZipFixtureBuilder.archive([
            ZipFixtureBuilder.Entry(name: "Apps/App.ipa", content: package, deflate: true),
        ])
        let source = ImportFixtures.writeFile(named: "Bundle.zip", content: Data(archive), in: workDirectory)
        let intake = makeIntake()
        let container = IPAArtifact().id
        let child = IPAArtifact().id
        try intake.stageDocument(at: source, as: container)

        try intake.stageArchiveEntry(
            NestedPackageCandidate(path: makePath("Apps/App.ipa"), byteCount: package.count, compressedByteCount: 0),
            from: container,
            as: child,
            reporting: nil
        )

        XCTAssertEqual(
            try Data(contentsOf: stagingDirectory.appendingPathComponent("\(child.rawValue).ipa")),
            Data(package)
        )
        XCTAssertEqual(try Data(contentsOf: source), Data(archive), "The archive the user chose is only read.")
    }

    func testAFailedArchiveEntryLeavesNothingBehind() throws {
        let archive = ZipFixtureBuilder.archive([ZipFixtureBuilder.Entry(name: "App.ipa", content: [0x01])])
        let source = ImportFixtures.writeFile(named: "Bundle.zip", content: Data(archive), in: workDirectory)
        let intake = makeIntake()
        let container = IPAArtifact().id
        let child = IPAArtifact().id
        try intake.stageDocument(at: source, as: container)

        XCTAssertThrowsError(try intake.stageArchiveEntry(
            NestedPackageCandidate(path: makePath("Missing.ipa"), byteCount: 1, compressedByteCount: 1),
            from: container,
            as: child,
            reporting: nil
        ))
        XCTAssertEqual(ImportFixtures.fileNames(in: stagingDirectory), ["\(container.rawValue).ipa"])
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

    // MARK: - Describing

    func testDescribingADocumentObservesItWithoutCopyingIt() throws {
        let intake = makeIntake()
        let source = writeSource()

        let description = try intake.describeDocument(at: source)

        XCTAssertEqual(description.fileName, "Example.ipa")
        XCTAssertEqual(description.byteCount, FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int)
        XCTAssertEqual(description.kind, .regularFile)
        XCTAssertEqual(description.beginsWithArchiveSignature, true)
        // Describing is an observation: nothing was staged, and the selected
        // document is still where it was.
        XCTAssertTrue(ImportFixtures.fileNames(in: stagingDirectory).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testAnEmptyDocumentIsDescribedAsEmptyAndNotAsAnArchive() throws {
        let intake = makeIntake()
        let empty = ImportFixtures.writeFile(named: "Empty.ipa", content: Data(), in: workDirectory)

        let description = try intake.describeDocument(at: empty)

        XCTAssertEqual(description.byteCount, 0)
        XCTAssertEqual(description.beginsWithArchiveSignature, false)
    }

    func testADocumentThatDoesNotBeginWithAnArchiveSignatureIsObservedAsSuch() throws {
        let intake = makeIntake()
        let text = ImportFixtures.writeFile(
            named: "Notes.ipa",
            content: Data("this is not an archive".utf8),
            in: workDirectory
        )

        let description = try intake.describeDocument(at: text)

        XCTAssertEqual(description.beginsWithArchiveSignature, false)
    }

    func testDescribingAMissingDocumentIsRefused() throws {
        let intake = makeIntake()
        let missing = workDirectory.appendingPathComponent("Gone.ipa")

        XCTAssertThrowsError(try intake.describeDocument(at: missing)) { error in
            guard let zynSignError = error as? ZynSignError else {
                return XCTFail("Expected a typed error, got \(error)")
            }
            XCTAssertEqual(zynSignError.category, .storageFailure)
        }
        XCTAssertTrue(ImportFixtures.fileNames(in: stagingDirectory).isEmpty)
    }

    // MARK: - Progress

    func testStagingReportsTheBytesItHasCopied() throws {
        let container = Data(ZipFixtureBuilder.archive(ZipFixtureBuilder.validPackage()))
        let source = ImportFixtures.writeFile(named: "Example.ipa", content: container, in: workDirectory)
        let intake = makeIntake(copyChunkSize: 8)
        let recorder = RecordingProgress()
        let artifact = IPAArtifact()

        try intake.stageDocument(at: source, as: artifact.id, reporting: recorder)

        let reports = recorder.reports
        XCTAssertFalse(reports.isEmpty)
        XCTAssertTrue(reports.allSatisfy { $0.stage == .copying })
        let last = try XCTUnwrap(reports.last)
        XCTAssertEqual(last.totalUnitCount, container.count)
        XCTAssertEqual(last.completedUnitCount, container.count)

        // The reports describe the same copy the staging performed: what is
        // staged is the whole source, byte for byte.
        let stagedURL = stagingDirectory
            .appendingPathComponent(artifact.id.rawValue)
            .appendingPathExtension("ipa")
        XCTAssertEqual(FileManager.default.contents(atPath: stagedURL.path), container)
    }

    func testStagingNeverChangesTheSelectedDocument() throws {
        let container = Data(ZipFixtureBuilder.archive(ZipFixtureBuilder.validPackage()))
        let source = ImportFixtures.writeFile(named: "Example.ipa", content: container, in: workDirectory)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)
        let intake = makeIntake(copyChunkSize: 4)

        try intake.stageDocument(at: source, as: IPAArtifact().id)
        intake.discardStagedDocument(for: IPAArtifact().id)

        XCTAssertEqual(FileManager.default.contents(atPath: source.path), container)
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        XCTAssertEqual(before[.size] as? Int, after[.size] as? Int)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }
}

/// Collects progress reports so a test can assert what the copy reported.
private final class RecordingProgress: ImportProgressReporting, @unchecked Sendable {

    private let lock = NSLock()
    private var values: [ImportProgress] = []

    var reports: [ImportProgress] {
        lock.withLock { values }
    }

    func report(_ progress: ImportProgress) {
        lock.withLock { values.append(progress) }
    }
}
