import Foundation

/// One day of the refresh window: the re-signs whose *action* date falls on it.
///
/// The action date is not the expiry. A build signed by a seven-day personal
/// team should be signed again two days before it lapses, so the day a person
/// has to act is earlier than the day the app stops opening — and that earlier
/// date is the one a calendar can plan around. Every lease contributes exactly
/// one action date, which is why the counts here add up.
struct SideloadRefreshDay: Identifiable, Equatable, Sendable {

    /// Days from the day the calendar was built. Zero is today.
    let index: Int

    /// The start of that day, in the calendar the projection was built with.
    let date: Date

    /// The leases whose action date is this day, nearest expiry first.
    let leases: [SideloadLease]

    var id: Int { index }

    /// Whether this is the day the person is reading the screen.
    var isToday: Bool { index == 0 }

    /// How many re-signs belong to this day.
    var count: Int { leases.count }

    /// Whether nothing is due this day.
    var isEmpty: Bool { leases.isEmpty }
}

/// The next two weeks of re-signs, projected onto days.
///
/// The studio's other lists answer "what is due now"; this one answers "when
/// is my week busy", which is the question a person with three apps on a free
/// personal team actually asks. It is a projection of the journal, built the
/// same way every other studio value is: a lease is a reading, the action date
/// is arithmetic on the profile's own expiry, and nothing is stored.
///
/// Two things are deliberately *not* days: a lease whose run recorded no expiry
/// has no action date, and a lease whose action date is past the window is not
/// squeezed into the last cell. Both are listed, because a calendar that hides
/// what it cannot place is a calendar that lies by omission.
struct SideloadRefreshCalendar: Equatable, Sendable {

    /// The window, today first. Always `dayCount` entries, including empty days:
    /// a gap between two busy days is information, and dropping it would make
    /// the strip look like a continuous queue.
    let days: [SideloadRefreshDay]

    /// Leases whose action date is later than the window's last day.
    let beyondWindow: [SideloadLease]

    /// Leases with no expiry at all, so no action date could be derived.
    let scheduledWithoutDate: [SideloadLease]

    /// A calendar that has not been built yet.
    static let empty = SideloadRefreshCalendar(days: [], beyondWindow: [], scheduledWithoutDate: [])

    /// A Gregorian calendar in the reader's own time zone: day boundaries belong
    /// to the person reading, not to UTC.
    static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// How many days the studio projects by default. Two weeks is long enough to
    /// show a free team's whole cycle with a second one starting, and short
    /// enough to stay a glance rather than a chart.
    static let defaultDayCount = 14

    // MARK: - Building

    /// Projects `leases` onto `dayCount` days, starting with the day `now` is in.
    ///
    /// An action date that has already arrived — including one that has already
    /// passed, because the person is late — lands on today rather than in a
    /// negative column: "act now" is a real bucket, not an error case.
    static func calendar(
        for leases: [SideloadLease],
        dayCount: Int = defaultDayCount,
        at now: Date,
        calendar timeZone: Calendar = SideloadRefreshCalendar.gregorian
    ) -> SideloadRefreshCalendar {
        guard dayCount > 0 else { return .empty }
        let today = timeZone.startOfDay(for: now)

        var buckets: [Int: [SideloadLease]] = [:]
        var beyond: [SideloadLease] = []
        var undated: [SideloadLease] = []

        for lease in leases {
            guard let actionDate = lease.refreshBy() else {
                undated.append(lease)
                continue
            }
            if actionDate <= now {
                buckets[0, default: []].append(lease)
                continue
            }
            let offset = timeZone.dateComponents(
                [.day],
                from: today,
                to: timeZone.startOfDay(for: actionDate)
            ).day ?? 0
            if offset >= dayCount {
                beyond.append(lease)
            } else {
                buckets[max(0, offset), default: []].append(lease)
            }
        }

        let days = (0..<dayCount).map { index in
            SideloadRefreshDay(
                index: index,
                date: timeZone.date(byAdding: .day, value: index, to: today) ?? today,
                leases: sorted(buckets[index] ?? [])
            )
        }

        return SideloadRefreshCalendar(
            days: days,
            beyondWindow: sorted(beyond),
            scheduledWithoutDate: undated.sorted { $0.displayName < $1.displayName }
        )
    }

