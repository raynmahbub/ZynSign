import Foundation
import XCTest
@testable import ZynSign

/// Tests for the batch signing sequencer.
///
/// The sequencer had no test at all before these, which is how it kept a
/// defect the type of the code makes easy to write: `SignApplicationPipeline`
/// reports a refusal as a *returned result*, not a thrown error, and the batch
/// step read only the return value. A refused package was therefore recorded as
/// delivered — output name set, outcome `succeeded`, nothing on disk — and a
/// batch summary that counts refusals as successes is worse than the failure it
/// hides.
///
/// The coordinator now depends on `BatchSigningStep`, so these tests drive the
/// sequencing rules with a scripted engine instead of real packages: a refusal
/// is a failure, one failure does not stop the run, every step reaches the
/// journal, and an empty request is refused.
final class BatchSigningCoordinatorTests: XCTestCase {

    private var workDirectory: URL!
    private var sourceURL: URL!
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = try LibraryFixtures.makeTemporaryDirectory()
        sourceURL = workDirectory.appendingPathComponent("Synthetic.ipa", isDirectory: false)
        try Data("synthetic-ipa-bytes".utf8).write(to: sourceURL)
        outputDirectory = workDirectory.appendingPathComponent("Signed", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        sourceURL = nil
        outputDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Refusals

    /// The regression this suite exists for: a refusal must be a failed step,
    /// with no output name and a failure recorded in the journal.
    func testARefusedSigningIsRecordedAsAFailureRatherThanADelivery() async throws {
        let engine = ScriptedSigningStep(replies: [.refused(at: .profile)])
        let history = InMemorySigningHistoryStore()
        let coordinator = makeCoordinator(engine: engine, history: history)
        let entry = makeEntry()

        let result = try await coordinator.run(try makeRequest(entries: [entry]))

        XCTAssertEqual(result.steps.count, 1)
        let step = try XCTUnwrap(result.steps.first)
        XCTAssertEqual(step.outcome, .failed)
        XCTAssertNil(step.outputFileName, "a refused package has no delivered output")
        XCTAssertNil(step.outputByteCount)
        XCTAssertEqual(step.stoppingStage, ApplicationSigningStage.profile.rawValue)
        XCTAssertEqual(step.userMessage, "The profile does not authorize this bundle.")
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertEqual(result.failedCount, 1)

        let records = try await history.allRecords()
        XCTAssertEqual(records.count, 1, "every step reaches the journal")
        XCTAssertEqual(records.first?.outcome, .failed)
        XCTAssertNotNil(records.first?.errorCode)
        XCTAssertNil(records.first?.outputFileName)
    }

    /// A batch is worth running because one bad package does not waste the
    /// user's setup: the remaining entries are still attempted, in order.
    func testOneRefusalDoesNotStopTheRemainingEntries() async throws {
        let engine = ScriptedSigningStep(replies: [.refused(at: .integrity), .signed])
        let history = InMemorySigningHistoryStore()
        let coordinator = makeCoordinator(engine: engine, history: history)
        let entries = [makeEntry(name: "First"), makeEntry(name: "Second")]

        let result = try await coordinator.run(try makeRequest(entries: entries))

        XCTAssertEqual(result.steps.map(\.outcome), [.failed, .succeeded])
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.failedCount, 1)
        let attempts = await engine.requestCount
        let records = try await history.allRecords()
        XCTAssertEqual(attempts, 2, "both entries were attempted")
        XCTAssertEqual(records.count, 2)
    }

    /// A step that throws is a failed step too, and the run continues.
    func testAThrownStepFailsOnlyThatEntry() async throws {
        let engine = ScriptedSigningStep(replies: [.thrown, .signed])
        let history = InMemorySigningHistoryStore()
        let coordinator = makeCoordinator(engine: engine, history: history)
        let entries = [makeEntry(name: "First"), makeEntry(name: "Second")]

        let result = try await coordinator.run(try makeRequest(entries: entries))

        XCTAssertEqual(result.steps.map(\.outcome), [.failed, .succeeded])
        XCTAssertEqual(result.steps.first?.userMessage, "The source could not be read.")
    }

