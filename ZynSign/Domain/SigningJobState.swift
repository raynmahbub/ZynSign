import Foundation

/// Where a signing job was asked for. A provenance label for the queue's
/// list and diagnostics; it changes nothing about how the job runs.
enum SigningJobOrigin: String, CaseIterable, Equatable, Hashable, Sendable, Codable {

    /// Queued from a library row or card action.
    case library

    /// Queued from the application's detail screen.
    case applicationDetails

    /// Queued as part of a multi-selection bulk action.
    case bulkSelection

    /// Queued from the Smart Sign screen with its chosen configuration.
    case signingScreen

    /// Queued from the import area after a package was accepted.
    case importHub

    /// A waiting job restored from the persisted queue after an interruption.
    case restored

    /// The user-presentable name.
    var displayName: String {
        switch self {
        case .library: return "Library"
        case .applicationDetails: return "App Details"
        case .bulkSelection: return "Bulk Selection"
        case .signingScreen: return "Smart Sign"
        case .importHub: return "Import"
        case .restored: return "Restored"
        }
    }
}

/// Why one signing job failed, in the queue's terms.
///
/// A failure carries three registers deliberately: the stage that stopped
/// (where), a short explanation (what it means for the user), and technical
/// detail (what the pipeline said). The registers are kept apart so the
/// failure-recovery screen can show the explanation first and the technical
/// detail on request — and so nothing sensitive is added: identities, keys,
/// and profile content are never named, matching the pipeline's own
/// diagnostic discipline.
struct SigningJobFailure: Equatable, Hashable, Sendable, Codable {

    /// The job stage the run stopped at. A job that failed before any stage
    /// began reports the stage it was preparing for.
    let stage: SigningJobStage

    /// A short, user-presentable explanation. Never carries diagnostic
    /// detail.
    let summary: String

    /// The technical detail the pipeline or executor produced, for the
    /// expanded failure view. May name bundle-relative locations; never
    /// names identities, keys, or profile content.
    let detail: String?

    /// The failure's category.
    let category: DiagnosticCategory

    /// Whether offering to run this job again is honest: a retry creates a
    /// fresh, clean run, which can end differently for transient failures
    /// (storage, interruption, capability availability) but not for input
    /// the pipeline has already refused on its content.
    let isRetryable: Bool

    /// When the failure was recorded.
    let occurredAt: Date

    init(
        stage: SigningJobStage,
        summary: String,
        detail: String? = nil,
        category: DiagnosticCategory,
        isRetryable: Bool,
        occurredAt: Date
    ) {
        self.stage = stage
        self.summary = summary
        self.detail = detail
        self.category = category
        self.isRetryable = isRetryable
        self.occurredAt = occurredAt
    }

    /// Whether a later clean run of the same inputs can plausibly end
    /// differently. Input refusals are content decisions: re-reading an
    /// unchanged package cannot change what it declares. Everything else —
    /// storage, internal conditions, cancelled capabilities, interruptions
    /// — is treated as possibly transient.
    static func isRetryable(category: DiagnosticCategory) -> Bool {
        switch category {
        case .invalidInput, .unsupportedInput, .ambiguousInput:
            return false
        case .capabilityUnavailable, .cancelled, .storageFailure, .internalFailure:
            return true
        }
    }
}

/// What one completed signing job delivered.
///
/// The evidence is the signing operation's own: the exported artifact's
/// name, size, and export identifier, the nested-target count the run's
/// plan established, and what independent verification concluded. A
/// completion states that the container the run produced passed the run's
/// independent verification and was committed to export storage — it is
/// not a trust, authorization, or installability claim, exactly as the
/// pipeline documents.
struct SigningJobCompletion: Equatable, Hashable, Sendable, Codable {

    /// The exported artifact's file name inside export storage. A label
    /// only, never a full path.
    let outputFileName: String

    /// The delivered container's size in bytes, when it could be measured.
    let outputByteCount: Int?

