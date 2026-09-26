import XCTest
@testable import ZynSign

/// Tests for the executor that runs one signing job as one signing
/// operation: how pipeline stages map onto job stages, how the operation's
/// outcomes become job outcomes, and what the executor hands the operation.
///
/// The operation and the library lookup are injected, so the tests exercise
/// the executor's own mapping without a container, a profile, a Keychain, or
/// export storage. Delivery, isolation, and journaling belong to
/// `SigningOperationCenter` and are covered by its own tests.
final class SigningOperationExecutorTests: XCTestCase {

    // MARK: - Helpers

    private let entry = LibraryOrganizationFixtures.entry(name: "Example")
    private let sourceURL = URL(fileURLWithPath: "/synthetic/source.ipa")

    private func request(emitDER: Bool = true) -> SigningJobExecutionRequest {
        SigningJobExecutionRequest(
            jobID: SigningJobIdentifier(),
            attempt: 1,
            recordID: entry.record.id,
            sourceURL: sourceURL,
            profile: SigningQueueFixtures.profileBytes,
            identityID: SigningIdentityIdentifier(),
            emitDEREntitlements: emitDER,
            applicationName: "Example",
            bundleIdentifier: "com.example.synthetic",
            identityDisplayName: "Synthetic Identity",
            profileDisplayName: "Synthetic Profile"
        )
    }

    /// An executor whose library lookup finds the fixture entry.
    private func executor(run: @escaping SigningOperationExecutor.OperationRun) -> SigningOperationExecutor {
        let entry = self.entry
        return SigningOperationExecutor(run: run, resolveEntry: { _ in entry })
    }

