import XCTest
@testable import ZynSign

/// Tests for the executor that runs one signing job through the pipeline:
/// how pipeline stages map onto job stages, how pipeline outcomes become job
/// outcomes, and what the history journal records for each.
///
/// The pipeline run is injected, so the tests exercise the executor's own
/// mapping and bookkeeping without a container, a profile, or a Keychain.
final class PipelineSigningExecutorTests: XCTestCase {

    private var directory: URL!
    private var sourceURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineSigningExecutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourceURL = directory.appendingPathComponent("source.ipa")
        try Data("synthetic-container".utf8).write(to: sourceURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func request(source: URL? = nil) -> SigningJobExecutionRequest {
        SigningJobExecutionRequest(
            jobID: SigningJobIdentifier(),
            attempt: 1,
            sourceURL: source ?? sourceURL,
            outputURL: directory.appendingPathComponent("Signed/Example_signed.ipa"),
            profile: SigningQueueFixtures.profileBytes,
            identityID: SigningIdentityIdentifier(),
            emitDEREntitlements: true,
            applicationName: "Example",
            bundleIdentifier: "com.example.synthetic"
        )
    }

    /// Collects every progress report, in delivery order.
    private final class ProgressRecorder: SigningJobProgressReporting, @unchecked Sendable {
        private let lock = NSLock()
        private var _stages: [SigningJobStage] = []
        var stages: [SigningJobStage] {
            lock.lock(); defer { lock.unlock() }
            return _stages
        }
        func report(_ progress: SigningJobProgress) {
            lock.lock(); defer { lock.unlock() }
            _stages.append(progress.stage)
        }
    }

    /// A journal that keeps what it is given.
    private actor RecordingHistory: SigningHistoryStore {
        private(set) var records: [SigningRecord] = []
        let capacity = 100
        func allRecords() async throws -> [SigningRecord] { records }
        func records(forPreset presetID: PresetIdentifier) async throws -> [SigningRecord] { [] }
        func append(_ record: SigningRecord) async throws { records.append(record) }
        func remove(recordWithID id: SigningRecordIdentifier) async throws {}
        func clear() async throws { records = [] }
        func count() async throws -> Int { records.count }
    }

    // MARK: - Stage mapping

    func testPipelineStagesMapOntoTheQueuesStagesInOrder() {
        let mapped = ApplicationSigningStage.allCases.map(PipelineSigningExecutor.jobStage(for:))
        XCTAssertEqual(mapped, [
            .preflight, .preflight,
            .extraction, .extraction,
            .signingFrameworks,
            .signingApp, .signingApp,
            .packaging,
            .verification,
        ])
        // Mapping preserves order: a later pipeline stage never maps to an
        // earlier job stage, so reported progress can only move forwards.
        for (earlier, later) in zip(mapped, mapped.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.order, later.order)
        }
    }

    // MARK: - Outcomes

