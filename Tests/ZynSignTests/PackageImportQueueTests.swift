import XCTest
@testable import ZynSign

/// Tests for the import queue: what it accepts, the order it runs things in,
/// what it shows while they run, and how each job can end.
///
/// The import capability underneath the queue is a double, because none of
/// this is about reading archives or storing files — it is about the
/// promises the queue makes to the person using it: one thing at a time in
/// the order they asked, progress that only ever moves forwards, a question
/// that stores nothing until it is answered, a retry only where a retry can
/// change the outcome, and a list they can clear without clearing anything
/// else.
@MainActor
final class PackageImportQueueTests: XCTestCase {

    private var importer: SyntheticImporting!
    private var queue: PackageImportQueue!

    override func setUp() {
        super.setUp()
        importer = SyntheticImporting()
        queue = PackageImportQueue(
            importing: importer,
            now: { Date(timeIntervalSinceReferenceDate: 750_000_000) }
        )
    }

    override func tearDown() {
        importer = nil
        queue = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func source(_ name: String) -> URL {
        ImportFixtures.sourceURL(name: name)
    }

    /// An accepted import for a package the library recorded.
    private func recordedResult(
        sourceFileName: String = "Example.ipa",
        identity: ApplicationIdentity = LibraryFixtures.identity()
    ) -> PackageImportResult {
        let record = LibraryFixtures.record(identity: identity, sourceFileName: sourceFileName)
        return PackageImportResult(
            artifact: LibraryFixtures.acceptedArtifact(sourceFileName: sourceFileName, identity: identity),
            admission: .recorded(record, relation: .unrelated)
        )
    }

    /// A comparison against one existing record, as the library would produce.
    private func duplicateReport(
        kind: DuplicateMatchKind = .sameVersionAndBuild
    ) -> DuplicateReport {
        DuplicateReport(
            candidateBundleIdentifier: LibraryFixtures.identity().bundleIdentifier,
            candidateMarketingVersion: "1.2",
            candidateBuildVersion: "34",
            candidateByteCount: 1_024,
            candidateFingerprint: LibraryFixtures.fingerprint(seed: 0x01),
            matches: [
                DuplicateMatch(
                    record: LibraryFixtures.record(),
                    kind: kind,
                    evidence: [.bundleIdentifier(LibraryFixtures.identity().bundleIdentifier)]
                ),
            ]
        )
    }

    /// Waits for a condition the queue reaches asynchronously.
    @discardableResult
    private func wait(until condition: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// Waits until the queue holds no active jobs.
    @discardableResult
    private func waitUntilIdle() async -> Bool {
        await wait { !self.queue.isBusy }
    }

    // MARK: - Ordering

    func testJobsRunOneAtATimeInTheOrderTheyWereEnqueued() async {
        importer.enqueue([
            .succeeds(recordedResult(sourceFileName: "First.ipa")),
            .succeeds(recordedResult(sourceFileName: "Second.ipa")),
            .succeeds(recordedResult(sourceFileName: "Third.ipa")),
        ])

        let ids = queue.enqueue(
            [source("First.ipa"), source("Second.ipa"), source("Third.ipa")],
            origin: .documentPicker
        )
        XCTAssertEqual(queue.jobs.map(\.id), ids)
        XCTAssertEqual(queue.jobs.map(\.origin), [.documentPicker, .documentPicker, .documentPicker])

        await waitUntilIdle()

        XCTAssertEqual(
            importer.startedSources.map(\.lastPathComponent),
            ["First.ipa", "Second.ipa", "Third.ipa"]
        )
        XCTAssertEqual(queue.settledJobs.count, 3)
        XCTAssertTrue(queue.settledJobs.allSatisfy { $0.settlement?.kind == .imported })
        XCTAssertEqual(queue.summary.importedCount, 3)
        XCTAssertEqual(queue.summary.addedCount, 3)
    }

    func testAJobWaitsItsTurnWhileAnEarlierJobIsStillRunning() async {
        importer.enqueue([
            .asksForDecision(duplicateReport(), then: recordedResult()),
            .succeeds(recordedResult(sourceFileName: "Second.ipa")),
        ])

        queue.enqueue(source("First.ipa"), origin: .shareSheet)
        queue.enqueue(source("Second.ipa"), origin: .dragAndDrop)

        XCTAssertTrue(await wait { self.queue.jobAwaitingDecision != nil })
        // The second job is held, not started: exactly one import runs at a
        // time, whatever the queue is holding.
        XCTAssertEqual(queue.activeJobs.count, 2)
        XCTAssertEqual(queue.jobs[1].state, .queued)
        XCTAssertEqual(importer.startedSources.map(\.lastPathComponent), ["First.ipa"])

        let waitingID = queue.jobs[0].id
        queue.resolveDuplicate(waitingID, with: .keepBoth)
        await waitUntilIdle()

        XCTAssertEqual(
            importer.startedSources.map(\.lastPathComponent),
            ["First.ipa", "Second.ipa"]
        )
    }

    // MARK: - Progress

    func testProgressNeverMovesBackwardsWhenReportsArriveOutOfOrder() async {
        let total = 1_000
        importer.enqueue([
            .reportsProgress(
                [
                    ImportProgress(stage: .copying, completedUnitCount: 500, totalUnitCount: total),
                    ImportProgress(stage: .copying, completedUnitCount: 100, totalUnitCount: total),
                    ImportProgress(stage: .examiningStructure),
                    ImportProgress(stage: .copying, completedUnitCount: 750, totalUnitCount: total),
                ],
                recordedResult()
            ),
        ])

        let id = queue.enqueue(source("Example.ipa"), origin: .documentPicker)
        await waitUntilIdle()

        let job = queue.jobs.first { $0.id == id }
        XCTAssertEqual(job?.byteCount, total)
        // The regression was dropped, so the last observation stands rather
        // than the import appearing to undo work it had already done.
        XCTAssertEqual(job?.progress?.completedUnitCount, total)
        XCTAssertEqual(job?.fractionCompleted, 1)
    }

    func testAByteCountIsReportedOnlyOnceItHasBeenMeasured() async {
        importer.enqueue([
            .reportsProgress([ImportProgress(stage: .preparing)], recordedResult()),
        ])

        queue.enqueue(source("Example.ipa"), origin: .documentPicker)
        await waitUntilIdle()

        XCTAssertNil(queue.settledJobs.first?.byteCount)
        XCTAssertEqual(queue.summary.byteCount, 0)
    }

    // MARK: - Cancelling

    func testCancellingAQueuedJobSettlesItWithoutStartingIt() async {
        importer.enqueue([
            .waitsUntilCancelled,
            .succeeds(recordedResult(sourceFileName: "Second.ipa")),
        ])

        let first = queue.enqueue(source("First.ipa"), origin: .documentPicker)
        let second = queue.enqueue(source("Second.ipa"), origin: .documentPicker)

        XCTAssertTrue(await wait { self.importer.startedSources.count == 1 })
        queue.cancel(second)

        XCTAssertEqual(queue.jobs.first { $0.id == second }?.settlement?.kind, .cancelled)
        XCTAssertEqual(importer.startedSources.map(\.lastPathComponent), ["First.ipa"])

        // The running job is unaffected by its neighbour's cancellation: the
        // queue settles it on its own terms, and never starts the job the
        // user withdrew.
        queue.cancel(first)
        await waitUntilIdle()
        XCTAssertEqual(queue.settledJobs.count, 2)
        XCTAssertEqual(importer.startedSources.map(\.lastPathComponent), ["First.ipa"])
    }

    func testCancellingTheRunningJobSettlesItAsCancelledAndOffersARetry() async {
        importer.enqueue([.waitsUntilCancelled, .succeeds(recordedResult())])

        let id = queue.enqueue(source("Example.ipa"), origin: .documentPicker)
        XCTAssertTrue(await wait { self.importer.startedSources.count == 1 })

        queue.cancel(id)
        XCTAssertTrue(await wait { self.queue.jobs.first { $0.id == id }?.state.isSettled == true })

        XCTAssertEqual(queue.jobs[0].settlement?.kind, .cancelled)
        XCTAssertEqual(queue.jobs[0].settlement?.isRetryable, true)

        queue.retry(id)
        await waitUntilIdle()

        XCTAssertEqual(importer.startedSources.count, 2)
        XCTAssertEqual(queue.jobs[0].settlement?.kind, .imported)
    }

    func testCancelAllCancelsEveryActiveJob() async {
        importer.enqueue([.waitsUntilCancelled, .waitsUntilCancelled])

        queue.enqueue([source("First.ipa"), source("Second.ipa")], origin: .documentPicker)
        XCTAssertTrue(await wait { self.importer.startedSources.count == 1 })

        queue.cancelAll()
        await waitUntilIdle()

        XCTAssertTrue(queue.jobs.allSatisfy { $0.settlement?.kind == .cancelled })
        // Only the job that was running had started; the queued one was
        // cancelled outright and never opened.
        XCTAssertEqual(importer.startedSources.count, 1)
    }

    // MARK: - Failure and retry

    func testARetryableFailureOffersARetryAndTheSameFileIsReadAgain() async {
        importer.enqueue([
            .fails(ZynSignError.importCopyFailure(diagnosticDetail: "synthetic storage failure")),
            .succeeds(recordedResult()),
        ])

        let id = queue.enqueue(source("Example.ipa"), origin: .documentPicker)
        await waitUntilIdle()

        XCTAssertEqual(queue.jobs[0].settlement?.kind, .failed)
        XCTAssertEqual(queue.jobs[0].settlement?.isRetryable, true)
        XCTAssertEqual(queue.jobs[0].settlement?.failure?.recovery, .retry)

        queue.retry(id)
        await waitUntilIdle()

        XCTAssertEqual(importer.startedSources, [source("Example.ipa"), source("Example.ipa")])
        XCTAssertEqual(queue.jobs[0].settlement?.kind, .imported)
    }

    func testARefusalIsNotRetryable() async {
        importer.enqueue([
            .fails(ZynSignError.unsupportedImportFile(diagnosticDetail: "synthetic refusal")),
        ])

        let id = queue.enqueue(source("Example.ipa"), origin: .documentPicker)
        await waitUntilIdle()

        XCTAssertEqual(queue.jobs[0].settlement?.kind, .rejected)
        XCTAssertEqual(queue.jobs[0].settlement?.isRetryable, false)
        XCTAssertEqual(queue.jobs[0].settlement?.failure?.recovery, .chooseAnotherFile)

        queue.retry(id)
        await waitUntilIdle()

        // A refusal cannot be retried: re-reading an unchanged file cannot
        // change what it declares, so the queue does not offer a second look.
        XCTAssertEqual(importer.startedSources.count, 1)
        XCTAssertEqual(queue.jobs[0].settlement?.kind, .rejected)
    }

    // MARK: - The duplicate question

    func testAJobWaitingOnTheDuplicateQuestionStoresNothingUntilItIsAnswered() async {
        let report = duplicateReport()
        importer.enqueue([.asksForDecision(report, then: recordedResult())])

        let id = queue.enqueue(source("Example.ipa"), origin: .documentPicker)
        XCTAssertTrue(await wait { self.queue.jobAwaitingDecision != nil })

        let job = queue.jobs[0]
        XCTAssertEqual(job.pendingDuplicateReport, report)
        XCTAssertEqual(job.state, .awaitingDuplicateDecision(report))
        XCTAssertEqual(job.statusText, "Waiting for your decision")
        XCTAssertFalse(job.state.isSettled)
        XCTAssertNil(job.settlement)
        // Nothing has settled, so nothing is counted as added.
        XCTAssertEqual(queue.summary.addedCount, 0)

        queue.resolveDuplicate(id, with: .keepBoth)
        await waitUntilIdle()

        XCTAssertEqual(importer.duplicateAnswers, [.keepBoth])
        XCTAssertEqual(queue.jobs[0].settlement?.kind, .imported)
        XCTAssertNil(queue.jobs[0].pendingDuplicateReport)
    }

    func testCancellingAtTheDuplicateQuestionSettlesAsCancelled() async {
        importer.enqueue([.asksForDecision(duplicateReport(), then: recordedResult())])

        let id = queue.enqueue(source("Example.ipa"), origin: .documentPicker)
        XCTAssertTrue(await wait { self.queue.jobAwaitingDecision != nil })

        queue.cancel(id)
        await waitUntilIdle()

        XCTAssertEqual(importer.duplicateAnswers, [.cancel])
        XCTAssertEqual(queue.jobs[0].settlement?.kind, .cancelled)
        XCTAssertEqual(queue.summary.importedCount, 0)
    }

    func testAnsweringAJobThatIsNotWaitingDoesNothing() async {
        let id = queue.enqueue(source("Example.ipa"), origin: .documentPicker)
        importer.enqueue([.succeeds(recordedResult())])
        await waitUntilIdle()

        queue.resolveDuplicate(id, with: .replaceExisting)

        XCTAssertEqual(importer.duplicateAnswers, [])
        XCTAssertEqual(queue.jobs[0].settlement?.kind, .imported)
    }

    func testAKeptBothOutcomeIsSettledAsKeptBothAndCountsAsAdded() async {
        let report = duplicateReport(kind: .identicalContent)
        let record = LibraryFixtures.record()
        let result = PackageImportResult(
            artifact: LibraryFixtures.acceptedArtifact(),
            admission: .recorded(record, relation: .sameDeclaredVersion([record])),
            duplicate: DuplicateOutcome(report: report, resolution: .keepBoth)
        )
        importer.enqueue([.asksForDecision(report, then: result)])

        let id = queue.enqueue(source("Example.ipa"), origin: .documentPicker)
        XCTAssertTrue(await wait { self.queue.jobAwaitingDecision != nil })
        queue.resolveDuplicate(id, with: .keepBoth)
        await waitUntilIdle()

        XCTAssertEqual(queue.jobs[0].settlement?.kind, .keptBoth)
        XCTAssertEqual(queue.summary.keptBothCount, 1)
        XCTAssertEqual(queue.summary.addedCount, 1)
        XCTAssertEqual(queue.summary.unsuccessfulCount, 0)
    }

    func testAReplacementReportsBothWhatItRemovedAndWhatItCouldNot() async {
        let report = duplicateReport()
        let match = report.decisiveMatches[0].record
        let result = PackageImportResult(
            artifact: LibraryFixtures.acceptedArtifact(),
            admission: .recorded(LibraryFixtures.record(), relation: .sameDeclaredVersion([match])),
            duplicate: DuplicateOutcome(
                report: report,
                resolution: .replaceExisting,
                replacedRecords: [match],
                retainedRecords: []
            )
        )
        importer.enqueue([.asksForDecision(report, then: result)])

        let id = queue.enqueue(source("Example.ipa"), origin: .documentPicker)
        XCTAssertTrue(await wait { self.queue.jobAwaitingDecision != nil })
        queue.resolveDuplicate(id, with: .replaceExisting)
        await waitUntilIdle()

        XCTAssertEqual(queue.jobs[0].settlement?.kind, .replaced)
        XCTAssertEqual(queue.jobs[0].settlement?.replacedRecords, [match])
        XCTAssertEqual(queue.summary.replacedCount, 1)
        XCTAssertEqual(queue.summary.addedCount, 1)
    }

    // MARK: - Removing

    func testRemovingASettledJobLeavesTheRestOfTheListAlone() async {
        importer.enqueue([
            .succeeds(recordedResult(sourceFileName: "First.ipa")),
            .succeeds(recordedResult(sourceFileName: "Second.ipa")),
        ])

        let ids = queue.enqueue(
            [source("First.ipa"), source("Second.ipa")],
            origin: .documentPicker
        )
        await waitUntilIdle()

        queue.remove(ids[0])
        XCTAssertEqual(queue.jobs.map(\.id), [ids[1]])
        // Removing a job removes only the request: nothing the import stored
        // is reachable from the queue, so nothing can be deleted this way.
        XCTAssertEqual(importer.startedSources.count, 2)
    }

    func testRemovingAnActiveJobIsRefused() async {
        importer.enqueue([.waitsUntilCancelled])

        let id = queue.enqueue(source("Example.ipa"), origin: .documentPicker)
        XCTAssertTrue(await wait { self.importer.startedSources.count == 1 })

        queue.remove(id)

        XCTAssertEqual(queue.jobs.count, 1)
        queue.cancel(id)
        await waitUntilIdle()
        XCTAssertEqual(queue.jobs.count, 1)
    }

    func testRemoveSettledLeavesActiveJobsInPlace() async {
        importer.enqueue([
            .succeeds(recordedResult(sourceFileName: "First.ipa")),
            .waitsUntilCancelled,
        ])

        let ids = queue.enqueue(
            [source("First.ipa"), source("Second.ipa")],
            origin: .documentPicker
        )
        XCTAssertTrue(await wait { self.queue.jobs.first { $0.id == ids[0] }?.state.isSettled == true })
        XCTAssertTrue(await wait { self.importer.startedSources.count == 2 })

        queue.removeSettled()
        XCTAssertEqual(queue.jobs.map(\.id), [ids[1]])
        XCTAssertTrue(queue.isBusy)

        queue.cancel(ids[1])
        await waitUntilIdle()
        XCTAssertTrue(queue.settledJobs.isEmpty)
    }

    // MARK: - Summary

    func testSummaryCountsWhatHappenedAndNothingElse() async {
        let report = duplicateReport()
        importer.enqueue([
            .succeeds(recordedResult(sourceFileName: "First.ipa")),
            .fails(ZynSignError.unsupportedImportFile(diagnosticDetail: "synthetic refusal")),
            .asksForDecision(report, then: PackageImportResult(
                artifact: LibraryFixtures.acceptedArtifact(),
                admission: .recorded(LibraryFixtures.record(), relation: .sameDeclaredVersion([])),
                duplicate: DuplicateOutcome(report: report, resolution: .keepBoth)
            )),
        ])

        let ids = queue.enqueue(
            [source("First.ipa"), source("Second.ipa"), source("Third.ipa")],
            origin: .documentPicker
        )
        XCTAssertTrue(await wait { self.queue.jobs.first { $0.id == ids[2] }?.pendingDuplicateReport != nil })
        queue.resolveDuplicate(ids[2], with: .keepBoth)
        await waitUntilIdle()

        let summary = queue.summary
        XCTAssertEqual(summary.scheduledCount, 3)
        XCTAssertEqual(summary.settledCount, 3)
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertEqual(summary.keptBothCount, 1)
        XCTAssertEqual(summary.rejectedCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(summary.cancelledCount, 0)
        XCTAssertEqual(summary.addedCount, 2)
        XCTAssertEqual(summary.unsuccessfulCount, 1)
        XCTAssertTrue(summary.hasWork)
        XCTAssertTrue(summary.isComplete)
    }

    func testAnEmptyQueueSummarizesNothing() {
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertEqual(queue.summary, .empty)
        XCTAssertNil(queue.jobAwaitingDecision)
        XCTAssertFalse(queue.isBusy)
    }
}
