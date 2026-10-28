import Foundation

/// One local reminder that a build is about to stop launching.
///
/// A reminder is a sentence and an instant. It carries the application's name
/// and two dates — the day to sign again and the day the profile ends — and
/// nothing else: no identifier of a certificate, no profile content, no path.
/// The identifier is stable and derived from the lease, so scheduling the same
/// lease twice replaces the pending reminder instead of adding a second one.
struct SideloadRefreshReminder: Identifiable, Equatable, Sendable {

    /// A stable identifier, prefixed so the scheduler can remove exactly its own
    /// pending reminders and nothing else in the notification centre.
    let id: String

    /// The lease the reminder is about.
    let leaseID: String

    /// What the notification says in its title.
    let title: String

    /// The one sentence under the title.
    let body: String

    /// When it should fire.
    let fireAt: Date

    /// The identifier prefix every reminder carries.
    static let identifierPrefix = "zynsign.refresh."
}

/// The reminders a set of leases implies, and what was left out.
///
/// The plan is deliberately small and deliberately not exhaustive: it schedules
/// a reminder for work that is still ahead, skips work whose reminder instant
/// has already passed (the studio's queue already says that out loud, and a
/// notification about yesterday is noise), and caps the total so a journal with
/// hundreds of runs cannot fill the notification centre.
struct SideloadRefreshReminderPlan: Equatable, Sendable {

    /// The reminders to schedule, soonest first.
    let reminders: [SideloadRefreshReminder]

    /// How many leases were skipped because their instant had already passed.
    let skippedInPast: Int

    /// How many were skipped because the cap was reached.
    let skippedBeyondLimit: Int

    /// A plan with nothing in it.
    static let empty = SideloadRefreshReminderPlan(reminders: [], skippedInPast: 0, skippedBeyondLimit: 0)

    /// How many reminders would be posted.
    var count: Int { reminders.count }

    /// The hour of the day a reminder fires: nine in the morning reads as
    /// "today", and is late enough not to wake anyone.
    static let reminderHour = 9

    /// How many reminders one plan may hold.
    static let defaultLimit = 12

    /// Builds the plan for `leases` at `now`.
    ///
    /// `dayLabel` renders a date in the words the screen already uses, so the
    /// notification and the studio cannot describe the same day differently.
    static func make(
        for leases: [SideloadLease],
        at now: Date,
        calendar: Calendar = SideloadRefreshCalendar.gregorian,
        hour: Int = reminderHour,
        limit: Int = defaultLimit,
        dayLabel: (Date) -> String = SideloadRefreshReminderPlan.defaultDayLabel
    ) -> SideloadRefreshReminderPlan {
        guard limit > 0 else { return .empty }
        var candidates: [SideloadRefreshReminder] = []
        var skippedInPast = 0

        for lease in leases {
            guard let actionDate = lease.refreshBy() else { continue }
            guard let fireAt = fireInstant(for: actionDate, at: now, calendar: calendar, hour: hour) else {
                skippedInPast += 1
                continue
            }
            candidates.append(reminder(for: lease, actionDate: actionDate, fireAt: fireAt, dayLabel: dayLabel))
        }

        let ordered = candidates.sorted { first, second in
            if first.fireAt != second.fireAt { return first.fireAt < second.fireAt }
            return first.leaseID < second.leaseID
        }
        return SideloadRefreshReminderPlan(
            reminders: Array(ordered.prefix(limit)),
            skippedInPast: skippedInPast,
            skippedBeyondLimit: max(0, ordered.count - limit)
        )
    }

    /// The instant the reminder should fire, or `nil` when it is already behind
    /// us and posting it would be noise.
    private static func fireInstant(
        for actionDate: Date,
        at now: Date,
        calendar: Calendar,
        hour: Int
    ) -> Date? {
        let startOfDay = calendar.startOfDay(for: actionDate)
        guard let fireAt = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: startOfDay) else {
            return nil
        }
        return fireAt > now ? fireAt : nil
    }

    private static func reminder(
        for lease: SideloadLease,
        actionDate: Date,
        fireAt: Date,
        dayLabel: (Date) -> String
    ) -> SideloadRefreshReminder {
        let action = dayLabel(actionDate)
        let expiry = lease.expiresAt.map { "The profile behind it expires \(dayLabel($0))." }
            ?? "Its recorded expiry is unknown, so this is the day its account's lead time ends."
        return SideloadRefreshReminder(
            id: SideloadRefreshReminder.identifierPrefix + lease.id,
            leaseID: lease.id,
            title: "Re-sign \(lease.displayName) by \(action)",
            body: expiry + " Sign it again to get a fresh profile.",
            fireAt: fireAt
        )
    }

    /// A day as a notification reads it: the day and the month, in a fixed
    /// locale so the text is the same everywhere.
    static func defaultDayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = SideloadRefreshCalendar.gregorian
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }
}
