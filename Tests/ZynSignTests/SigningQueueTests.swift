import XCTest
@testable import ZynSign

/// Tests for the signing queue: the order it runs things in, the controls
/// it offers, the progress it shows, how each job can end, and what survives
/// an interruption.
///
/// The executor underneath the queue is a double, because none of this is
/// about signing Mach-O images — it is about the promises the queue makes
/// to the person using it: one job at a time, highest priority first; a
/// running job never preempted; progress that only moves forwards; a retry
/// only where a retry can change the outcome, and always as a clean run;
/// isolated outputs per job; and a restored queue that never pretends
/// unfinished work finished.
@MainActor
final class SigningQueueTests: XCTestCase {

    private var executor: SyntheticSigningExecutor!
    private var queue: SigningQueue!

    override func setUp() {
        super.setUp()
        executor = SyntheticSigningExecutor()
        queue = makeQueue()
    }

    override func tearDown() {
        executor = nil
        queue = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeQueue(
        store: (any SigningQueueStore)? = nil,
        notifier: (any SigningQueueNotifying)? = nil
    ) -> SigningQueue {
        SigningQueue(
            executor: executor,
            store: store,
            notifier: notifier,
            artifactURLResolver: SigningQueueFixtures.artifactURLResolver,
            outputDirectory: SigningQueueFixtures.outputDirectory,
            now: { SigningQueueFixtures.fixedDate }
        )
    }

    @discardableResult
    private func wait(until condition: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    @discardableResult
    private func waitUntilIdle() async -> Bool {
        await wait { !self.queue.isBusy }
    }

    private func held() -> SyntheticSigningExecutor.Step {
        SyntheticSigningExecutor.Step(holdsUntilReleased: true)
    }

    // MARK: - Ordering

    func testJobsRunOneAtATimeInTheOrderTheyWereQueued() async {
        let ids = queue.enqueue(
            [
                SigningQueueFixtures.submission(name: "MyApp"),
                SigningQueueFixtures.submission(name: "TestApp"),
                SigningQueueFixtures.submission(name: "GameApp"),
                SigningQueueFixtures.submission(name: "UtilityApp"),
            ],
            origin: .bulkSelection
        )
        XCTAssertEqual(queue.jobs.map(\.id), ids)
        XCTAssertEqual(queue.jobs.map(\.origin), Array(repeating: .bulkSelection, count: 4))

        await waitUntilIdle()

        XCTAssertEqual(executor.requests.map(\.applicationName), ["MyApp", "TestApp", "GameApp", "UtilityApp"])
        XCTAssertEqual(queue.completedJobs.count, 4)
        XCTAssertEqual(queue.summary.completedCount, 4)
        XCTAssertFalse(queue.summary.isBusy)
    }

    func testOnlyOneJobRunsWhileTheFirstIsInFlight() async {
        executor.enqueue([held()])
        let first = queue.enqueue(SigningQueueFixtures.submission(name: "MyApp"), origin: .library)
        queue.enqueue(SigningQueueFixtures.submission(name: "TestApp"), origin: .library)
        queue.enqueue(SigningQueueFixtures.submission(name: "GameApp"), origin: .library)

        await wait { self.executor.isHolding(first) }

        XCTAssertEqual(queue.runningJobs.map(\.id), [first])
        XCTAssertEqual(queue.waitingJobs.map(\.applicationName), ["TestApp", "GameApp"])
        XCTAssertEqual(executor.requests.count, 1)
        XCTAssertEqual(queue.summary.runningCount, 1)
        XCTAssertEqual(queue.summary.waitingCount, 2)

        executor.release(first)
        await waitUntilIdle()
        XCTAssertEqual(executor.requests.count, 3)
    }

    // MARK: - Priorities

    func testHigherPriorityWaitingJobsRunFirstAndLowPriorityRunsLast() async {
        executor.enqueue([held()])
        let running = queue.enqueue(SigningQueueFixtures.submission(name: "Running"), origin: .library)
        await wait { self.executor.isHolding(running) }

        queue.enqueue(SigningQueueFixtures.submission(name: "NormalA"), priority: .normal, origin: .library)
        queue.enqueue(SigningQueueFixtures.submission(name: "Background"), priority: .low, origin: .library)
        queue.enqueue(SigningQueueFixtures.submission(name: "NormalB"), priority: .normal, origin: .library)
        queue.enqueue(SigningQueueFixtures.submission(name: "Urgent"), priority: .high, origin: .library)

        XCTAssertEqual(queue.waitingJobs.map(\.applicationName), ["Urgent", "NormalA", "NormalB", "Background"])
        // The running job is never preempted by a higher priority arrival.
        XCTAssertEqual(queue.runningJobs.map(\.applicationName), ["Running"])

        executor.release(running)
        await waitUntilIdle()
        XCTAssertEqual(
            executor.requests.map(\.applicationName),
            ["Running", "Urgent", "NormalA", "NormalB", "Background"]
        )
    }

    func testChangingPriorityReordersAWaitingJobButLeavesTheRunningJobAlone() async {
        executor.enqueue([held()])
        let running = queue.enqueue(SigningQueueFixtures.submission(name: "Running"), origin: .library)
        await wait { self.executor.isHolding(running) }
        queue.enqueue(SigningQueueFixtures.submission(name: "A"), origin: .library)
        let b = queue.enqueue(SigningQueueFixtures.submission(name: "B"), origin: .library)

        queue.setPriority(.high, on: b)
        XCTAssertEqual(queue.waitingJobs.map(\.applicationName), ["B", "A"])
        XCTAssertEqual(queue.job(withID: b)?.priority, .high)

        queue.setPriority(.low, on: running)
        XCTAssertEqual(queue.job(withID: running)?.priority, .normal, "A running job's priority cannot change anything and is not changed")

        executor.release(running)
        await waitUntilIdle()
    }

    // MARK: - Reordering

    func testMoveUpMoveDownAndSendToTopArrangeWaitingJobsOnly() async {
        executor.enqueue([held()])
        let running = queue.enqueue(SigningQueueFixtures.submission(name: "Running"), origin: .library)
        await wait { self.executor.isHolding(running) }
        let a = queue.enqueue(SigningQueueFixtures.submission(name: "A"), origin: .library)
        let b = queue.enqueue(SigningQueueFixtures.submission(name: "B"), origin: .library)
        let c = queue.enqueue(SigningQueueFixtures.submission(name: "C"), origin: .library)

        queue.move(b, up: true)
        XCTAssertEqual(queue.waitingJobs.map(\.applicationName), ["B", "A", "C"])

        queue.move(b, up: false)
        XCTAssertEqual(queue.waitingJobs.map(\.applicationName), ["A", "B", "C"])

        queue.sendToTop(c)
        XCTAssertEqual(queue.waitingJobs.map(\.applicationName), ["C", "A", "B"])

        // Moving past the ends is a no-op, and a running job cannot move.
        queue.move(c, up: true)
        queue.move(b, up: false)
        queue.move(running, up: true)
        queue.sendToTop(running)
        XCTAssertEqual(queue.waitingJobs.map(\.applicationName), ["C", "A", "B"])
        XCTAssertEqual(queue.runningJobs.map(\.id), [running])
        _ = a

        executor.release(running)
        await waitUntilIdle()
        XCTAssertEqual(executor.requests.map(\.applicationName), ["Running", "C", "A", "B"])
    }

    // MARK: - Cancelling

    func testCancellingAWaitingJobSettlesItWithoutEverRunningIt() async {
        executor.enqueue([held()])
        let running = queue.enqueue(SigningQueueFixtures.submission(name: "Running"), origin: .library)
        await wait { self.executor.isHolding(running) }
        let waiting = queue.enqueue(SigningQueueFixtures.submission(name: "Waiting"), origin: .library)

        queue.cancel(waiting)
        XCTAssertEqual(queue.job(withID: waiting)?.state, .cancelled)

        executor.release(running)
        await waitUntilIdle()
        XCTAssertEqual(executor.requests.map(\.applicationName), ["Running"])
    }

    func testCancellingARunningJobStopsItAtItsNextSafePoint() async {
        executor.enqueue([held()])
        let running = queue.enqueue(SigningQueueFixtures.submission(name: "Running"), origin: .library)
        await wait { self.executor.isHolding(running) }

        queue.cancel(running)
        // Cancellation is cooperative: until the run reaches a safe point
        // the job says it is cancelling rather than pretending it stopped.
        if queue.job(withID: running)?.state == .running {
            XCTAssertEqual(queue.job(withID: running)?.cancellationRequested, true)
            XCTAssertEqual(queue.job(withID: running)?.statusText, "Cancelling…")
        }

        await waitUntilIdle()
        XCTAssertEqual(queue.job(withID: running)?.state, .cancelled)
        XCTAssertEqual(executor.cancelledJobs, [running])
        XCTAssertEqual(queue.job(withID: running)?.cancellationRequested, false)
    }

    func testCancelAllWaitingLeavesTheRunningJobInFlight() async {
        executor.enqueue([held()])
        let running = queue.enqueue(SigningQueueFixtures.submission(name: "Running"), origin: .library)
        await wait { self.executor.isHolding(running) }
        queue.enqueue(SigningQueueFixtures.submission(name: "A"), origin: .library)
        queue.enqueue(SigningQueueFixtures.submission(name: "B"), origin: .library)

        queue.cancelAllWaiting()

        XCTAssertTrue(queue.waitingJobs.isEmpty)
        XCTAssertEqual(queue.cancelledJobs.count, 2)
        XCTAssertEqual(queue.job(withID: running)?.state, .running)

        executor.release(running)
        await waitUntilIdle()
        XCTAssertNotNil(queue.job(withID: running)?.completion)
    }

    // MARK: - Failure and retry

    func testARetryableFailureCanBeRetriedAsAFreshRunOfTheSameJob() async {
        executor.enqueue([
            .init(outcome: .fails(SigningQueueFixtures.failure(stage: .packaging, category: .storageFailure))),
        ])
        let id = queue.enqueue(SigningQueueFixtures.submission(name: "MyApp"), origin: .library)
        await waitUntilIdle()

        guard let failed = queue.job(withID: id), let failure = failed.failure else {
            return XCTFail("The job should have failed")
        }
        XCTAssertEqual(failure.stage, .packaging)
        XCTAssertTrue(failed.isRetryable)
        XCTAssertEqual(failed.statusText, "Failed at Packaging")

        queue.retry(id)
        XCTAssertEqual(queue.job(withID: id)?.state.isActive, true)
        await waitUntilIdle()

        XCTAssertNotNil(queue.job(withID: id)?.completion)
        XCTAssertEqual(queue.job(withID: id)?.attemptCount, 2)
        XCTAssertEqual(executor.requests.map(\.attempt), [1, 2])
        // A retry is the same job: the same output name, so it replaces its
        // own earlier output and never another job's.
        XCTAssertEqual(executor.requests[0].outputURL, executor.requests[1].outputURL)
        XCTAssertEqual(executor.requests[0].jobID, executor.requests[1].jobID)
    }

    func testAContentRefusalIsNotOfferedARetry() async {
        executor.enqueue([
            .init(outcome: .fails(SigningQueueFixtures.failure(stage: .preflight, category: .invalidInput))),
        ])
        let id = queue.enqueue(SigningQueueFixtures.submission(), origin: .library)
        await waitUntilIdle()

        XCTAssertEqual(queue.job(withID: id)?.isRetryable, false)
        queue.retry(id)
        XCTAssertNotNil(queue.job(withID: id)?.failure)
        XCTAssertEqual(executor.requests.count, 1)
    }

    func testAnUnexpectedThrowIsARetryableFailureAtTheStageReached() async {
        executor.enqueue([.init(stages: [.preflight, .extraction], outcome: .throwsUnexpectedly)])
        let id = queue.enqueue(SigningQueueFixtures.submission(), origin: .library)
        await waitUntilIdle()

        guard let failure = queue.job(withID: id)?.failure else { return XCTFail("Expected a failure") }
        XCTAssertTrue(failure.isRetryable)
        XCTAssertEqual(failure.category, .internalFailure)
    }

    func testRetryAllFailedRetriesOnlyTheFailuresARetryCanChange() async {
        executor.enqueue([
            .init(outcome: .fails(SigningQueueFixtures.failure(category: .storageFailure))),
            .init(outcome: .fails(SigningQueueFixtures.failure(category: .unsupportedInput))),
        ])
        let transient = queue.enqueue(SigningQueueFixtures.submission(name: "Transient"), origin: .library)
        let refused = queue.enqueue(SigningQueueFixtures.submission(name: "Refused"), origin: .library)
        await waitUntilIdle()

        queue.retryAllFailed()
        await waitUntilIdle()

        XCTAssertNotNil(queue.job(withID: transient)?.completion)
        XCTAssertNotNil(queue.job(withID: refused)?.failure)
        XCTAssertEqual(executor.requests.map(\.applicationName), ["Transient", "Refused", "Transient"])
    }

    func testACancelledJobCanBeRetried() async {
        executor.enqueue([held()])
        let id = queue.enqueue(SigningQueueFixtures.submission(), origin: .library)
        await wait { self.executor.isHolding(id) }
        queue.cancel(id)
        await waitUntilIdle()
        XCTAssertEqual(queue.job(withID: id)?.isRetryable, true)

        queue.retry(id)
        await waitUntilIdle()
        XCTAssertNotNil(queue.job(withID: id)?.completion)
    }

    // MARK: - Removing and bulk clearing

    func testOnlySettledJobsCanBeRemoved() async {
        executor.enqueue([held()])
        let running = queue.enqueue(SigningQueueFixtures.submission(), origin: .library)
        await wait { self.executor.isHolding(running) }

        queue.remove(running)
        XCTAssertNotNil(queue.job(withID: running))

        executor.release(running)
        await waitUntilIdle()
        queue.remove(running)
        XCTAssertNil(queue.job(withID: running))
    }

    func testClearCompletedAndClearFailedRemoveOnlyTheirOwnKind() async {
        executor.enqueue([
            .init(),
            .init(outcome: .fails(SigningQueueFixtures.failure())),
            .init(),
        ])
        queue.enqueue(
            [
                SigningQueueFixtures.submission(name: "A"),
                SigningQueueFixtures.submission(name: "B"),
                SigningQueueFixtures.submission(name: "C"),
            ],
            origin: .bulkSelection
        )
        await waitUntilIdle()
        XCTAssertEqual(queue.completedJobs.count, 2)
        XCTAssertEqual(queue.failedJobs.count, 1)

        queue.clearCompleted()
        XCTAssertEqual(queue.jobs.map(\.applicationName), ["B"])

        queue.clearFailed()
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    // MARK: - Live progress

    func testProgressOnlyMovesForwardsEvenWhenReportsArriveOutOfOrder() async {
        executor.enqueue([
            .init(stages: [.signingFrameworks, .preflight, .extraction], holdsUntilReleased: true),
        ])
        let id = queue.enqueue(SigningQueueFixtures.submission(), origin: .library)
        await wait { self.queue.job(withID: id)?.progress?.stage == .signingFrameworks }
        // Give the late, backwards reports time to arrive and be refused.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(queue.job(withID: id)?.progress?.stage, .signingFrameworks)
        let fraction = queue.job(withID: id)?.fractionCompleted ?? 0
        XCTAssertEqual(fraction, SigningJobStage.signingFrameworks.startingFraction, accuracy: 0.0001)

        executor.release(id)
        await waitUntilIdle()
        XCTAssertEqual(queue.job(withID: id)?.fractionCompleted, 1)
        XCTAssertEqual(queue.job(withID: id)?.stage, .completed)
    }

    func testAFailedJobKeepsTheFractionItActuallyReached() async {
        executor.enqueue([
            .init(stages: [.preflight, .extraction], outcome: .fails(SigningQueueFixtures.failure(stage: .extraction))),
        ])
        let id = queue.enqueue(SigningQueueFixtures.submission(), origin: .library)
        await waitUntilIdle()
        let fraction = queue.job(withID: id)?.fractionCompleted ?? -1
        XCTAssertEqual(fraction, SigningJobStage.extraction.startingFraction, accuracy: 0.0001)
        XCTAssertLessThan(fraction, 1)
    }

    func testEachJobKeepsItsOwnLog() async {
        queue.enqueue(
            [SigningQueueFixtures.submission(name: "A"), SigningQueueFixtures.submission(name: "B")],
            origin: .library
        )
        await waitUntilIdle()
        for job in queue.jobs {
            XCTAssertTrue(job.log.first?.message.hasPrefix("Queued from") ?? false)
            XCTAssertTrue(job.log.contains { $0.message.hasPrefix("Run started (attempt 1)") })
            XCTAssertTrue(job.log.contains { $0.message.hasPrefix("Completed") })
            XCTAssertEqual(job.log.filter { $0.message.hasPrefix("Run started") }.count, 1)
        }
    }

    // MARK: - Isolation

    func testEveryJobHasItsOwnOutputAndReadsItsOwnSource() async {
        let submissions = (0..<6).map { SigningQueueFixtures.submission(name: "Same Name") }
        queue.enqueue(submissions, origin: .bulkSelection)
        await waitUntilIdle()

        let requests = executor.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(Set(requests.map(\.outputURL)).count, 6, "Two jobs must never share an output")
        XCTAssertEqual(Set(requests.map(\.jobID)).count, 6)
        for (request, submission) in zip(requests, submissions) {
            XCTAssertEqual(request.sourceURL, SigningQueueFixtures.artifactURLResolver(submission.artifactID))
            XCTAssertEqual(request.outputURL.deletingLastPathComponent(), SigningQueueFixtures.outputDirectory)
            XCTAssertEqual(request.identityID, submission.identityID)
            XCTAssertEqual(request.profile, submission.profile)
        }
    }

    func testOutputFileNamesAreFilesystemSafeAndUniquePerJob() {
        let submission = SigningQueueFixtures.submission(name: "My App: Pro/Max")
        let first = SigningQueue.outputFileName(for: submission, jobID: SigningJobIdentifier())
        let second = SigningQueue.outputFileName(for: submission, jobID: SigningJobIdentifier())
        XCTAssertFalse(first.contains("/"))
        XCTAssertFalse(first.contains(":"))
        XCTAssertFalse(first.contains(" "))
        XCTAssertTrue(first.hasSuffix(".ipa"))
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Notices

    func testSettledRunsPostJobNoticesAndThenQueueFinished() async {
        let notifier = RecordingSigningQueueNotifier()
        queue = makeQueue(notifier: notifier)
        executor.enqueue([.init(), .init(outcome: .fails(SigningQueueFixtures.failure()))])
        queue.enqueue(
            [SigningQueueFixtures.submission(name: "Good"), SigningQueueFixtures.submission(name: "Bad")],
            origin: .library
        )
        await waitUntilIdle()
        await wait { self.queue.pendingNotices.count == 3 }

        XCTAssertEqual(queue.pendingNotices.map(\.kind), [.jobCompleted, .jobFailed, .queueFinished])
        XCTAssertEqual(queue.pendingNotices[0].title, "Good signed")
        XCTAssertEqual(queue.pendingNotices[1].title, "Bad failed")
        XCTAssertEqual(queue.pendingNotices[2].message, "1 signed · 1 failed.")

        // Local notifications are offered asynchronously; wait for all three.
        var delivered = await notifier.notices
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, delivered.count < 3 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            delivered = await notifier.notices
        }
        XCTAssertEqual(Set(delivered.map(\.id)), Set(queue.pendingNotices.map(\.id)))

        let first = queue.pendingNotices[0].id
        queue.acknowledgeNotice(first)
        XCTAssertFalse(queue.pendingNotices.contains { $0.id == first })
    }

    func testClearingTheListNeverPostsQueueFinished() async {
        queue.enqueue(SigningQueueFixtures.submission(), origin: .library)
        await waitUntilIdle()
        await wait { self.queue.pendingNotices.count == 2 }
        queue.pendingNotices.forEach { queue.acknowledgeNotice($0.id) }

        queue.clearCompleted()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(queue.pendingNotices.isEmpty)
    }

    // MARK: - Persistence

    func testNothingRunsBeforeThePersistedQueueIsRestored() async {
        let store = InMemorySigningQueueStore()
        queue = makeQueue(store: store)
        let id = queue.enqueue(SigningQueueFixtures.submission(), origin: .library)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(queue.job(withID: id)?.state, .queued)
        XCTAssertTrue(executor.requests.isEmpty)

        await queue.restore()
        await waitUntilIdle()
        XCTAssertNotNil(queue.job(withID: id)?.completion)
    }

    func testTheQueueIsPersistedAndWaitingJobsCarryTheirSetup() async {
        let store = InMemorySigningQueueStore()
        queue = makeQueue(store: store)
        await queue.restore()
        executor.enqueue([held()])
        let running = queue.enqueue(SigningQueueFixtures.submission(name: "Running"), origin: .library)
        await wait { self.executor.isHolding(running) }
        let waiting = queue.enqueue(SigningQueueFixtures.submission(name: "Waiting", emitDEREntitlements: true), priority: .high, origin: .library)

        var persisted: SigningQueueSnapshot?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            persisted = await store.snapshot
            if let job = persisted?.jobs.first(where: { $0.id == waiting.rawValue }),
               job.setup?.profileFileName != nil {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard let stored = persisted?.jobs.first(where: { $0.id == waiting.rawValue }) else {
            return XCTFail("The waiting job should be persisted")
        }
        XCTAssertEqual(stored.state, .queued)
        XCTAssertEqual(stored.priority, .high)
        XCTAssertEqual(stored.setup?.emitDEREntitlements, true)
        XCTAssertNotNil(stored.setup?.profileFileName)
        let profiles = await store.profiles
        XCTAssertEqual(profiles[stored.setup?.profileFileName ?? ""], SigningQueueFixtures.profileBytes)

        executor.release(running)
        await waitUntilIdle()
    }

    func testRestorationNeverMarksUnfinishedWorkCompleted() async {
        let runningID = SigningJobIdentifier()
        let waitingID = SigningJobIdentifier()
        let orphanID = SigningJobIdentifier()
        let completedID = SigningJobIdentifier()
        let failedID = SigningJobIdentifier()
        let identity = SigningIdentityIdentifier()

        func setup(_ id: SigningJobIdentifier, withProfile: Bool) -> StoredSigningJobSetup {
            StoredSigningJobSetup(
                identityID: identity.rawValue,
                identityDisplayName: "Synthetic Identity",
                certificateFingerprint: nil,
                profileFileName: withProfile ? "\(id.rawValue).mobileprovision" : "missing.mobileprovision",
                profileDisplayName: "Synthetic Profile",
                profileTeamIdentifier: "EXAMPLE123",
                emitDEREntitlements: false,
                presetID: nil,
                outputFileName: "out.ipa"
            )
        }
        func stored(
            _ id: SigningJobIdentifier,
            name: String,
            state: SigningJobState,
            stage: SigningJobStage? = nil,
            setup: StoredSigningJobSetup?
        ) -> StoredSigningJob {
            StoredSigningJob(
                id: id.rawValue,
                applicationName: name,
                bundleIdentifier: "com.example.\(name.lowercased())",
                versionText: nil,
                recordID: ApplicationRecordIdentifier().rawValue,
                artifactID: ArtifactIdentifier().rawValue,
                priority: .normal,
                origin: .library,
                enqueuedAt: SigningQueueFixtures.fixedDate,
                startedAt: state == .queued ? nil : SigningQueueFixtures.fixedDate,
                finishedAt: state.isSettled ? SigningQueueFixtures.fixedDate : nil,
                attemptCount: state == .queued ? 0 : 1,
                state: state,
                lastStageRawValue: stage?.rawValue,
                log: [],
                setup: setup
            )
        }

        let snapshot = SigningQueueSnapshot(
            revision: 7,
            savedAt: SigningQueueFixtures.fixedDate,
            jobs: [
                stored(completedID, name: "Done", state: .completed(SigningQueueFixtures.completion()), setup: nil),
                stored(failedID, name: "Refused", state: .failed(SigningQueueFixtures.failure(category: .invalidInput)), setup: nil),
                stored(runningID, name: "Interrupted", state: .running, stage: .signingFrameworks, setup: setup(runningID, withProfile: true)),
                stored(waitingID, name: "Waiting", state: .queued, setup: setup(waitingID, withProfile: true)),
                stored(orphanID, name: "Orphan", state: .queued, setup: setup(orphanID, withProfile: false)),
            ]
        )
        let store = InMemorySigningQueueStore(
            snapshot: snapshot,
            profiles: [
                "\(runningID.rawValue).mobileprovision": SigningQueueFixtures.profileBytes,
                "\(waitingID.rawValue).mobileprovision": SigningQueueFixtures.profileBytes,
                "stale-orphan.mobileprovision": Data("stale".utf8),
            ]
        )
        queue = makeQueue(store: store)
        await queue.restore()
        await waitUntilIdle()

        // Settled jobs come back exactly as they settled.
        XCTAssertEqual(queue.job(withID: completedID)?.completion, SigningQueueFixtures.completion())
        XCTAssertEqual(queue.job(withID: failedID)?.failure?.category, .invalidInput)

        // The job that was running is an interrupted failure at the stage it
        // reached — never completed — and retryable because its setup
        // survived.
        let interrupted = queue.job(withID: runningID)
        XCTAssertNil(interrupted?.completion)
        XCTAssertEqual(interrupted?.failure?.stage, .signingFrameworks)
        XCTAssertEqual(interrupted?.isRetryable, true)

        // The waiting job with its setup ran after restoration.
        XCTAssertNotNil(queue.job(withID: waitingID)?.completion)
        XCTAssertEqual(executor.requests.map(\.jobID), [waitingID])
        XCTAssertEqual(executor.requests.first?.identityID, identity)

        // The waiting job whose profile copy is gone cannot run honestly.
        let orphan = queue.job(withID: orphanID)
        XCTAssertNotNil(orphan?.failure)
        XCTAssertEqual(orphan?.isRetryable, false)

        // Temporary state was recovered: the unreferenced copy is swept.
        let profiles = await store.profiles
        XCTAssertNil(profiles["stale-orphan.mobileprovision"])
        XCTAssertNotNil(profiles["\(runningID.rawValue).mobileprovision"])

        // The interrupted job retries as a fresh, clean run.
        queue.retry(runningID)
        await waitUntilIdle()
        XCTAssertNotNil(queue.job(withID: runningID)?.completion)
        XCTAssertEqual(queue.job(withID: runningID)?.attemptCount, 2)
    }

    func testRemovingAJobDiscardsItsPersistedProfileCopy() async {
        let store = InMemorySigningQueueStore()
        queue = makeQueue(store: store)
        await queue.restore()
        let id = queue.enqueue(SigningQueueFixtures.submission(), origin: .library)
        await waitUntilIdle()
        var profiles = await store.profiles
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, profiles.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
            profiles = await store.profiles
        }
        XCTAssertFalse(profiles.isEmpty)

        queue.remove(id)
        let removalDeadline = Date().addingTimeInterval(5)
        while Date() < removalDeadline, !profiles.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
            profiles = await store.profiles
        }
        XCTAssertTrue(profiles.isEmpty)
    }
}