    private static func operationRecord(_ result: SigningRecord.Outcome) -> SigningRecord {
        SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: "com.example.synthetic",
            sourceDisplayName: "Example",
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: nil,
            outputByteCount: nil,
            startedAt: Date(),
            duration: 1,
            result: result
        )
    }

    private static func path(_ raw: String) -> BundlePath {
        guard let path = BundlePath(rawValue: raw) else {
            preconditionFailure("Test used an invalid bundle path: \(raw)")
        }
        return path
    }

    /// Collects every progress report, in delivery order.
    private final class ProgressRecorder: SigningJobProgressReporting, @unchecked Sendable {
        private let lock = NSLock()
        private var _reports: [SigningJobProgress] = []
        var reports: [SigningJobProgress] {
            lock.lock(); defer { lock.unlock() }
            return _reports
        }
        var stages: [SigningJobStage] { reports.map(\.stage) }
        func report(_ progress: SigningJobProgress) {
            lock.lock(); defer { lock.unlock() }
            _reports.append(progress)
        }
    }

    /// Keeps the request the executor handed the operation.
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _request: SigningOperationRequest?
        var request: SigningOperationRequest? {
            lock.lock(); defer { lock.unlock() }
            return _request
        }
        func keep(_ request: SigningOperationRequest) {
            lock.lock(); defer { lock.unlock() }
            _request = request
        }
    }

    // MARK: - Stage mapping

    func testPipelineStagesMapOntoTheQueuesStagesInOrder() {
        let mapped = ApplicationSigningStage.allCases.map(SigningOperationExecutor.jobStage(for:))
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

    func testOperationFailureStagesMapOntoJobStages() {
        XCTAssertEqual(SigningOperationExecutor.jobStage(for: .importSource, reached: .preparing), .preparing)
        XCTAssertEqual(SigningOperationExecutor.jobStage(for: .validation, reached: .preflight), .preflight)
        XCTAssertEqual(SigningOperationExecutor.jobStage(for: .preflight, reached: .preflight), .preflight)
        XCTAssertEqual(
            SigningOperationExecutor.jobStage(for: .nestedSigning, reached: .extraction), .extraction,
            "The run's own progress places a failure inside the operation's grouped stage"
        )
        XCTAssertEqual(SigningOperationExecutor.jobStage(for: .nestedSigning, reached: .signingFrameworks), .signingFrameworks)
        XCTAssertEqual(SigningOperationExecutor.jobStage(for: .mainSigning, reached: .signingApp), .signingApp)
        XCTAssertEqual(SigningOperationExecutor.jobStage(for: .packaging, reached: .packaging), .packaging)
        XCTAssertEqual(SigningOperationExecutor.jobStage(for: .verification, reached: .verification), .verification)
        XCTAssertEqual(SigningOperationExecutor.jobStage(for: .export, reached: .verification), .verification)
    }

    // MARK: - Outcomes

    func testAnExportedRunCompletesWithTheExportRecordAndReportsEveryStage() async throws {
        let recorder = ProgressRecorder()
        let box = RequestBox()
        let exportRecord = ExportRecord(
            sourceRecordIdentifier: nil,
            sourceArtifactIdentifier: nil,
            applicationName: "Example",
            bundleIdentifier: "com.example.synthetic",
            shortVersion: "1.0",
            buildVersion: "1",
            fileName: "Example 1.0.ipa",
            byteCount: 4_096,
            fingerprint: nil,
            createdAt: Date(),
            verificationStatus: .valid
        )
        let executor = executor { request, observe in
            box.keep(request)
            for stage in ApplicationSigningStage.allCases { observe(.stageStarted(stage)) }
            return .exported(
                record: exportRecord,
                operation: Self.operationRecord(.succeeded),
                fileURL: URL(fileURLWithPath: "/synthetic/Signed/Example 1.0.ipa")
            )
        }

        let outcome = try await executor.execute(request(), reporting: recorder)

        guard case .completed(let completion) = outcome else { return XCTFail("Expected completion") }
        XCTAssertEqual(completion.outputFileName, "Example 1.0.ipa")
        XCTAssertEqual(completion.outputByteCount, 4_096)
        XCTAssertTrue(completion.verificationPassed)
        XCTAssertEqual(completion.exportIdentifier, exportRecord.id.rawValue)
        XCTAssertEqual(completion.exportVerification, .valid)
        XCTAssertEqual(recorder.stages.first, .preparing)
        XCTAssertEqual(recorder.stages.last, .verification)

        let handed = try XCTUnwrap(box.request)
        XCTAssertEqual(handed.entry.record.id, entry.record.id)
        XCTAssertEqual(handed.sourceURL, sourceURL)
        XCTAssertEqual(handed.profile, SigningQueueFixtures.profileBytes)
        XCTAssertEqual(handed.provisioningProfileName, "Synthetic Profile")
        XCTAssertEqual(handed.certificateDisplayName, "Synthetic Identity")
        XCTAssertTrue(handed.options.emitDEREntitlements)
    }

    func testProgressNeverMovesBackwards() async throws {
        let recorder = ProgressRecorder()
        let executor = executor { _, observe in
            observe(.stageStarted(.mainExecutable))
            observe(.stageStarted(.integrity)) // a late or duplicate event
            throw ZynSignError(category: .internalFailure, userMessage: "synthetic")
        }

        _ = try await executor.execute(request(), reporting: recorder)

        XCTAssertEqual(recorder.stages, [.preparing, .signingApp])
    }

    func testNestedSigningAdvancesByCountedTargetsOnly() async throws {
        let recorder = ProgressRecorder()
        let executor = executor { _, observe in
            observe(.nestedPlan([.framework: 2]))
            observe(.stageStarted(.nestedSigning))
            observe(.nestedItemStarted(order: 1, total: 2, kind: .framework, path: Self.path("Frameworks/A.framework")))
            observe(.nestedItemSigned(order: 1, total: 2, kind: .framework, path: Self.path("Frameworks/A.framework")))
            observe(.nestedItemSigned(order: 2, total: 2, kind: .framework, path: Self.path("Frameworks/B.framework")))
            throw ZynSignError(category: .internalFailure, userMessage: "synthetic")
        }

        _ = try await executor.execute(request(), reporting: recorder)

        let frameworks = recorder.reports.filter { $0.stage == .signingFrameworks }
        XCTAssertEqual(frameworks.map(\.completedUnitCount), [0, 1, 2])
        XCTAssertTrue(frameworks.allSatisfy { $0.totalUnitCount == 2 })
    }

    func testARecordedFailureBecomesATypedFailureAtTheMappedStage() async throws {
        let executor = executor { _, observe in
            observe(.stageStarted(.integrity))
            observe(.stageStarted(.profile))
            return .failed(
                operation: Self.operationRecord(.failed),
                failure: SigningFailureSummary(
                    stage: .preflight,
                    category: DiagnosticCategory.invalidInput.rawValue,
                    explanation: "The replacement profile is not established as compatible."
                )
            )
        }

        let outcome = try await executor.execute(request(), reporting: nil)

        guard case .failed(let failure) = outcome else { return XCTFail("Expected failure") }
        XCTAssertEqual(failure.stage, .preflight)
        XCTAssertEqual(failure.category, .invalidInput)
        XCTAssertEqual(failure.detail, "The replacement profile is not established as compatible.")
        XCTAssertFalse(failure.isRetryable, "A content refusal cannot end differently on a retry")
    }

    func testAnUnknownRecordedCategoryIsTreatedAsAnInternalFailure() async throws {
        let executor = executor { _, _ in
            .failed(
                operation: Self.operationRecord(.failed),
                failure: SigningFailureSummary(stage: .packaging, category: "not-a-category", explanation: "synthetic")
            )
        }

        let outcome = try await executor.execute(request(), reporting: nil)

        guard case .failed(let failure) = outcome else { return XCTFail("Expected failure") }
        XCTAssertEqual(failure.category, .internalFailure)
        XCTAssertEqual(failure.stage, .packaging)
        XCTAssertTrue(failure.isRetryable)
    }

    func testAnInfrastructureThrowIsARetryableFailureAtTheStageReached() async throws {
        let executor = executor { _, observe in
            observe(.stageStarted(.integrity))
            observe(.stageStarted(.discovery))
            observe(.stageStarted(.extraction))
            throw ZynSignError(category: .storageFailure, userMessage: "Storage ran out.")
        }

        let outcome = try await executor.execute(request(), reporting: nil)

        guard case .failed(let failure) = outcome else { return XCTFail("Expected failure") }
        XCTAssertEqual(failure.stage, .extraction)
        XCTAssertEqual(failure.category, .storageFailure)
        XCTAssertEqual(failure.detail, "Storage ran out.")
        XCTAssertTrue(failure.isRetryable)
    }

    func testAThrownCancellationPropagates() async throws {
        let executor = executor { _, observe in
            observe(.stageStarted(.integrity))
            throw CancellationError()
        }

        do {
            _ = try await executor.execute(request(), reporting: nil)
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            // Expected: the queue settles the job as cancelled.
        }
    }

    func testAReportedCancellationPropagates() async throws {
        let executor = executor { _, _ in
            .cancelled(operation: Self.operationRecord(.cancelled))
        }

        do {
            _ = try await executor.execute(request(), reporting: nil)
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            // Expected.
        }
    }

    // MARK: - Before the run

    func testARemovedApplicationFailsBeforeAnyOperation() async throws {
        let executor = SigningOperationExecutor(
            run: { _, _ in
                XCTFail("No operation may run for an application the library no longer lists")
                return .refused(.sourceUnavailable(explanation: "synthetic"))
            },
            resolveEntry: { _ in nil }
        )

        let outcome = try await executor.execute(request(), reporting: nil)

        guard case .failed(let failure) = outcome else { return XCTFail("Expected failure") }
        XCTAssertEqual(failure.stage, .preparing)
        XCTAssertEqual(failure.category, .invalidInput)
        XCTAssertFalse(failure.isRetryable)
    }

    func testRefusalsFailAtPreparingWithTheRightRetryability() async throws {
        let cases: [(SigningOperationRefusal, DiagnosticCategory, Bool)] = [
            (.sourceUnavailable(explanation: "gone"), .invalidInput, false),
            (.insufficientStorage(requiredByteCount: 10, availableByteCount: 1), .storageFailure, true),
            (.workspaceUnavailable(explanation: "denied"), .storageFailure, true),
        ]
        for (refusal, category, retryable) in cases {
            let executor = executor { _, _ in .refused(refusal) }

            let outcome = try await executor.execute(request(), reporting: nil)

            guard case .failed(let failure) = outcome else { return XCTFail("Expected failure for \(refusal)") }
            XCTAssertEqual(failure.stage, .preparing)
            XCTAssertEqual(failure.category, category)
            XCTAssertEqual(failure.isRetryable, retryable)
            XCTAssertEqual(failure.detail, refusal.message)
        }
    }
}
