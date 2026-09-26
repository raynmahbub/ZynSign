import Foundation

/// How urgently one signing job should run relative to the other waiting
/// jobs in the queue.
///
/// Priority decides the order *waiting* jobs start in: high before normal
/// before low, and within one priority, first asked first run. A job that
/// is already running is never preempted by a priority change — signing is
/// heavy, stateful work, and interrupting a run to reshuffle it would be
/// neither safe nor honest. Reordering waiting jobs is always allowed.
///
/// Priority is scheduling information only. It says nothing about the
/// importance of the application, and a low-priority job runs exactly the
/// same pipeline, with exactly the same verification, as a high-priority
/// one.
enum SigningJobPriority: String, CaseIterable, Equatable, Hashable, Codable, Sendable, Comparable {

    /// Urgent work: runs before every waiting normal- and low-priority job.
    case high

    /// The default: runs in the order the user asked, after waiting
    /// high-priority jobs.
    case normal

    /// Background work: runs after every waiting high- and normal-priority
    /// job.
    case low

    /// The scheduling rank: lower runs first.
    var sortRank: Int {
        switch self {
        case .high: return 0
        case .normal: return 1
        case .low: return 2
        }
    }

    /// The user-presentable name.
    var displayName: String {
        switch self {
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        }
    }

    /// What the priority is for, in one short phrase.
    var purposeText: String {
        switch self {
        case .high: return "Urgent"
        case .normal: return "Default"
        case .low: return "Background"
        }
    }

    /// The SF Symbol shown beside the priority.
    var symbolName: String {
        switch self {
        case .high: return "arrow.up.circle.fill"
        case .normal: return "equal.circle"
        case .low: return "arrow.down.circle"
        }
    }

    static func < (lhs: SigningJobPriority, rhs: SigningJobPriority) -> Bool {
        lhs.sortRank < rhs.sortRank
    }
}
