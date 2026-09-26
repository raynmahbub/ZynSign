import XCTest
@testable import ZynSign

/// Tests for the queue's stage vocabulary, remaining-work estimates, and the
/// storage check made before every working copy.
final class ImportQueueStageTests: XCTestCase {

    // MARK: - Stages

    func testTheQueueShowsTheSevenStagesInOrder() {
        XCTAssertEqual(ImportQueueStage.allCases.map(\.displayName), [
            "Waiting", "Preparing", "Validating", "Analyzing", "Importing", "Complete", "Failed",
        ])
        XCTAssertEqual(ImportQueueStage.track, [.waiting, .preparing, .validating, .analyzing, .importing, .complete])
    }

    func testPipelineStagesMapOntoQueueStages() {
        XCTAssertEqual(ImportQueueStage.stage(for: .preparing), .preparing)
        XCTAssertEqual(ImportQueueStage.stage(for: .copying), .preparing)
        XCTAssertEqual(ImportQueueStage.stage(for: .examiningStructure), .validating)
        XCTAssertEqual(ImportQueueStage.stage(for: .examiningMetadata), .analyzing)
        XCTAssertEqual(ImportQueueStage.stage(for: .checkingForDuplicates), .analyzing)
        XCTAssertEqual(ImportQueueStage.stage(for: .storing), .importing)
        XCTAssertEqual(ImportQueueStage.stage(for: .finished), .complete)
    }

    func testRemainingStepsCountTheWorkStillAhead() {
        XCTAssertEqual(ImportQueueStage.waiting.remainingStepCount, 4)
        XCTAssertEqual(ImportQueueStage.preparing.remainingStepCount, 3)
        XCTAssertEqual(ImportQueueStage.analyzing.remainingStepCount, 1)
        XCTAssertEqual(ImportQueueStage.importing.remainingStepCount, 0)
        XCTAssertEqual(ImportQueueStage.complete.remainingStepCount, 0)
        XCTAssertEqual(ImportQueueStage.failed.remainingStepCount, 0)
        XCTAssertTrue(ImportQueueStage.failed.isTerminal)
        XCTAssertFalse(ImportQueueStage.importing.isTerminal)
    }

    // MARK: - Remaining work

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testNoTimeIsEstimatedBeforeACopyHasEstablishedItsRate() {
        let early = ImportRemainingEstimate.estimate(
            stage: .preparing,
            progress: ImportProgress(stage: .copying, completedUnitCount: 10, totalUnitCount: 1_000),
            transferStartedAt: start,
            now: start.addingTimeInterval(5)
        )
        XCTAssertNil(early.remainingSeconds, "1% done is not enough to extrapolate from.")
        XCTAssertEqual(early.remainingBytes, 990)

        let immediate = ImportRemainingEstimate.estimate(
            stage: .preparing,
            progress: ImportProgress(stage: .copying, completedUnitCount: 500, totalUnitCount: 1_000),
            transferStartedAt: start,
            now: start.addingTimeInterval(0.5)
        )
        XCTAssertNil(immediate.remainingSeconds, "Half a second is not enough to extrapolate from.")
    }

    func testAnEstablishedCopyEstimatesTheTimeLeftFromItsRate() throws {
        let estimate = ImportRemainingEstimate.estimate(
            stage: .preparing,
            progress: ImportProgress(stage: .copying, completedUnitCount: 250, totalUnitCount: 1_000),
            transferStartedAt: start,
            now: start.addingTimeInterval(10)
        )
        XCTAssertEqual(try XCTUnwrap(estimate.remainingSeconds), 30, accuracy: 0.001)
        XCTAssertEqual(estimate.remainingBytes, 750)
        XCTAssertEqual(estimate.remainingSteps, 3)
    }

    func testWorkWithoutAMeasurableRateOnlyCountsSteps() {
        let estimate = ImportRemainingEstimate.estimate(
            stage: .analyzing,
            progress: ImportProgress(stage: .checkingForDuplicates),
            transferStartedAt: start,
            now: start.addingTimeInterval(60)
        )
        XCTAssertEqual(estimate, ImportRemainingEstimate(remainingSteps: 1, remainingBytes: nil, remainingSeconds: nil))
    }

    // MARK: - Storage

    func testAWorkingCopyNeedsItsSizePlusHeadroomAndEveryConcurrentClaim() {
        let size = 500 * 1_024 * 1_024
        let reserved = 200 * 1_024 * 1_024
        let required = ImportStoragePolicy.requiredBytes(forWorkingCopyOf: size, reservedBytes: reserved)
        XCTAssertEqual(required, size + reserved + ImportStoragePolicy.headroomBytes)

        XCTAssertEqual(ImportStoragePolicy.verdict(forWorkingCopyOf: size, reservedBytes: reserved, availableBytes: required), .sufficient)
        XCTAssertEqual(
            ImportStoragePolicy.verdict(forWorkingCopyOf: size, reservedBytes: reserved, availableBytes: required - 1),
            .insufficient(requiredBytes: required, availableBytes: required - 1)
        )
    }

    func testAnUnknownCapacityIsNotAShortage() {
        let verdict = ImportStoragePolicy.verdict(forWorkingCopyOf: 10, reservedBytes: 0, availableBytes: nil)
        XCTAssertEqual(verdict, .unknown)
        XCTAssertTrue(verdict.permitsCopy)
    }

    func testRequiredBytesNeverOverflow() {
        XCTAssertEqual(ImportStoragePolicy.requiredBytes(forWorkingCopyOf: Int.max, reservedBytes: Int.max), Int.max)
    }

    func testTheGuardAccountsForCopiesThatAreStillRunning() throws {
        let headroom = ImportStoragePolicy.headroomBytes
        let guardian = ImportStorageGuard(probe: FixedStorageCapacityProbe(capacity: headroom + 1_000))

        let first = try guardian.reserve(byteCount: 600)
        XCTAssertEqual(guardian.reservedByteCount, 600)
        XCTAssertThrowsError(try guardian.reserve(byteCount: 600), "Two 600-byte copies do not fit in 1,000 bytes.") { error in
            XCTAssertEqual((error as? ImportFailure)?.recovery, .freeStorage)
        }

        guardian.release(first)
        XCTAssertEqual(guardian.reservedByteCount, 0)
        XCTAssertNoThrow(try guardian.reserve(byteCount: 600))
    }

    func testTheGuardPermitsCopiesWhenCapacityIsUnknown() {
        let guardian = ImportStorageGuard(probe: nil)
        XCTAssertNoThrow(try guardian.reserve(byteCount: Int.max / 2))
        XCTAssertNil(guardian.availableCapacity())
    }

    func testTheShortageExplanationStatesWhatIsNeeded() {
        let failure = ImportFailure.insufficientStorage(requiredBytes: 2_000_000_000, availableBytes: 500_000_000)
        XCTAssertEqual(failure.title, "Not Enough Space")
        XCTAssertEqual(failure.category, .storageFailure)
        XCTAssertTrue(failure.message.contains(ByteCountFormatter.string(fromByteCount: 2_000_000_000, countStyle: .file)))
        XCTAssertTrue(failure.message.contains("Nothing was copied"))
    }
}
