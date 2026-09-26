import Foundation
@testable import ZynSign

/// Synthetic values and doubles for signing-queue tests.
///
/// Every value is invented: identifiers are fresh UUIDs, names and bundle
/// identifiers are example literals, and profile bytes are a fixed marker —
/// no real profile, certificate, or key appears anywhere. The doubles stand
/// in for the executor and the store so the queue's own promises can be
/// tested without a pipeline, a filesystem, or a Keychain.
enum SigningQueueFixtures {

    /// A fixed instant, so ordering and timestamps are deterministic.
    static let fixedDate = Date(timeIntervalSinceReferenceDate: 750_000_000)

    /// Synthetic profile bytes. Not a profile; a marker the doubles carry.
    static let profileBytes = Data("synthetic-profile".utf8)

    /// The artifact-location convention the queue under test uses.
    static let artifactURLResolver: @Sendable (ArtifactIdentifier) -> URL = { id in
        URL(fileURLWithPath: "/synthetic/Artifacts/\(id.rawValue).ipa")
    }

    /// One submission for an application with the given name.
    static func submission(
        name: String = "Example",
        bundleIdentifier: String = "com.example.synthetic",
        emitDEREntitlements: Bool = false,
        profile: Data = profileBytes
    ) -> SigningJobSubmission {
        SigningJobSubmission(
            recordID: ApplicationRecordIdentifier(),
            artifactID: ArtifactIdentifier(),
            applicationName: name,
            bundleIdentifier: bundleIdentifier,
            versionText: "Version 1.2 (34)",
            identityID: SigningIdentityIdentifier(),
            identityDisplayName: "Synthetic Identity",
            certificateFingerprint: nil,
            profile: profile,
            profileDisplayName: "Synthetic Profile",
            profileTeamIdentifier: "EXAMPLE123",
            emitDEREntitlements: emitDEREntitlements
        )
    }

    /// A completion the synthetic executor reports.
    static func completion(fileName: String = "Example_signed.ipa") -> SigningJobCompletion {
        SigningJobCompletion(
            outputFileName: fileName,
            outputByteCount: 1_024,
            nestedItemCount: 2,
            sealedFileCount: 10,
            signatureByteCount: 256,
            finishedAt: fixedDate
        )
    }

    /// A failure the synthetic executor reports.
    static func failure(
        stage: SigningJobStage = .signingApp,
        category: DiagnosticCategory = .storageFailure
    ) -> SigningJobFailure {
        SigningJobFailure(
            stage: stage,
            summary: "Synthetic failure.",
            detail: "synthetic detail",
            category: category,
            isRetryable: SigningJobFailure.isRetryable(category: category),
            occurredAt: fixedDate
        )
    }
}

/// A signing executor whose every run follows a script the test writes.
///
/// Each run records its request, reports the stages the script names (in
/// the order the script names them — including out of order, to exercise
/// the queue's monotonic progress), optionally waits until the test
/// releases it, and then ends with the scripted outcome. Waiting is
/// cancellation-aware: a cancelled run throws `CancellationError` exactly
/// as the real pipeline does at its stage boundaries.
final class SyntheticSigningExecutor: SigningQueueExecuting, @unchecked Sendable {

    /// How one run ends.
    enum Outcome {
        case completes(SigningJobCompletion)
        case fails(SigningJobFailure)
        case throwsUnexpectedly
    }

    /// One scripted run.
    struct Step {
        var stages: [SigningJobStage] = [.preflight, .extraction, .signingFrameworks, .signingApp, .packaging, .verification]
        var holdsUntilReleased = false
        var outcome: Outcome = .completes(SigningQueueFixtures.completion())
    }

    private let lock = NSLock()
    private var script: [Step] = []
    private var _requests: [SigningJobExecutionRequest] = []
    private var held: Set<SigningJobIdentifier> = []
    private var _cancelledJobs: [SigningJobIdentifier] = []