    /// A delivered container is a success with its output recorded.
    func testADeliveredSigningRecordsItsOutput() async throws {
        let engine = ScriptedSigningStep(replies: [.signed])
        let history = InMemorySigningHistoryStore()
        let coordinator = makeCoordinator(engine: engine, history: history)

        let result = try await coordinator.run(try makeRequest(entries: [makeEntry()]))

        let step = try XCTUnwrap(result.steps.first)
        XCTAssertEqual(step.outcome, .succeeded)
        XCTAssertNotNil(step.outputFileName)
        XCTAssertEqual(step.stoppingStage, "verification")
        XCTAssertNil(step.userMessage, "a clean run has nothing to warn about")
    }

    /// An empty request is refused before anything is attempted.
    func testAnEmptyRequestIsRefused() async throws {
        let engine = ScriptedSigningStep(replies: [])
        let history = InMemorySigningHistoryStore()
        let coordinator = makeCoordinator(engine: engine, history: history)

        do {
            _ = try await coordinator.run(try makeRequest(entries: []))
            XCTFail("an empty batch must be refused")
        } catch {
            XCTAssertTrue(error is ZynSignError, "expected a typed refusal, got \(error)")
        }
        let attempts = await engine.requestCount
        let records = try await history.allRecords()
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(records.count, 0)
    }

    // MARK: - Helpers

    private func makeCoordinator(
        engine: ScriptedSigningStep,
        history: InMemorySigningHistoryStore
    ) -> BatchSigningCoordinator {
        let source = sourceURL!
        let destination = outputDirectory!
        return BatchSigningCoordinator(
            pipeline: engine,
            history: history,
            requestFactory: { entry, identityID, profile in
                SignApplicationRequest(
                    sourceURL: source,
                    profile: profile,
                    identityID: identityID,
                    entitlements: try CodeSigningEntitlements(values: [:]),
                    outputURL: destination.appendingPathComponent("placeholder.ipa"),
                    options: SignApplicationOptions()
                )
            },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func makeRequest(entries: [LibraryEntry]) throws -> BatchSigningCoordinator.Request {
        BatchSigningCoordinator.Request(
            identityID: SigningIdentityIdentifier(),
            certificateFingerprint: nil,
            profile: CMSFixtures.validRSASignedAttributes,
            entries: entries,
            outputDirectory: outputDirectory
        )
    }

    private func makeEntry(name: String = "Synthetic") -> LibraryEntry {
        LibraryOrganizationFixtures.entry(name: name)
    }
}

/// A `BatchSigningStep` that answers from a script, so the sequencing rules can
/// be exercised without building packages on disk.
private actor ScriptedSigningStep: BatchSigningStep {

    enum Reply {
        /// The engine delivers the container.
        case signed
        /// The engine refuses at `stage` — a returned result, not a throw.
        case refused(at: ApplicationSigningStage)
        /// The engine throws before it can produce a result.
        case thrown
    }

    private var replies: [Reply]
    private(set) var requestCount = 0

    init(replies: [Reply]) {
        self.replies = replies
    }

    func signApplication(_ request: SignApplicationRequest) async throws -> SignApplicationResult {
        requestCount += 1
        let reply = replies.isEmpty ? Reply.signed : replies.removeFirst()
        switch reply {
        case .signed:
            return SignApplicationResult(
                status: .signed,
                outputURL: request.outputURL,
                stages: nil,
                failure: nil
            )
        case .refused(let stage):
            return SignApplicationResult(
                status: .failed,
                outputURL: nil,
                stages: nil,
                failure: ApplicationSigningFailure(
                    stage: stage,
                    detail: "The profile does not authorize this bundle.",
                    category: .invalidInput
                )
            )
        case .thrown:
            throw ZynSignError(
                category: .invalidInput,
                userMessage: "The source could not be read.",
                diagnosticDetail: ApplicationSigningStage.integrity.rawValue
            )
        }
    }
}
