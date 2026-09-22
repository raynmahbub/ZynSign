import XCTest
@testable import ZynSign

/// Tests for the import presentation model's phase machine and its
/// rendering of the library's decision.
///
/// The model is exercised with the real import use case over synthetic
/// ports, so the phases it renders are the phases the application layer
/// actually produces.
@MainActor
final class PackageImportModelTests: XCTestCase {

    // MARK: - Helpers

    // One test-case instance exists per test method, so these are fresh
    // for every test.
    private let artifacts = SyntheticLibraryArtifactStore()
    private let clock = SyntheticClock()
    private lazy var library = ApplicationLibrary(
        records: InMemoryApplicationRecordStore(),
        artifacts: artifacts,
        now: { [clock] in clock.now() }
    )

    private func makeModel(
        intake: SyntheticIntake,
        reader: any ArchiveReader
    ) -> PackageImportModel {
        intake.artifactStore = artifacts
        return PackageImportModel(
            importing: IPAPackageImport(
                intake: intake,
                readerProvider: SyntheticArchiveReaderProvider.providing(reader),
                library: library
            )
        )
    }

    /// Spins the main actor until the phase leaves `importing`, bounded so a
    /// model that never settles fails the test instead of hanging it.
    private func awaitSettledPhase(of model: PackageImportModel) async -> PackageImportModel.Phase {
        var spins = 0
        while case .importing = model.phase {
            spins += 1
            if spins > 10_000 {
                XCTFail("The import phase never settled.")
                break
            }
            await Task.yield()
        }
        return model.phase
    }

    // MARK: - Phases

    func testSuccessfulImportShowsSummaryAndTheLibraryDecision() async {
        let intake = SyntheticIntake()
        let model = makeModel(intake: intake, reader: ImportFixtures.validReader())

        XCTAssertEqual(model.phase, .idle)
        model.beginImport(from: ImportFixtures.sourceURL())
        XCTAssertEqual(model.phase, .importing)

        let phase = await awaitSettledPhase(of: model)
        guard case .succeeded(let summary) = phase else {
            return XCTFail("Expected a succeeded phase, got \(phase)")
        }
        XCTAssertEqual(summary.sourceFileName, "Example.ipa")
        XCTAssertEqual(summary.displayName, "Example")
        XCTAssertEqual(summary.bundleIdentifier, "com.example.synthetic")
        XCTAssertEqual(summary.marketingVersion, "1.2")
        XCTAssertEqual(summary.buildVersion, "34")
        XCTAssertEqual(summary.libraryMessage, "The package was added to ZynSign's library.")
        // The archive now belongs to the library; nothing was discarded and
        // nothing is left staged.
        XCTAssertTrue(intake.discarded.isEmpty)
        XCTAssertEqual(artifacts.held, Set(intake.staged))
        XCTAssertTrue(artifacts.staged.isEmpty)
    }

    func testImportingTheSamePackageAgainSucceedsAndSaysItWasNotAddedAgain() async {
        let intake = SyntheticIntake()
        let model = makeModel(intake: intake, reader: ImportFixtures.validReader())
        model.beginImport(from: ImportFixtures.sourceURL())
        _ = await awaitSettledPhase(of: model)

        model.beginImport(from: ImportFixtures.sourceURL(name: "Copy.ipa"))
        let phase = await awaitSettledPhase(of: model)

        guard case .succeeded(let summary) = phase else {
            return XCTFail("Expected a succeeded phase, got \(phase)")
        }
        XCTAssertEqual(
            summary.libraryMessage,
            "This exact package is already in ZynSign's library, so it was not added again."
        )
        XCTAssertEqual(intake.staged.count, 2)
        XCTAssertEqual(intake.discarded, [intake.staged[1]])
        XCTAssertEqual(artifacts.held, [intake.staged[0]])
    }