    /// Appends scripted runs. Runs beyond the script complete immediately.
    func enqueue(_ steps: [Step]) {
        lock.lock(); defer { lock.unlock() }
        script.append(contentsOf: steps)
    }

    /// Every request the executor received, in the order runs started.
    var requests: [SigningJobExecutionRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// The jobs whose runs observed a cancellation.
    var cancelledJobs: [SigningJobIdentifier] {
        lock.lock(); defer { lock.unlock() }
        return _cancelledJobs
    }

    /// Whether a run for `id` is currently held.
    func isHolding(_ id: SigningJobIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return held.contains(id)
    }

    /// Releases a held run so it proceeds to its outcome.
    func release(_ id: SigningJobIdentifier) {
        lock.lock(); defer { lock.unlock() }
        held.remove(id)
    }

    /// Records the request and takes the next scripted step, atomically.
    private func beginRun(_ request: SigningJobExecutionRequest) -> Step {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        let next = script.isEmpty ? Step() : script.removeFirst()
        if next.holdsUntilReleased { held.insert(request.jobID) }
        return next
    }

    /// Records that a run observed its cancellation.
    private func recordCancellation(of id: SigningJobIdentifier) {
        lock.lock(); defer { lock.unlock() }
        _cancelledJobs.append(id)
        held.remove(id)
    }

    func execute(
        _ request: SigningJobExecutionRequest,
        reporting progress: (any SigningJobProgressReporting)?
    ) async throws -> SigningJobExecutionOutcome {
        let step = beginRun(request)
        for stage in step.stages {
            progress?.report(SigningJobProgress(stage: stage))
        }
        do {
            while isHolding(request.jobID) {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try Task.checkCancellation()
        } catch {
            recordCancellation(of: request.jobID)
            throw CancellationError()
        }
        switch step.outcome {
        case .completes(let completion):
            return .completed(completion)
        case .fails(let failure):
            return .failed(failure)
        case .throwsUnexpectedly:
            throw ZynSignError(category: .internalFailure, userMessage: "Synthetic infrastructure failure.")
        }
    }
}

/// A queue store that keeps everything in memory, so persistence can be
/// observed and restoration exercised without touching the filesystem.
actor InMemorySigningQueueStore: SigningQueueStore {

    private(set) var snapshot: SigningQueueSnapshot?
    private(set) var profiles: [String: Data] = [:]
    private(set) var recoveredWith: Set<String>?
    private var knownRevision: Int?

    init(snapshot: SigningQueueSnapshot? = nil, profiles: [String: Data] = [:]) {
        self.snapshot = snapshot
        self.profiles = profiles
    }

    func load() async throws -> SigningQueueSnapshot? {
        if let snapshot { knownRevision = snapshot.revision }
        return snapshot
    }

    func save(_ snapshot: SigningQueueSnapshot) async throws {
        if let knownRevision, snapshot.revision <= knownRevision { return }
        self.snapshot = snapshot
        knownRevision = snapshot.revision
    }

    func storeProfile(_ data: Data, jobID: SigningJobIdentifier) async throws -> String {
        let name = "\(jobID.rawValue).mobileprovision"
        profiles[name] = data
        return name
    }

    func loadProfile(fileName: String) async throws -> Data? {
        profiles[fileName]
    }

    func removeProfile(fileName: String) async throws {
        profiles.removeValue(forKey: fileName)
    }

    func recoverWorkspace(referencedProfileFileNames: Set<String>) async throws {
        recoveredWith = referencedProfileFileNames
        profiles = profiles.filter { referencedProfileFileNames.contains($0.key) }
    }
}

/// A notifier that records every notice it is offered.
actor RecordingSigningQueueNotifier: SigningQueueNotifying {

    private(set) var notices: [SigningQueueNotice] = []

    func notify(_ notice: SigningQueueNotice) async {
        notices.append(notice)
    }
}
