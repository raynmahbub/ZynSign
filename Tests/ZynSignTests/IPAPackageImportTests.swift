import XCTest
@testable import ZynSign

final class IPAPackageImportTests: XCTestCase {

    // MARK: - Helpers

    private func makeUseCase(
        intake: SyntheticIntake,
        reader: any ArchiveReader
    ) -> IPAPackageImport {
        IPAPackageImport(
            intake: intake,
            readerProvider: SyntheticArchiveReaderProvider.providing(reader)
        )
    }

    // MARK: - Successful import

    func testSuccessfulImportReturnsExaminedArtifactWithMetadata() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())

        let artifact = try await useCase.importArtifact(from: ImportFixtures.sourceURL())

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

    func testSuccessfulImportRetainsTheStagedArchive() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.validReader())

        let artifact = try await useCase.importArtifact(from: ImportFixtures.sourceURL())

        XCTAssertEqual(intake.attempted.count, 1)
        XCTAssertEqual(intake.staged, [artifact.id])
        XCTAssertTrue(intake.discarded.isEmpty)
    }

    // MARK: - Rejected imports

    func testImportWithoutApplicationBundleIsRejectedAndDiscarded() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.emptyPayloadReader())

        let artifact = try await useCase.importArtifact(from: ImportFixtures.sourceURL())

        XCTAssertEqual(artifact.state, .invalid)
        XCTAssertFalse(artifact.permitsLaterStages)
        XCTAssertNil(artifact.metadata)
        XCTAssertEqual(artifact.validation?.errors.first?.code, .missingApplicationBundle)
        XCTAssertEqual(intake.discarded, [artifact.id])
    }

    func testImportWithMalformedMetadataIsRejectedAndDiscarded() async throws {
        let intake = SyntheticIntake()
        let reader = ImportFixtures.validReader(metadata: Data("not a property list".utf8))
        let useCase = makeUseCase(intake: intake, reader: reader)

        let artifact = try await useCase.importArtifact(from: ImportFixtures.sourceURL())

        XCTAssertEqual(artifact.state, .invalid)
        XCTAssertFalse(artifact.permitsLaterStages)
        XCTAssertEqual(artifact.validation?.errors.first?.code, .unreadableInfoPlist)
        XCTAssertEqual(intake.discarded, [artifact.id])
    }

    func testUnreadableContainerIsRecordedAsRejectionAndDiscarded() async throws {
        let intake = SyntheticIntake()
        let useCase = makeUseCase(intake: intake, reader: ImportFixtures.unreadableReader())

        let artifact = try await useCase.importArtifact(from: ImportFixtures.sourceURL())

        XCTAssertEqual(artifact.state, .invalid)
        XCTAssertEqual(artifact.validation?.errors.first?.code, .unreadableArchive)
        XCTAssertEqual(intake.discarded, [artifact.id])
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

        let artifact = try await useCase.importArtifact(from: ImportFixtures.sourceURL(name: "Package.IPA"))
        XCTAssertTrue(artifact.permitsLaterStages)
        XCTAssertEqual(intake.staged.count, 1)
    }

    func testFilePolicyAcceptsOnlyTheExactPackageExtension() {
        XCTAssertTrue(IPAFileFormat.acceptsPathExtension("ipa"))
        XCTAssertTrue(IPAFileFormat.acceptsPathExtension("IPA"))
        XCTAssertTrue(IPAFileFormat.acceptsPathExtension("Ipa"))
        XCTAssertFalse(IPAFileFormat.acceptsPathExtension("zip"))
        XCTAssertFalse(IPAFileFormat.acceptsPathExtension("ipazine"))
        XCTAssertFalse(IPAFileFormat.acceptsPathExtension(""))
        XCTAssertTrue(IPAFileFormat.accepts(ImportFixtures.sourceURL(name: "a/b.Example.ipA")))
        XCTAssertFalse(IPAFileFormat.accepts(ImportFixtures.sourceURL(name: "b.tar.ipa.bin")))
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