    /// Nearest expiry first, then by name, so a day's rows are stable between
    /// reads and the first one is always the one that lapses soonest.
    private static func sorted(_ leases: [SideloadLease]) -> [SideloadLease] {
        leases.sorted { first, second in
            switch (first.expiresAt, second.expiresAt) {
            case let (firstDate?, secondDate?):
                if firstDate != secondDate { return firstDate < secondDate }
                return first.displayName < second.displayName
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return first.displayName < second.displayName
            }
        }
    }

    // MARK: - Reading

    /// Whether no lease has an action date inside the window.
    var isEmpty: Bool {
        days.allSatisfy(\.isEmpty)
    }

    /// How many re-signs the window holds.
    var actionCount: Int {
        days.reduce(0) { $0 + $1.count }
    }

    /// The day a person should look at: today when anything is late or due
    /// today, otherwise the first day with work in it.
    var nextActionDay: SideloadRefreshDay? {
        days.first { !$0.isEmpty }
    }

    /// The busiest day in the window, ties broken by the earliest day.
    var busiestDay: SideloadRefreshDay? {
        days.reduce(nil as SideloadRefreshDay?) { best, day in
            guard !day.isEmpty else { return best }
            guard let best else { return day }
            return day.count > best.count ? day : best
        }
    }

    /// The day at `index`, when the window covers it.
    func day(at index: Int) -> SideloadRefreshDay? {
        guard index >= 0, index < days.count else { return nil }
        return days[index]
    }

    /// How many leases fall outside the window for reasons the calendar states,
    /// so a screen can say "and N more" without pretending they do not exist.
    var outsideCount: Int {
        beyondWindow.count + scheduledWithoutDate.count
    }

    // MARK: - A schedule a person can keep

    /// The projection as plain text, for copying into a note or a message.
    ///
    /// `dayLabel` renders one day's date, so the text reads in the same words
    /// as the screen it came from. The result is deliberately boring: a heading,
    /// one block per day that holds work, and three honest counts.
    func scheduleText(at now: Date, readOn: String, dayLabel: (Date) -> String) -> String {
        var lines: [String] = ["ZynSign — refresh schedule (read \(readOn))", ""]

        let busyDays = days.filter { !$0.isEmpty }
        if busyDays.isEmpty {
            lines.append("Nothing is due in the next \(days.count) days.")
        } else {
            for day in busyDays {
                let heading = day.isToday ? "Today, \(dayLabel(day.date))" : "Re-sign by \(dayLabel(day.date))"
                lines.append(heading)
                for lease in day.leases {
                    let account = lease.account?.shortLabel ?? "account not recorded"
                    let ending = lease.ending?.title.lowercased() ?? "expiry"
                    let expiry = lease.expiresAt.map(dayLabel) ?? "an unrecorded date"
                    lines.append("  · \(lease.displayName) — expires \(expiry) (\(ending), \(account))")
                }
                lines.append("")
            }
        }

        lines.append("\(actionCount) re-sign\(actionCount == 1 ? "" : "s") in the next \(days.count) days.")
        if !beyondWindow.isEmpty {
            lines.append("\(beyondWindow.count) later than \(days.count) days.")
        }
        if !scheduledWithoutDate.isEmpty {
            lines.append("\(scheduledWithoutDate.count) with no expiry recorded.")
        }
        lines.append("A date is the profile's own expiry. ZynSign does not know whether a build is installed.")
        return lines.joined(separator: "\n")
    }
}

extension SideloadLease {

    /// The day a person should sign this build again: its expiry minus the
    /// account's lead time.
    ///
    /// The lead is the lease's own — resolved when it was derived — so a free
    /// personal team's two days and a membership's three weeks are answered by
    /// the lease itself rather than by the screen that shows it. `nil` when the
    /// run recorded no expiry: an action date invented from nothing would be a
    /// deadline the person never agreed to.
    func refreshBy() -> Date? {
        guard let expiresAt else { return nil }
        return expiresAt.addingTimeInterval(-TimeInterval(refreshLeadDays) * 86_400)
    }
}
