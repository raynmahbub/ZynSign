import Foundation

/// How urgently one download should start relative to the other waiting
/// downloads.
///
/// Priority decides the order *waiting* downloads are inserted in: high before
/// normal before low, and within one priority, first asked first. A transfer
/// that has already started is never preempted by a priority change. The user
/// may still reorder waiting jobs explicitly; after that, list order is what
/// the scheduler follows.
///
/// Priority is scheduling information only. A low-priority download is
/// validated with exactly the same rules as a high-priority one.
enum DownloadJobPriority: String, CaseIterable, Equatable, Hashable, Codable, Sendable, Comparable {

    /// Urgent work: inserted before every waiting normal- and low-priority job.
    case high

    /// The default.
    case normal

    /// Background work: inserted after every waiting high- and normal-priority job.
    case low

    /// The scheduling rank: lower starts sooner when the queue is first built.
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

    static func < (lhs: DownloadJobPriority, rhs: DownloadJobPriority) -> Bool {
        lhs.sortRank < rhs.sortRank
    }
}