    func testASignedRunCompletesReportsEveryStageAndIsJournaled() async throws {
        let history = RecordingHistory()
        let recorder = ProgressRecorder()
        let executor = PipelineSigningExecutor(
            run: { request, observe in
                for stage in ApplicationSigningStage.allCases { observe(stage) }
                XCTAssertTrue(request.options.emitDEREntitlements)
                try Data("signed".utf8).write(to: request.outputURL)
                return SignApplicationResult(status: .signed, outputURL: request.outputURL, stages: nil, failure: nil)
            },
            history: history
        )

        let outcome = try await executor.execute(request(), reporting: recorder)

        guard case .completed(let completion) = outcome else { return XCTFail("Expected completion") }
        XCTAssertEqual(completion.outputFileName, "Example_signed.ipa")
        XCTAssertEqual(completion.outputByteCount, 6)
        XCTAssertTrue(completion.verificationPassed)
        XCTAssertEqual(recorder.stages.first, .preparing)
        XCTAssertEqual(recorder.stages.last, .verification)
        let records = await history.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.outcome, .succeeded)
        XCTAssertEqual(records.first?.sourceBundleIdentifier, "com.example.synthetic")
    }

    func testAPipelineRefusalBecomesATypedFailureAtTheMappedStage() async throws {
        let history = RecordingHistory()
        let executor = PipelineSigningExecutor(
            run: { _, observe in
                observe(.integrity)
                observe(.profile)
                return SignApplicationResult(
                    status: .failed,
                    outputURL: nil,
                    stages: nil,
                    failure: ApplicationSigningFailure(
                        stage: .profile,
                        detail: "The replacement profile is not established as compatible.",
                        category: .invalidInput
                    )
                )
            },
            history: history
        )

        let outcome = try await executor.execute(request(), reporting: nil)

        guard case .failed(let failure) = outcome else { return XCTFail("Expected failure") }
        XCTAssertEqual(failure.stage, .preflight)
        XCTAssertEqual(failure.category, .invalidInput)
        XCTAssertEqual(failure.detail, "The replacement profile is not established as compatible.")
        XCTAssertFalse(failure.isRetryable, "A content refusal cannot end differently on a retry")
        let records = await history.records
        XCTAssertEqual(records.first?.outcome, .failed)
        XCTAssertEqual(records.first?.stoppingStage, SigningJobStage.preflight.rawValue)
    }

    func testAnInfrastructureThrowIsARetryableFailureAtTheStageReached() async throws {
        let executor = PipelineSigningExecutor(run: { _, observe in
            observe(.integrity)
            observe(.discovery)
            observe(.extraction)
            throw ZynSignError(category: .storageFailure, userMessage: "Storage ran out.")
        })

        let outcome = try await executor.execute(request(), reporting: nil)

        guard case .failed(let failure) = outcome else { return XCTFail("Expected failure") }
        XCTAssertEqual(failure.stage, .extraction)
        XCTAssertEqual(failure.category, .storageFailure)
        XCTAssertTrue(failure.isRetryable)
    }

    func testCancellationPropagatesRemovesPartialOutputAndIsJournaledAsCancelled() async throws {
        let history = RecordingHistory()
        let executor = PipelineSigningExecutor(
            run: { request, observe in
                observe(.integrity)
                try FileManager.default.createDirectory(
                    at: request.outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("partial".utf8).write(to: request.outputURL)
                throw CancellationError()
            },
            history: history
        )
        let job = request()

        do {
            _ = try await executor.execute(job, reporting: nil)
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.outputURL.path))
        let records = await history.records
        XCTAssertEqual(records.first?.outcome, .cancelled)
    }

    func testAMissingPackageFailsBeforeAnyPipelineWork() async throws {
        let executor = PipelineSigningExecutor(run: { _, _ in
            XCTFail("The pipeline must not run without a source")
            return SignApplicationResult(status: .failed, outputURL: nil, stages: nil, failure: nil)
        })

        let outcome = try await executor.execute(
            request(source: directory.appendingPathComponent("missing.ipa")),
            reporting: nil
        )

        guard case .failed(let failure) = outcome else { return XCTFail("Expected failure") }
        XCTAssertEqual(failure.stage, .preparing)
        XCTAssertFalse(failure.isRetryable)
    }

    func testAStaleOutputFromAnEarlierAttemptIsRemovedBeforeTheRun() async throws {
        let job = request()
        try FileManager.default.createDirectory(
            at: job.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: job.outputURL)
        let executor = PipelineSigningExecutor(run: { request, _ in
            XCTAssertFalse(FileManager.default.fileExists(atPath: request.outputURL.path),
                           "A retry starts from a clean output, never from an earlier attempt's file")
            return SignApplicationResult(
                status: .failed,
                outputURL: nil,
                stages: nil,
                failure: ApplicationSigningFailure(stage: .packaging, detail: "synthetic", category: .internalFailure)
            )
        })

        _ = try await executor.execute(job, reporting: nil)
    }
}
