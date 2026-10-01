import XCTest
@testable import ZynSign

final class IPAPackageImportTests: XCTestCase {

    // MARK: - Helpers

    private var records: InMemoryApplicationRecordStore!
    private var artifacts: SyntheticLibraryArtifactStore!
    private var library: ApplicationLibrary!

    override func setUp() {
        super.setUp()
        records = InMemoryApplicationRecordStore()
        artifacts = SyntheticLibraryArtifactStore()
        let clock = SyntheticClock()
        library = ApplicationLibrary(records: records, artifacts: artifacts, now: { clock.now() })
    }

    override func tearDown() {
        library = nil
        artifacts = nil
        records = nil
        super.tearDown()
    }

    /// Builds the use case over synthetic ports. The intake shares its
    /// staging area with the library's artifact store, as the composition
    /// root arranges for the real implementations.
    private func makeUseCase(
        intake: SyntheticIntake,
        reader: any ArchiveReader
    ) -> IPAPackageImport {
        intake.artifactStore = artifacts
        return IPAPackageImport(
            intake: intake,
            readerProvider: SyntheticArchiveReaderProvider.providing(reader),
            library: library
        )
    }

    // MARK: - Successful import

    func testSuccessfulImportReturnsExaminedArtifactWithMetadata() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())

        let result = try await useCase.importArtifact(from: ImportFixtures.sourceURL())
        let artifact = result.artifact

        XCTAssertTrue(result.isAccepted)
        XCTAssertEqual(artifact.state, .inspected)
        XCTAssertEqual(artifact.validation?.classification, .valid)
        XCTAssertTrue(artifact.permitsLaterStages)
        XCTAssertEqual(artifact.sourceFileName, "Example.ipa")
        XCTAssertEqual(artifact.metadata?.identity.bundleIdentifier.rawValue, "com.example.synthetic")
        XCTAssertEqual(artifact.metadata?.identity.displayName, "Example")
        XCTAssertEqual(artifact.metadata?.identity.shortVersionString, "1.2")
        XCTAssertEqual(artifact.metadata?.identity.buildVersion, "34")
        XCTAssertEqual(artifact.discoveredBundle?.bundlePath.rawValue, "Payload/Example.app")
        XCTAssertEqual(artifact.discoveredBundle?.executablePath?.rawValue, "Payload/Example.app/Example")
    }

    func testSuccessfulImportRecordsThePackageAndAdoptsTheStagedArchive() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())

        let result = try await useCase.importArtifact(from: ImportFixtures.sourceURL())

        guard case .recorded(let record, let relation) = result.admission else {
            return XCTFail("Expected a recorded admission, got \(String(describing: result.admission))")
        }
        XCTAssertEqual(relation, .unrelated)
        XCTAssertEqual(record.artifact.artifactID, result.artifact.id)
        XCTAssertEqual(record.identity, result.artifact.metadata?.identity)
        XCTAssertEqual(record.executableName, "Example")
        XCTAssertEqual(record.sourceFileName, "Example.ipa")

        // The staged archive was moved into library storage, not discarded
        // and not left staged; the record is what refers to it now.
        XCTAssertEqual(intake.attempted.count, 1)
        XCTAssertEqual(intake.staged, [result.artifact.id])
        XCTAssertTrue(intake.discarded.isEmpty)
        XCTAssertEqual(artifacts.adopted, [result.artifact.id])
        XCTAssertEqual(artifacts.held, [result.artifact.id])
        XCTAssertTrue(artifacts.staged.isEmpty)
        let stored = try await records.record(withID: record.id)
        XCTAssertEqual(stored, record)
    }

    func testImportingIdenticalContentAgainReportsTheExistingRecordAndDiscardsTheCopy() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())
        let first = try await useCase.importArtifact(from: ImportFixtures.sourceURL())

        let second = try await useCase.importArtifact(from: ImportFixtures.sourceURL(name: "Copy.ipa"))

        XCTAssertTrue(second.isAccepted)
        XCTAssertEqual(second.admission, .alreadyRecorded(existing: first.admission!.record))
        XCTAssertEqual(intake.discarded, [second.artifact.id])
        XCTAssertEqual(artifacts.held, [first.artifact.id])
        XCTAssertTrue(artifacts.staged.isEmpty)
        let count = await records.count
        XCTAssertEqual(count, 1)
    }

    func testImportingDifferentContentOfTheSameApplicationRecordsBoth() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())
        let first = try await useCase.importArtifact(from: ImportFixtures.sourceURL())
        intake.nextStagedContent = Data("a rebuilt package with the same declared metadata".utf8)

        let second = try await useCase.importArtifact(from: ImportFixtures.sourceURL())

        guard case .recorded(let record, let relation) = second.admission else {
            return XCTFail("Expected a recorded admission, got \(String(describing: second.admission))")
        }
        XCTAssertEqual(relation, .sameDeclaredVersion([first.admission!.record]))
        XCTAssertNotEqual(record.id, first.admission!.record.id)
        XCTAssertTrue(intake.discarded.isEmpty)
        XCTAssertEqual(artifacts.held, [first.artifact.id, second.artifact.id])
    }

    func testAdmissionFailureIsTypedAndLeavesNothingStagedOrHeld() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())
        await records.failInserts(with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic"))

        do {
            _ = try await useCase.importArtifact(from: ImportFixtures.sourceURL())
            XCTFail("Expected the admission failure to be thrown.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
            XCTAssertEqual(error.userMessage, ZynSignError.libraryStorageFailure().userMessage)
        }

        XCTAssertEqual(intake.staged.count, 1)
        XCTAssertEqual(intake.discarded, intake.staged)
        XCTAssertTrue(artifacts.held.isEmpty)
        XCTAssertTrue(artifacts.staged.isEmpty)
        let count = await records.count
        XCTAssertEqual(count, 0)
    }

    // MARK: - Rejected imports

    func testImportWithoutApplicationBundleIsRejectedAndDiscarded() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.emptyPayloadReader())

        let result = try await useCase.importArtifact(from: ImportFixtures.sourceURL())
        let artifact = result.artifact

        XCTAssertFalse(result.isAccepted)
        XCTAssertNil(result.admission)
        XCTAssertEqual(artifact.state, .invalid)
        XCTAssertFalse(artifact.permitsLaterStages)
        XCTAssertNil(artifact.metadata)
        XCTAssertEqual(artifact.validation?.errors.first?.code, .missingApplicationBundle)
        XCTAssertEqual(intake.discarded, [artifact.id])
        XCTAssertTrue(artifacts.adopted.isEmpty)
        XCTAssertTrue(artifacts.staged.isEmpty)
        let count = await records.count
        XCTAssertEqual(count, 0)
    }

    func testImportWithMalformedMetadataIsRejectedAndDiscarded() async throws {
        let intake = SyntheticIntake()
        let reader = ImportFixtures.validReader(metadata: Data("not a property list".utf8))
        let useCase = makeUseCase(intake: intake, reader: reader)

        let result = try await useCase.importArtifact(from: ImportFixtures.sourceURL())
        let artifact = result.artifact

        XCTAssertNil(result.admission)
        XCTAssertEqual(artifact.state, .invalid)
        XCTAssertFalse(artifact.permitsLaterStages)
        XCTAssertEqual(artifact.validation?.errors.first?.code, .unreadableInfoPlist)
        XCTAssertEqual(intake.discarded, [artifact.id])
        XCTAssertTrue(artifacts.adopted.isEmpty)
    }

    func testUnreadableContainerIsRecordedAsRejectionAndDiscarded() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.unreadableReader())

        let result = try await useCase.importArtifact(from: ImportFixtures.sourceURL())
        let artifact = result.artifact

        XCTAssertNil(result.admission)
        XCTAssertEqual(artifact.state, .invalid)
        XCTAssertEqual(artifact.validation?.errors.first?.code, .unreadableArchive)
        XCTAssertEqual(intake.discarded, [artifact.id])
        XCTAssertTrue(artifacts.adopted.isEmpty)
    }

    // MARK: - File-type policy

    func testFileWithoutPackageExtensionIsRefusedBeforeStaging() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())

        do {
            _ = try await useCase.importArtifact(from: ImportFixtures.sourceURL(name: "Example.zip"))
            XCTFail("Expected the import to be refused.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .unsupportedInput)
        }

        XCTAssertTrue(intake.attempted.isEmpty)
    }

    func testFileWithoutAnyExtensionIsRefusedBeforeStaging() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())

        do {
            _ = try await useCase.importArtifact(from: ImportFixtures.sourceURL(name: "Example"))
            XCTFail("Expected the import to be refused.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .unsupportedInput)
        }

        XCTAssertTrue(intake.attempted.isEmpty)
    }

    func testPackageExtensionIsMatchedCaseInsensitively() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())

        let result = try await useCase.importArtifact(from: ImportFixtures.sourceURL(name: "Package.IPA"))
        XCTAssertTrue(result.isAccepted)
        XCTAssertEqual(intake.staged.count, 1)
    }

    func testTIPAUsesTheSameValidatedImportPipelineAsIPA() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())

        let result = try await useCase.importArtifact(from: ImportFixtures.sourceURL(name: "TrollStore.TIPA"))

        XCTAssertTrue(result.isAccepted)
        XCTAssertEqual(result.artifact.sourceFileName, "TrollStore.TIPA")
        XCTAssertEqual(result.artifact.validation?.classification, .valid)
        XCTAssertEqual(intake.attempted.count, 1)
        XCTAssertEqual(intake.staged, [result.artifact.id])
    }

    func testFilePolicyAcceptsOnlyTheExactPackageExtension() {
        XCTAssertTrue(IPAFileFormat.acceptsPathExtension("ipa"))
        XCTAssertTrue(IPAFileFormat.acceptsPathExtension("IPA"))
        XCTAssertTrue(IPAFileFormat.acceptsPathExtension("Ipa"))
        XCTAssertTrue(IPAFileFormat.acceptsPathExtension("tipa"))
        XCTAssertTrue(IPAFileFormat.acceptsPathExtension("TIPA"))
        XCTAssertTrue(IPAFileFormat.acceptsPathExtension("TiPa"))
        XCTAssertFalse(IPAFileFormat.acceptsPathExtension("zip"))
        XCTAssertFalse(IPAFileFormat.acceptsPathExtension("ipazine"))
        XCTAssertFalse(IPAFileFormat.acceptsPathExtension("tipazine"))
        XCTAssertFalse(IPAFileFormat.acceptsPathExtension(""))
        XCTAssertTrue(IPAFileFormat.accepts(ImportFixtures.sourceURL(name: "a/b.Example.ipA")))
        XCTAssertTrue(IPAFileFormat.accepts(ImportFixtures.sourceURL(name: "a/b.Example.TiPa")))
        XCTAssertFalse(IPAFileFormat.accepts(ImportFixtures.sourceURL(name: "b.tar.ipa.bin")))
        XCTAssertFalse(IPAFileFormat.accepts(ImportFixtures.sourceURL(name: "b.tipa.zip")))
    }

    // MARK: - Staging failures

    func testStagingFailureIsPropagatedAsTypedErrorWithoutCleanup() async throws {
        let intake = SyntheticIntake()
        intake.behaviour = .fails
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())

        do {
            _ = try await useCase.importArtifact(from: ImportFixtures.sourceURL())
            XCTFail("Expected the staging failure to be thrown.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
            XCTAssertEqual(error.userMessage, ZynSignError.selectedFileUnavailable().userMessage)
        }

        XCTAssertEqual(intake.attempted.count, 1)
        XCTAssertTrue(intake.staged.isEmpty)
        XCTAssertTrue(intake.discarded.isEmpty)
    }

    // MARK: - Cancellation

    func testCancellationDuringStagingStopsTheImport() async throws {
        let intake = SyntheticIntake()
        intake.behaviour = .waitsUntilCancelledThenFails
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())

        let task = Task { try await useCase.importArtifact(from: ImportFixtures.sourceURL()) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled import to throw.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .cancelled)
        }

        XCTAssertTrue(intake.staged.isEmpty)
        XCTAssertTrue(intake.discarded.isEmpty)
    }

    func testCancellationAfterStagingDiscardsTheStagedArchive() async throws {
        let intake = SyntheticIntake()
        intake.behaviour = .waitsUntilCancelledThenSucceeds
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())

        let task = Task { try await useCase.importArtifact(from: ImportFixtures.sourceURL()) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled import to throw.")
        } catch {
            assertReportsCancellation(error)
        }

        XCTAssertEqual(intake.staged.count, 1)
        XCTAssertEqual(intake.discarded.count, 1)
        if let stagedID = intake.staged.first, let discardedID = intake.discarded.first {
            XCTAssertEqual(stagedID, discardedID)
        }
        XCTAssertTrue(artifacts.adopted.isEmpty)
        XCTAssertTrue(artifacts.staged.isEmpty)
        let count = await records.count
        XCTAssertEqual(count, 0)
    }

    /// A cancelled import must surface as an ordinary cancellation — either
    /// the structured cancellation error or a typed error in the cancelled
    /// category — and never as an application failure.
    private func assertReportsCancellation(_ error: any Error) {
        if let zynSignError = error as? ZynSignError {
            XCTAssertEqual(zynSignError.category, .cancelled)
        } else {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
    }
}
