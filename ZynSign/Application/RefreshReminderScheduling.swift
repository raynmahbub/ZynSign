import Foundation

/// The boundary through which the Sideload Studio reaches the platform's local
/// notifications.
///
/// The port exists so the studio plans reminders without knowing anything about
/// `UserNotifications`, permission states, or how a notification centre stores a
/// request. The implementation decides whether a reminder may become a system
/// notification, and the honest answer is often "no" — the platform has no
/// centre, the person never allowed notifications, or the person turned the
/// reminders off. A refused reminder is not an error: the countdowns on screen
/// stand on their own.
///
/// Reminder content follows the studio's own discipline: an application name and
/// two dates. Never a certificate, a key, a profile's contents, or a file path.
protocol RefreshReminderScheduling: Sendable {

    /// Whether this platform offers a notification centre at all.
    var isSupported: Bool { get }

    /// Replaces every reminder this app posted with `reminders`. A reminder that
    /// is no longer in the array is removed; nothing else in the notification
    /// centre is touched.
    func schedule(_ reminders: [SideloadRefreshReminder]) async

    /// Asks the system for authorization — once, and only because the person
    /// just asked for reminders. A denial is accepted silently.
    func requestAuthorizationIfNeeded() async

    /// Removes every reminder this app posted, and nothing else.
    func clearScheduled() async
}

/// A scheduler that posts nothing, anywhere. The composition root's choice for
/// targets without `UserNotifications`, and the fallback a test uses when it
/// wants to observe the studio without a notification centre.
struct UnavailableRefreshReminderScheduler: RefreshReminderScheduling {

    var isSupported: Bool { false }

    func schedule(_ reminders: [SideloadRefreshReminder]) async {
        // Nothing is posted, deliberately: this target has no centre the studio
        // may use.
    }

    func requestAuthorizationIfNeeded() async {}

    func clearScheduled() async {}
}

/// Where the person's reminder preference is kept.
///
/// The preference belongs to the app, not to a notification centre, so it lives
/// in `UserDefaults` under a key the studio reads and the scheduler never sees.
/// Off unless it was turned on.
enum RefreshReminderPreferences {

    /// The `UserDefaults` key the preference lives under.
    static let enabledDefaultsKey = "zynsign.sideload.refreshReminders"

    /// The `UserDefaults` key holding the identifiers the app posted, so a later
    /// read can remove exactly those and nothing else.
    static let scheduledDefaultsKey = "zynsign.sideload.refreshReminderIDs"

    /// Whether reminders are on. Absent means off.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledDefaultsKey)
    }

    /// Stores the preference.
    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledDefaultsKey)
    }
}
