import Foundation

// MARK: - Smart Workspace 3.0 — widgets and their ordering policy

/// One card on the Smart Workspace dashboard.
///
/// The set is closed and declared here once. Presentation renders a widget
/// only when the feature behind it is on the release train *and* the data
/// it shows exists; the policy below only decides the order.
enum WorkspaceWidget: String, CaseIterable, Codable, Hashable, Sendable {
    case continueLastSession
    case quickSign
    case healthScore
    case recentApps
    case signingQueue
    case downloads
    case identityHealth
    case profileExpiry
    case backupStatus
    case collections
    case activity

    /// Short title shown on the card header.
    var title: String {
        switch self {
        case .continueLastSession: return "Continue Last Session"
        case .quickSign: return "Quick Sign"
        case .healthScore: return "Install Health"
        case .recentApps: return "Recent Apps"
        case .signingQueue: return "Signing Queue"
        case .downloads: return "Downloads"
        case .identityHealth: return "Identity Center"
        case .profileExpiry: return "Profile Expiry"
        case .backupStatus: return "Backup"
        case .collections: return "Collections"
        case .activity: return "Activity"
        }
    }

    /// SF Symbol name for the card header.
    var symbolName: String {
        switch self {
        case .continueLastSession: return "arrow.uturn.forward.circle"
        case .quickSign: return "bolt.badge.checkmark"
        case .healthScore: return "heart.text.square"
        case .recentApps: return "clock.arrow.circlepath"
        case .signingQueue: return "tray.full"
        case .downloads: return "arrow.down.circle"
        case .identityHealth: return "person.badge.key"
        case .profileExpiry: return "calendar.badge.exclamationmark"
        case .backupStatus: return "externaldrive.badge.timemachine"
        case .collections: return "folder"
        case .activity: return "list.bullet.rectangle"
        }
    }

    /// The default order — what a first launch shows before any usage exists.
    static let defaultOrder: [WorkspaceWidget] = [
        .continueLastSession, .quickSign, .healthScore, .recentApps, .signingQueue, .downloads,
        .identityHealth, .profileExpiry, .backupStatus, .collections, .activity,
    ]
}

/// How often and how recently one widget was opened. Pure data; the store
/// that persists it lives behind an Application port.
struct WorkspaceUsageSignal: Codable, Equatable, Hashable, Sendable {
    let widget: WorkspaceWidget
    var openCount: Int
    var lastOpenedAt: Date?

    init(widget: WorkspaceWidget, openCount: Int = 0, lastOpenedAt: Date? = nil) {
        self.widget = widget
        self.openCount = openCount
        self.lastOpenedAt = lastOpenedAt
    }
}

/// The part of the day the layout policy reasons about.
enum WorkspaceDaypart: String, CaseIterable, Sendable {
    case morning    // 05:00 – 11:59
    case afternoon  // 12:00 – 17:59
    case evening    // 18:00 – 22:59
    case night      // 23:00 – 04:59

    init(hour: Int) {
        switch hour {
        case 5..<12: self = .morning
        case 12..<18: self = .afternoon
        case 18..<23: self = .evening
        default: self = .night
        }
    }

    /// The greeting the workspace opens with.
    var greeting: String {
        switch self {
        case .morning: return "Good Morning"
        case .afternoon: return "Good Afternoon"
        case .evening: return "Good Evening"
        case .night: return "Good Night"
        }
    }
}

/// Facts the layout policy needs that are not usage: what exists right now.
struct WorkspaceContext: Equatable, Sendable {
    var hasLastSession = false
    var activeSigningJobs = 0
    var activeDownloads = 0
    var expiringProfiles = 0
    var expiringCertificates = 0
    /// Days since the last backup; `nil` when no backup has ever been made.
    var daysSinceBackup: Int? = nil

    init(
        hasLastSession: Bool = false,
        activeSigningJobs: Int = 0,
        activeDownloads: Int = 0,
        expiringProfiles: Int = 0,
        expiringCertificates: Int = 0,
        daysSinceBackup: Int? = nil
    ) {
        self.hasLastSession = hasLastSession
        self.activeSigningJobs = activeSigningJobs
        self.activeDownloads = activeDownloads
        self.expiringProfiles = expiringProfiles
        self.expiringCertificates = expiringCertificates
        self.daysSinceBackup = daysSinceBackup
    }
}

/// Orders the widgets: what is live now first, then what the user opens
/// most, then the time of day, then the default order.
///
/// The policy is a pure function so it can be tested against a clock and
/// an inventory without a store or a view. It never hides a widget — the
/// order is a suggestion, and Presentation still gates each card on the
/// release train and on the presence of data.
struct WorkspaceLayoutPolicy: Sendable {

    /// A backup older than this is "recommended" at night.
    var backupReminderDays = 7

    init(backupReminderDays: Int = 7) {
        self.backupReminderDays = backupReminderDays
    }

    func order(
        usage: [WorkspaceUsageSignal],
        context: WorkspaceContext,
        now: Date,
        calendar: Calendar = .current
    ) -> [WorkspaceWidget] {
        let daypart = WorkspaceDaypart(hour: calendar.component(.hour, from: now))
        let usageByWidget = Dictionary(uniqueKeysWithValues: usage.map { ($0.widget, $0) })

        func score(_ widget: WorkspaceWidget) -> Double {
            var value = 0.0

            // 1. Live work outranks everything: something is happening now.
            switch widget {
            case .signingQueue where context.activeSigningJobs > 0: value += 1000
            case .downloads where context.activeDownloads > 0: value += 900
            case .continueLastSession where context.hasLastSession: value += 800
            case .profileExpiry where context.expiringProfiles > 0: value += 700
            case .identityHealth where context.expiringCertificates > 0: value += 700
            default: break
            }

            // 2. Time of day nudges, as the vision describes:
            //    morning → pick up yesterday's work; night → back up.
            switch (daypart, widget) {
            case (.morning, .continueLastSession), (.morning, .recentApps):
                value += 300
            case (.night, .backupStatus), (.evening, .backupStatus):
                if let days = context.daysSinceBackup, days >= backupReminderDays {
                    value += 350
                } else if context.daysSinceBackup == nil {
                    value += 200
                }
            case (.afternoon, .signingQueue), (.afternoon, .healthScore):
                value += 100
            default:
                break
            }

            // 3. Usage: frequency with a recency decay (half-life ≈ 7 days).
            if let signal = usageByWidget[widget] {
                var recency = 1.0
                if let last = signal.lastOpenedAt {
                    let days = max(0, now.timeIntervalSince(last) / 86_400)
                    recency = pow(0.5, days / 7)
                }
                value += min(Double(signal.openCount), 50) * 4 * recency
            }

            return value
        }

        func defaultRank(_ widget: WorkspaceWidget) -> Int {
            WorkspaceWidget.defaultOrder.firstIndex(of: widget) ?? WorkspaceWidget.defaultOrder.count
        }

        // 4. Stable fallback: the default order breaks every tie.
        return WorkspaceWidget.allCases.sorted { lhs, rhs in
            let l = score(lhs), r = score(rhs)
            if l != r { return l > r }
            return defaultRank(lhs) < defaultRank(rhs)
        }
    }
}
