import Foundation

#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local refresh reminders, where the platform supports them and the person
/// allowed notifications.
///
/// The same discipline as the signing queue's notifier, for the same reasons: a
/// reminder becomes a system notification only when the platform has a centre
/// and authorization is granted or provisional. The studio's own preference is
/// checked before this type is ever called, so a person who never turned
/// reminders on is never asked for permission and never sees a notification.
///
/// Reminders are scheduled with a calendar trigger at the instant the plan
/// computed — nine in the morning on the day a lease's own lead time says to
/// sign again. Nothing is transmitted: a notification is this device posting a
/// sentence to itself.
@MainActor
final class LocalRefreshReminderScheduler: RefreshReminderScheduling {

    /// Whether this platform offers a notification centre at all.
    let isSupported: Bool

    /// `nonisolated` because the composition root builds the scheduler while
    /// wiring the environment, which is not a main-actor context. It only
    /// initializes storage; every later call hops to the main actor.
    nonisolated init() {
        #if canImport(UserNotifications) && os(iOS)
        self.isSupported = true
        #else
        self.isSupported = false
        #endif
    }

    nonisolated func schedule(_ reminders: [SideloadRefreshReminder]) async {
        await scheduleOnMain(reminders)
    }

    nonisolated func requestAuthorizationIfNeeded() async {
        await requestAuthorizationOnMain()
    }

    nonisolated func clearScheduled() async {
        await clearOnMain()
    }

    // MARK: - Main-actor half

    /// Replaces this app's pending reminders with `reminders`.
    ///
    /// Removal runs first and is driven by the identifiers that were actually
    /// posted, so a lease that has since been re-signed, dropped out of the
    /// journal, or fallen past the plan's cap cannot leave an orphan behind —
    /// and no reminder belonging to anything else is touched.
    private func scheduleOnMain(_ reminders: [SideloadRefreshReminder]) async {
        guard isSupported else { return }
        #if canImport(UserNotifications) && os(iOS)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            return
        }

        center.removePendingNotificationRequests(withIdentifiers: Self.postedIdentifiers())
        var posted: [String] = []
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.categoryIdentifier = "ZYN_REFRESH"
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.fireAt
            )
            let request = UNNotificationRequest(
                identifier: reminder.id,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            do {
                try await center.add(request)
                posted.append(reminder.id)
            } catch {
                // A refused request is a fact about this device's state, not an
                // error to surface: the studio still shows the countdown.
            }
        }
        UserDefaults.standard.set(posted, forKey: RefreshReminderPreferences.scheduledDefaultsKey)
        #endif
    }

    private func requestAuthorizationOnMain() async {
        guard isSupported else { return }
        #if canImport(UserNotifications) && os(iOS)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        #endif
    }

    private func clearOnMain() async {
        #if canImport(UserNotifications) && os(iOS)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: Self.postedIdentifiers())
        UserDefaults.standard.removeObject(forKey: RefreshReminderPreferences.scheduledDefaultsKey)
        #endif
    }

    private nonisolated static func postedIdentifiers() -> [String] {
        UserDefaults.standard.stringArray(forKey: RefreshReminderPreferences.scheduledDefaultsKey) ?? []
    }
}
