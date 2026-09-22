import XCTest
@testable import ZynSign

/// Tests for the import presentation model's phase machine and its
/// staged-archive ownership.
///
/// The model is exercised with the real import use case over synthetic
/// ports, so the phases it renders are the phases the application layer
/// actually produces.
@MainActor
final class PackageImportModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeModel(
        intake: SyntheticIntake,
        reader: any ArchiveReader
    ) -> PackageImportModel {
        PackageImportModel(
            importing: IPAPackageImport(
                intake: intake,
                readerProvider: SyntheticArchiveReaderProvider.providing(reader)
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

    func testSuccessfulImportShowsSummaryAndRetainsTheStagedArchive() async {
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
        XCTAssertTrue(intake.discarded.isEmpty)
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

    // MARK: - Staged-archive ownership

    func testImportingAgainAfterSuccessReleasesTheReplacedArchive() async {
        let intake = SyntheticIntake()
        let model = makeModel(intake: intake, reader: ImportFixtures.validReader())

        model.beginImport(from: ImportFixtures.sourceURL())
        _ = await awaitSettledPhase(of: model)
        let firstStaged = intake.staged

        // A second successful import replaces the first result.
        model.beginImport(from: ImportFixtures.sourceURL(name: "Other.ipa"))
        _ = await awaitSettledPhase(of: model)

        guard case .succeeded = model.phase else {
            return XCTFail("Expected the second import to succeed, got \(model.phase)")
        }
        XCTAssertEqual(intake.staged.count, 2)
        XCTAssertEqual(intake.discarded.map { $0.rawValue }, [firstStaged[0].rawValue])
    }

    func testDroppingTheModelReleasesTheRetainedArchive() async {
        let intake = SyntheticIntake()
        weak var weakModel: PackageImportModel?

        do {
            let model = makeModel(intake: intake, reader: ImportFixtures.validReader())
            weakModel = model
            model.beginImport(from: ImportFixtures.sourceURL())
            _ = await awaitSettledPhase(of: model)
            XCTAssertTrue(intake.discarded.isEmpty)
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
        XCTAssertEqual(intake.discarded.count, 1)
    }

    // MARK: - Rendering rules

    func testSummaryIsDerivedFromDeclaredMetadata() {
        var artifact = IPAArtifact(sourceFileName: "Example.ipa")
        let identity = ApplicationIdentity(
            bundleIdentifier: BundleIdentifier(rawValue: "com.example.synthetic")!,
            displayName: "Example",
            shortVersionString: "1.2",
            buildVersion: "34"
        )
        artifact = artifact.metadataExamined(
            bundle: nil,
            metadata: ApplicationMetadata(identity: identity),
            validation: .valid()
        )

        let summary = PackageImportModel.summary(for: artifact)
        XCTAssertEqual(summary.sourceFileName, "Example.ipa")
        XCTAssertEqual(summary.displayName, "Example")
        XCTAssertEqual(summary.bundleIdentifier, "com.example.synthetic")
        XCTAssertEqual(summary.marketingVersion, "1.2")
        XCTAssertEqual(summary.buildVersion, "34")
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
}
