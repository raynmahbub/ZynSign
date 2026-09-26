import XCTest
@testable import ZynSign

/// Tests for the signing queue's vocabulary: stage weights, priorities,
/// retryability, durations, estimates, stage rows, and the sentences
/// VoiceOver reads. Pure mappings, tested without a running queue.
final class SigningQueueRenderingTests: XCTestCase {

    // MARK: - Helpers

    private func job(
        state: SigningJobState,
        stage: SigningJobStage? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        attemptCount: Int = 1,
        cancellationRequested: Bool = false
    ) -> SigningQueue.Job {
        SigningQueue.Job(
            id: SigningJobIdentifier(),
            recordID: ApplicationRecordIdentifier(),
            artifactID: ArtifactIdentifier(),
            applicationName: "MyApp",
            bundleIdentifier: "com.example.myapp",
            versionText: "Version 1.0",
            priority: .normal,
            origin: .library,
            enqueuedAt: SigningQueueFixtures.fixedDate,
            startedAt: startedAt,
            finishedAt: finishedAt,
            attemptCount: attemptCount,
            state: state,
            progress: stage.map { SigningJobProgress(stage: $0) },
            cancellationRequested: cancellationRequested,
            log: [],
            hasRunnableSetup: true,
            identityDisplayName: nil,
            certificateFingerprint: nil,
            profileDisplayName: nil,
            profileTeamIdentifier: nil,
            emitDEREntitlements: false
        )
    }

    // MARK: - Stages

    func testStageWeightsAddUpToOneAndFractionsIncreaseInOrder() {
        XCTAssertEqual(SigningJobStage.totalWeight, 1, accuracy: 0.0001)
        let starts = SigningJobStage.ordered.map(\.startingFraction)
        XCTAssertEqual(starts.first ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(SigningJobStage.completed.startingFraction, 1, accuracy: 0.0001)
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            XCTAssertLessThan(earlier, later)
        }
        XCTAssertEqual(SigningJobStage.workStageCount, 7)
    }

    func testWithinStageProgressIsClampedToItsStage() {
        let over = SigningJobProgress(stage: .extraction, completedUnitCount: 20, totalUnitCount: 10)
        XCTAssertEqual(over.fractionCompleted, SigningJobStage.signingFrameworks.startingFraction, accuracy: 0.0001)
        let none = SigningJobProgress(stage: .extraction, completedUnitCount: -3)
        XCTAssertFalse(none.isDeterminate)
        XCTAssertEqual(none.fractionCompleted, SigningJobStage.extraction.startingFraction, accuracy: 0.0001)
    }

    func testPrioritiesSortHighNormalLow() {
        XCTAssertEqual([SigningJobPriority.low, .high, .normal].sorted(), [.high, .normal, .low])
        XCTAssertEqual(SigningJobPriority.high.purposeText, "Urgent")
        XCTAssertEqual(SigningJobPriority.normal.purposeText, "Default")
        XCTAssertEqual(SigningJobPriority.low.purposeText, "Background")
    }

    func testOnlyNonContentFailuresAreRetryable() {
        XCTAssertFalse(SigningJobFailure.isRetryable(category: .invalidInput))
        XCTAssertFalse(SigningJobFailure.isRetryable(category: .unsupportedInput))
        XCTAssertFalse(SigningJobFailure.isRetryable(category: .ambiguousInput))
        XCTAssertTrue(SigningJobFailure.isRetryable(category: .storageFailure))
        XCTAssertTrue(SigningJobFailure.isRetryable(category: .internalFailure))
        XCTAssertTrue(SigningJobFailure.isRetryable(category: .capabilityUnavailable))
    }

    func testStatesRoundTripThroughCodable() throws {
        let states: [SigningJobState] = [
            .queued, .running, .cancelled,
            .completed(SigningQueueFixtures.completion()),
            .failed(SigningQueueFixtures.failure()),
        ]
        let data = try JSONEncoder().encode(states)
        XCTAssertEqual(try JSONDecoder().decode([SigningJobState].self, from: data), states)
    }

    // MARK: - Durations and estimates

    func testDurationsAreCompactAndNeverNegative() {
        XCTAssertEqual(SigningQueueRendering.durationText(-5), "0s")
        XCTAssertEqual(SigningQueueRendering.durationText(.infinity), "0s")
        XCTAssertFalse(SigningQueueRendering.durationText(42).isEmpty)
        XCTAssertFalse(SigningQueueRendering.durationText(3_725).isEmpty)
    }