    /// The number of nested targets that were signed.
    let nestedItemCount: Int?

    /// The number of file resources sealed into the bundle's resource seal.
    let sealedFileCount: Int?

    /// The cryptographic signature's size in bytes.
    let signatureByteCount: Int?

    /// Whether the pipeline's independent verification passed. Always true
    /// for a delivered container — a run whose verification fails is a
    /// failure, never a completion — recorded explicitly so the detail
    /// screen states the verification as evidence rather than implication.
    let verificationPassed: Bool

    /// When the job completed.
    let finishedAt: Date

    /// The Export Center record describing the delivered artifact, by its
    /// stored identifier, so the job can open the export it produced.
    /// Optional because snapshots written before jobs were delivered
    /// through export storage carry none.
    let exportIdentifier: String?

    /// What independent verification of the exported artifact concluded —
    /// the same check the Export Center's "Verify Again" runs, recorded
    /// after the artifact was committed. Distinct from
    /// `verificationPassed`, which is the run's own verification of the
    /// container before delivery.
    let exportVerification: ArtifactVerificationStatus?

    init(
        outputFileName: String,
        outputByteCount: Int? = nil,
        nestedItemCount: Int? = nil,
        sealedFileCount: Int? = nil,
        signatureByteCount: Int? = nil,
        verificationPassed: Bool = true,
        finishedAt: Date,
        exportIdentifier: String? = nil,
        exportVerification: ArtifactVerificationStatus? = nil
    ) {
        self.outputFileName = outputFileName
        self.outputByteCount = outputByteCount
        self.nestedItemCount = nestedItemCount
        self.sealedFileCount = sealedFileCount
        self.signatureByteCount = signatureByteCount
        self.verificationPassed = verificationPassed
        self.finishedAt = finishedAt
        self.exportIdentifier = exportIdentifier
        self.exportVerification = exportVerification
    }
}

/// One line in a job's own log.
///
/// Every job keeps its own log — stage transitions, retries, cancellations,
/// settlements — so two jobs running side by side can never interleave
/// their histories. Lines are fixed diagnostic language: a timestamp and a
/// short event, never identities, keys, profile content, or file locations.
struct SigningJobLogEntry: Equatable, Hashable, Sendable, Codable {

    /// When the event happened.
    let timestamp: Date

    /// What happened, in fixed diagnostic language.
    let message: String

    init(timestamp: Date, message: String) {
        self.timestamp = timestamp
        self.message = message
    }
}

/// The lifecycle state of one signing job.
///
/// ```
/// queued → running → completed
///                ↘ failed → (retry) → queued
///                ↘ cancelled
/// ```
///
/// A running job also carries a "cancelling" fact the queue tracks
/// separately: cancellation is cooperative, so between the user's request
/// and the run reaching its next cancellation point the job is still
/// running — and the interface says so rather than pretending the run
/// stopped the instant the button was tapped.
enum SigningJobState: Equatable, Hashable, Sendable, Codable {

    /// Accepted and waiting for its turn, ordered by priority and then by
    /// the order the user asked.
    case queued

    /// Running. What it is doing now is in the job's progress.
    case running

    /// Every stage passed and the verified container was delivered.
    case completed(SigningJobCompletion)

    /// A stage refused the run or the run failed. Nothing was delivered.
    case failed(SigningJobFailure)

    /// The user cancelled, before or during the run. Nothing was delivered.
    case cancelled

    /// Whether the job has not yet finished.
    var isActive: Bool {
        switch self {
        case .queued, .running: return true
        case .completed, .failed, .cancelled: return false
        }
    }

    /// Whether the job has finished.
    var isSettled: Bool {
        !isActive
    }

    /// The completion evidence, when the job completed.
    var completion: SigningJobCompletion? {
        if case .completed(let completion) = self { return completion }
        return nil
    }

    /// The failure, when the job failed.
    var failure: SigningJobFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}
