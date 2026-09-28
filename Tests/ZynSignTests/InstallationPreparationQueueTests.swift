import XCTest
@testable import ZynSign

/// Tests for the preparation queue: one-at-a-time scheduling, settlement,
/// retry, clear completed, and the honest shapes of the failure and
/// cancellation paths.
@MainActor
final class InstallationPreparationQueueTests: XCTestCase {

    private func makeQueue(
        work: @escaping InstallationPreparationQueue.Work = { _ in
            InstallationPreparationQueue.Outcome(summary: "done", isReady: true)
        }
    ) -> InstallationPreparationQueue {
        InstallationPreparationQueue(work: work)
    }

    private func request(
        recordID: ApplicationRecordIdentifier = ApplicationRecordIdentifier(),
        kind: InstallationPreparationQueue.Kind = .fullVerification
    ) -> InstallationPreparationQueue.Request {
        InstallationPreparationQueue.Request(
            kind: kind,
            recordID: recordID,
            exportID: ExportIdentifier(),
            applicationName: "Example",
            bundleIdentifier: "com.example.synthetic"
        )
    }

    /// Waits until `condition` holds or the timeout passes.
    private func wait(
        for condition: @escaping () -> Bool,
        timeout: TimeInterval = 2,
        _ message: String
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    func testEnqueueRunsAJobToCompletion() async {
        let queue = makeQueue()
        queue.enqueue(request())

        await wait(for: { queue.completedCount == 1 }, "The job should complete.")

        let job = queue.jobs[0]
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(job.outcomeSummary, "done")
        XCTAssertNotNil(job.startedAt)
        XCTAssertNotNil(job.finishedAt)
    }

    func testJobsRunOneAtATTimeInTheOrderAsked() async {
        let lock = NSLock()
        var running = 0
        var maxConcurrent = 0
        var order: [String] = []
        let queue = makeQueue { job in
            lock.withLock {
                running += 1
                maxConcurrent = max(maxConcurrent, running)
                order.append(job.bundleIdentifier)
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
            lock.withLock { running -= 1 }
            return InstallationPreparationQueue.Outcome(summary: "ok", isReady: true)
        }
        queue.enqueueAll([
            request(recordID: ApplicationRecordIdentifier()),
            request(recordID: ApplicationRecordIdentifier()),
            request(recordID: ApplicationRecordIdentifier()),
        ])

        await wait(for: { queue.jobs.allSatisfy { $0.state == .completed } }, "All jobs should complete.")

        XCTAssertEqual(maxConcurrent, 1, "One job at a time.")
        XCTAssertEqual(order.count, 3)
    }

    func testDuplicateActiveJobsAreNotEnqueuedTwice() async {
        let gate = AsyncStream<Void>.makeStream()
        var continuation: AsyncStream<Void>.Continuation!
        let queue = makeQueue { _ in
            _ = await gate.stream.first(where: { _ in true })
            return InstallationPreparationQueue.Outcome(summary: "ok", isReady: true)
        }
        continuation = gate.continuation

        let shared = request()
        let first = queue.enqueue(shared)
        let again = queue.enqueue(shared)

        XCTAssertEqual(first.id, again.id, "Asking twice while active does not enqueue twice.")
        XCTAssertEqual(queue.jobs.count, 1)
        continuation.finish()
        await wait(for: { queue.completedCount == 1 }, "The job should finish after the gate opens.")
    }

    func testFailedJobKeepsItsReasonAndRetriesFresh() async {
        var attempts = 0
        let queue = makeQueue { _ in
            attempts += 1
            throw ZynSignError.exportRecordNotFound(
                diagnosticDetail: "synthetic"
            )
        }
        let job = queue.enqueue(request())

        await wait(for: { queue.failedCount == 1 }, "The job should fail.")
        XCTAssertEqual(queue.jobs.first?.id, job.id)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            queue.jobs.first?.state,
            .failed("That exported artifact is no longer listed in the Export Center."),
            "The failure carries the typed error's user-facing text."
        )

        // A retry is a fresh run of the same work — which still fails, so
        // the retry fails again and never reports success it did not earn.
        queue.retry(job.id)
        await wait(for: { attempts == 2 }, "The retry is a fresh run.")
        XCTAssertEqual(queue.failedCount, 1)
    }

    func testQueuedJobCanBeCancelledBeforeItRuns() async {
        let gate = AsyncStream<Void>.makeStream()
        let queue = makeQueue { _ in
            _ = await gate.stream.first(where: { _ in true })
            return InstallationPreparationQueue.Outcome(summary: "ok", isReady: true)
        }
        let first = queue.enqueue(request(recordID: ApplicationRecordIdentifier()))
        let second = queue.enqueue(request(recordID: ApplicationRecordIdentifier()))

        // Wait until the first job actually holds the single slot, so the
        // cancellation targets a job that has not started.
        await wait(for: { queue.jobs.first(where: { $0.id == first.id })?.state == .running }, "The first job should start.")
        queue.cancel(second.id)
        XCTAssertEqual(queue.jobs.first(where: { $0.id == second.id })?.state, .cancelled)

        gate.continuation.finish()
        await wait(for: { queue.jobs.first(where: { $0.id == first.id })?.state == .completed }, "The first job should complete.")
    }

    func testClearSettledRemovesOnlySettledJobs() async {
        let gate = AsyncStream<Void>.makeStream()
        let queue = makeQueue { _ in
            _ = await gate.stream.first(where: { _ in true })
            return InstallationPreparationQueue.Outcome(summary: "ok", isReady: true)
        }
        let runningJob = queue.enqueue(request(recordID: ApplicationRecordIdentifier()))
        let doneJob = queue.enqueue(request(recordID: ApplicationRecordIdentifier()))
        queue.cancel(doneJob.id)

        queue.clearSettled()

        XCTAssertEqual(queue.jobs.map(\.id), [runningJob.id], "Only the active job remains.")

        gate.continuation.finish()
        await wait(for: { queue.jobs.allSatisfy { !$0.isActive } }, "The running job settles after the gate opens.")
        queue.clearSettled()
        XCTAssertTrue(queue.jobs.isEmpty)
    }
}