    func testWaitingJobsReadAsTheirPlaceInLine() {
        let waiting = job(state: .queued, attemptCount: 0)
        let now = SigningQueueFixtures.fixedDate
        XCTAssertEqual(SigningQueueRendering.remainingWorkText(for: waiting, waitingPosition: 0, now: now), "Runs next")
        XCTAssertEqual(SigningQueueRendering.remainingWorkText(for: waiting, waitingPosition: 1, now: now), "Runs after 1 job")
        XCTAssertEqual(SigningQueueRendering.remainingWorkText(for: waiting, waitingPosition: 3, now: now), "Runs after 3 jobs")
    }

    func testARunningJobOnlyGetsATimeEstimateOnceOneIsHonest() {
        let start = SigningQueueFixtures.fixedDate
        let early = job(state: .running, stage: .preparing, startedAt: start)
        XCTAssertEqual(
            SigningQueueRendering.remainingWorkText(for: early, waitingPosition: nil, now: start.addingTimeInterval(1)),
            "Stage 1 of 7",
            "With nothing measured, the stage position is the honest estimate"
        )
        let later = job(state: .running, stage: .signingFrameworks, startedAt: start)
        let text = SigningQueueRendering.remainingWorkText(for: later, waitingPosition: nil, now: start.addingTimeInterval(36)) ?? ""
        XCTAssertTrue(text.hasPrefix("~"), text)
        XCTAssertTrue(text.contains("stage 4 of 7"), text)
    }

    func testSettledJobsReadAsWhatTheyTookOrWhereTheyStopped() {
        let start = SigningQueueFixtures.fixedDate
        let completed = job(state: .completed(SigningQueueFixtures.completion()), startedAt: start, finishedAt: start.addingTimeInterval(90))
        XCTAssertTrue(SigningQueueRendering.remainingWorkText(for: completed, waitingPosition: nil, now: start)?.hasPrefix("Took") ?? false)
        let failed = job(state: .failed(SigningQueueFixtures.failure(stage: .packaging)))
        XCTAssertEqual(SigningQueueRendering.remainingWorkText(for: failed, waitingPosition: nil, now: start), "Stopped at Packaging")
    }

    // MARK: - Stage rows

    func testStageRowsMarkCompleteCurrentAndPendingFromTheStageReached() {
        let running = job(state: .running, stage: .signingFrameworks, startedAt: SigningQueueFixtures.fixedDate)
        let rows = SigningQueueRendering.stageRows(for: running)
        XCTAssertEqual(rows.map(\.stage), SigningJobStage.ordered.filter { $0 != .completed })
        XCTAssertEqual(rows.map(\.status), [.complete, .complete, .complete, .current, .pending, .pending, .pending])
        XCTAssertNil(rows[3].stageFraction, "A stage reported by boundary alone is indeterminate, never a made-up percentage")
    }

    func testAFailedJobsRowsStopAtTheFailingStage() {
        let failed = job(state: .failed(SigningQueueFixtures.failure(stage: .packaging)), stage: .packaging)
        let statuses = SigningQueueRendering.stageRows(for: failed).map(\.status)
        XCTAssertEqual(statuses, [.complete, .complete, .complete, .complete, .complete, .stopped, .pending])
    }

    func testACompletedJobShowsEveryStageDoneAndAWaitingJobNone() {
        let completed = job(state: .completed(SigningQueueFixtures.completion()), stage: .completed)
        XCTAssertTrue(SigningQueueRendering.stageRows(for: completed).allSatisfy { $0.status == .complete })
        let waiting = job(state: .queued, attemptCount: 0)
        XCTAssertTrue(SigningQueueRendering.stageRows(for: waiting).allSatisfy { $0.status == .pending })
    }

    // MARK: - Accessibility

    func testTheCardIsReadAsOneSentence() {
        let running = job(state: .running, stage: .signingApp, startedAt: SigningQueueFixtures.fixedDate, attemptCount: 2)
        let sentence = SigningQueueRendering.accessibilityDescription(for: running, waitingPosition: nil, now: SigningQueueFixtures.fixedDate)
        XCTAssertTrue(sentence.hasPrefix("MyApp, Signing App, "), sentence)
        XCTAssertTrue(sentence.contains("percent"), sentence)
        XCTAssertTrue(sentence.contains("attempt 2"), sentence)

        let cancelling = job(state: .running, stage: .signingApp, startedAt: SigningQueueFixtures.fixedDate, cancellationRequested: true)
        XCTAssertTrue(
            SigningQueueRendering.accessibilityDescription(for: cancelling, waitingPosition: nil, now: SigningQueueFixtures.fixedDate)
                .contains("cancelling")
        )
    }

    func testAnnouncementsReadTitleThenMessage() {
        let notice = SigningQueueNotice(kind: .jobCompleted, title: "MyApp signed", message: "Delivered.", createdAt: SigningQueueFixtures.fixedDate)
        XCTAssertEqual(SigningQueueRendering.announcement(for: notice), "MyApp signed. Delivered.")
    }
}