    func testRejectedImportShowsFailureExplanation() async {
        let intake = SyntheticIntake()
        let model = makeModel(intake: intake, reader: ImportFixtures.emptyPayloadReader())

        model.beginImport(from: ImportFixtures.sourceURL())
        let phase = await awaitSettledPhase(of: model)

        guard case .failed(let message) = phase else {
            return XCTFail("Expected a failed phase, got \(phase)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(message, "No application was found inside the package.")
        // The staged archive of a rejected import was already discarded by
        // the use case, and the model retains nothing.
        XCTAssertEqual(intake.discarded.count, 1)
    }

    func testStagingFailureShowsTheTypedUserMessage() async {
        let intake = SyntheticIntake()
        intake.behaviour = .fails
        let model = makeModel(intake: intake, reader: ImportFixtures.validReader())

        model.beginImport(from: ImportFixtures.sourceURL())
        let phase = await awaitSettledPhase(of: model)

        guard case .failed(let message) = phase else {
            return XCTFail("Expected a failed phase, got \(phase)")
        }
        XCTAssertEqual(message, ZynSignError.selectedFileUnavailable().userMessage)
    }

    func testCancelledImportShowsTheCancelledPhase() async {
        let intake = SyntheticIntake()
        intake.behaviour = .waitsUntilCancelledThenFails
        let model = makeModel(intake: intake, reader: ImportFixtures.validReader())

        model.beginImport(from: ImportFixtures.sourceURL())
        model.cancelImport()

        let phase = await awaitSettledPhase(of: model)
        XCTAssertEqual(phase, .cancelled)
    }

    func testCancellingWhenNothingRunsDoesNotChangeThePhase() {
        let intake = SyntheticIntake()
        let model = makeModel(intake: intake, reader: ImportFixtures.validReader())

        model.cancelImport()
        XCTAssertEqual(model.phase, .idle)
    }

    func testPickerCancellationIsNotAnError() {
        let intake = SyntheticIntake()
        let model = makeModel(intake: intake, reader: ImportFixtures.validReader())

        model.handlePickerResult(.failure(ZynSignError.importCancelled()))

        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertTrue(intake.attempted.isEmpty)
    }

    // MARK: - Library storage

    func testImportingAgainAfterSuccessKeepsBothRecordedArchives() async {
        let intake = SyntheticIntake()
        let model = makeModel(intake: intake, reader: ImportFixtures.validReader())

        model.beginImport(from: ImportFixtures.sourceURL())
        _ = await awaitSettledPhase(of: model)

        // A second import of different content replaces the shown result
        // but not the library's holdings: the model owns no archive.
        intake.nextStagedContent = Data("different package content".utf8)
        model.beginImport(from: ImportFixtures.sourceURL(name: "Other.ipa"))
        _ = await awaitSettledPhase(of: model)

        guard case .succeeded = model.phase else {
            return XCTFail("Expected the second import to succeed, got \(model.phase)")
        }
        XCTAssertEqual(intake.staged.count, 2)
        XCTAssertTrue(intake.discarded.isEmpty)
        XCTAssertEqual(artifacts.held, Set(intake.staged))
    }

    func testDroppingTheModelLeavesTheLibraryUntouched() async {
        let intake = SyntheticIntake()
        weak var weakModel: PackageImportModel?

        do {
            let model = makeModel(intake: intake, reader: ImportFixtures.validReader())
            weakModel = model
            model.beginImport(from: ImportFixtures.sourceURL())
            _ = await awaitSettledPhase(of: model)
        }

        // The import task releases the model shortly after the phase
        // settles; give it a bounded number of main-actor turns to do so.
        var spins = 0
        while weakModel != nil {
            spins += 1
            if spins > 10_000 {
                XCTFail("The model was never released.")
                break
            }
            await Task.yield()
        }
        XCTAssertNil(weakModel)
        XCTAssertTrue(intake.discarded.isEmpty)
        XCTAssertEqual(artifacts.held, Set(intake.staged))
    }

    // MARK: - Rendering rules

    func testSummaryIsDerivedFromDeclaredMetadataAndTheAdmission() {
        let artifact = LibraryFixtures.acceptedArtifact()
        let record = LibraryFixtures.record()

        let summary = PackageImportModel.summary(
            for: PackageImportResult(artifact: artifact, admission: .recorded(record, relation: .unrelated))
        )
        XCTAssertEqual(summary.sourceFileName, "Example.ipa")
        XCTAssertEqual(summary.displayName, "Example")
        XCTAssertEqual(summary.bundleIdentifier, "com.example.synthetic")
        XCTAssertEqual(summary.marketingVersion, "1.2")
        XCTAssertEqual(summary.buildVersion, "34")
        XCTAssertEqual(summary.libraryMessage, "The package was added to ZynSign's library.")
    }

    func testLibraryMessageDescribesEachAdmissionOutcome() {
        let record = LibraryFixtures.record()
        let other = LibraryFixtures.record()

        XCTAssertEqual(
            PackageImportModel.libraryMessage(for: .recorded(record, relation: .unrelated)),
            "The package was added to ZynSign's library."
        )
        XCTAssertEqual(
            PackageImportModel.libraryMessage(for: .recorded(record, relation: .otherVersions([other]))),
            "The package was added to ZynSign's library alongside one other version of this application."
        )
        XCTAssertEqual(
            PackageImportModel.libraryMessage(for: .recorded(record, relation: .otherVersions([other, other]))),
            "The package was added to ZynSign's library alongside 2 other versions of this application."
        )
        XCTAssertEqual(
            PackageImportModel.libraryMessage(for: .recorded(record, relation: .sameDeclaredVersion([other]))),
            "The package was added to ZynSign's library. An earlier import declares the same version and build but has different content; both are kept."
        )
        XCTAssertEqual(
            PackageImportModel.libraryMessage(for: .alreadyRecorded(existing: other)),
            "This exact package is already in ZynSign's library, so it was not added again."
        )
        XCTAssertEqual(
            PackageImportModel.libraryMessage(for: nil),
            "The package was not added to ZynSign's library."
        )
    }

    func testRejectionMessageIsComposedFromThePrimaryFinding() {
        var artifact = IPAArtifact(sourceFileName: "Example.ipa")
        artifact = artifact.examined(
            bundle: nil,
            validation: .invalid(findings: [
                ValidationFinding(severity: .error, code: .missingPayloadDirectory, detail: "synthetic detail"),
            ])
        )

        XCTAssertEqual(
            PackageImportModel.rejectionMessage(for: artifact),
            "No application was found inside the package."
        )
    }

    // MARK: - Settlement hook

    func testTheSettlementHookReportsAPickerCancellationExactlyOnce() {
        var settlements: [PackageImportModel.Phase] = []
        let intake = SyntheticIntake()
        let model = PackageImportModel(importing: IPAPackageImport(
            intake: intake,
            readerProvider: SyntheticArchiveReaderProvider.providing(ImportFixtures.validReader()),
            library: library
        ))
        model.onSettlement = { settlements.append($0) }

        struct PickerFailure: Error {}
        model.handlePickerResult(.failure(PickerFailure()))

        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertEqual(settlements, [.cancelled])
    }

    func testTheSettlementHookReportsASuccessfulImportExactlyOnce() async {
        var settlements: [PackageImportModel.Phase] = []
        let intake = SyntheticIntake()
        intake.artifactStore = artifacts
        let model = PackageImportModel(importing: IPAPackageImport(
            intake: intake,
            readerProvider: SyntheticArchiveReaderProvider.providing(ImportFixtures.validReader()),
            library: library
        ))
        model.onSettlement = { settlements.append($0) }

        model.beginImport(from: ImportFixtures.sourceURL())
        var spins = 0
        while case .importing = model.phase {
            spins += 1
            if spins > 10_000 {
                XCTFail("The import phase never settled.")
                break
            }
            await Task.yield()
        }

        guard case .succeeded(let summary) = model.phase else {
            return XCTFail("Expected a succeeded phase, got \(model.phase)")
        }
        XCTAssertEqual(settlements, [.succeeded(summary)])
        XCTAssertEqual(summary.libraryMessage, "The package was added to ZynSign's library.")
    }
}
