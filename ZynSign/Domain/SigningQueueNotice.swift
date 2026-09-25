import Foundation

/// One in-app notification the signing queue posts about a settled job or a
/// finished queue.
///
/// Notices are the queue's own words for what just happened: a job
/// completed, a job failed, or the queue ran out of work. They drive the
/// shell's toast, the VoiceOver announcement, and — only where the platform
/// supports it and the user allowed it — the local notification. A notice
/// carries display text and the job's identifier; it never carries
/// identities, keys, profile content, or file locations.
struct SigningQueueNotice: Equatable, Hashable, Sendable, Identifiable {

    /// What the notice announces.
    enum Kind: String, Equatable, Hashable, Sendable {

        /// One job delivered a verified container.
        case jobCompleted

        /// One job failed and did not deliver.
        case jobFailed

        /// The queue finished everything it was holding.
        case queueFinished

        /// The SF Symbol shown beside the notice.
        var symbolName: String {
            switch self {
            case .jobCompleted: return "checkmark.seal.fill"
            case .jobFailed: return "xmark.shield.fill"
            case .queueFinished: return "checklist"
            }
        }
    }

    /// Stable identifier, so a notice is delivered exactly once.
    let id: UUID

    /// What happened.
    let kind: Kind

    /// The short headline, e.g. "MyApp signed".
    let title: String

    /// The supporting sentence.
    let message: String

    /// The job the notice is about, when it is about one job.
    let jobID: SigningJobIdentifier?

    /// When the notice was posted.
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        message: String,
        jobID: SigningJobIdentifier? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.jobID = jobID
        self.createdAt = createdAt
    }
}
