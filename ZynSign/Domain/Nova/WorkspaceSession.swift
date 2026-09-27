import Foundation

/// What the user was doing when they last left — the record behind the
/// Smart Workspace's “Continue Last Session” card.
///
/// It names an activity and, when the activity concerned one application,
/// that application's record identifier and display name. It records
/// nothing else: no paths, no identities, no profile bodies.
struct WorkspaceSession: Codable, Equatable, Hashable, Sendable {

    /// The kind of work the session was in the middle of.
    enum Activity: String, Codable, CaseIterable, Sendable {
        case importing
        case inspecting
        case signing
        case verifying
        case delivering
        case browsingStore

        var verb: String {
            switch self {
            case .importing: return "Importing"
            case .inspecting: return "Inspecting"
            case .signing: return "Signing"
            case .verifying: return "Verifying"
            case .delivering: return "Delivering"
            case .browsingStore: return "Browsing the Store"
            }
        }
    }

    let activity: Activity
    /// The application the activity concerned, if any (`ApplicationRecord.id` raw value).
    let applicationRecordID: String?
    /// A display name captured at the time, so the card reads well even if
    /// the record was later removed.
    let applicationDisplayName: String?
    let recordedAt: Date

    init(activity: Activity, applicationRecordID: String? = nil, applicationDisplayName: String? = nil, recordedAt: Date) {
        self.activity = activity
        self.applicationRecordID = applicationRecordID
        self.applicationDisplayName = applicationDisplayName
        self.recordedAt = recordedAt
    }

    /// A one-line summary for the card: “Signing · Example App”.
    var summary: String {
        if let name = applicationDisplayName, !name.isEmpty {
            return "\(activity.verb) · \(name)"
        }
        return activity.verb
    }

    /// Sessions older than this are not worth resuming.
    static let resumeWindow: TimeInterval = 14 * 24 * 60 * 60

    /// Whether the session is recent enough to offer as “continue”.
    func isResumable(now: Date) -> Bool {
        now.timeIntervalSince(recordedAt) <= Self.resumeWindow
    }
}
