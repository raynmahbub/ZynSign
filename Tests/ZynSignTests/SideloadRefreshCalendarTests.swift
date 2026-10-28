import XCTest
@testable import ZynSign

/// Tests for the refresh calendar: the projection of the journal onto the days
/// a person has to act.
///
/// The calendar's whole value is that its arithmetic is the profile's own date
/// minus the account's lead, so these tests fix the clock and read the buckets
/// back. A calendar that quietly rounded, dropped a late lease, or invented a
/// deadline for a run with no expiry would be worse than no calendar at all.
final class SideloadRefreshCalendarTests: XCTestCase {

    /// A fixed instant: 2026-10-28T09:00:00Z, midnight in UTC.
    private let now = Date(timeIntervalSince1970: 1_793_178_000)

    /// A Gregorian calendar pinned to UTC, so a day boundary in the test is a
    /// day boundary in the assertion.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func date(daysFromNow days: Int, hours: Int = 0) -> Date {
        now.addingTimeInterval(TimeInterval(days) * 86_400 + TimeInterval(hours) * 3_600)
    }

    private func lease(
        name: String = "Example",
        expiresInDays days: Int?,
        lead: Int? = 2,
        account: SideloadAccount? = .personalTeam
    ) -> SideloadLease {
        SideloadLease(
            id: name + (days.map(String.init) ?? "none"),
            displayName: name,
            bundleIdentifier: "com.example.\(name.lowercased())",
            signedAt: date(daysFromNow: -1),
            profileExpiresAt: days.map { date(daysFromNow: $0) },
            account: account,
            refreshLeadDays: lead
        )
    }

    private func calendar(_ leases: [SideloadLease], dayCount: Int = 14) -> SideloadRefreshCalendar {
        SideloadRefreshCalendar.calendar(for: leases, dayCount: dayCount, at: now, calendar: utc)
    }

    // MARK: - The action date

    /// The action date is the expiry minus the lead, and it is the lease's own
    /// arithmetic — a personal team's two days, not a screen's constant.
    func testRefreshByIsTheExpiryMinusTheAccountsLead() throws {
        let personal = lease(expiresInDays: 7, lead: 2)
        let membership = lease(name: "Member", expiresInDays: 400, lead: 21, account: .developerProgram)

        XCTAssertEqual(try XCTUnwrap(personal.refreshBy()), date(daysFromNow: 5))
        XCTAssertEqual(try XCTUnwrap(membership.refreshBy()), date(daysFromNow: 379))
    }

    /// A run that recorded no expiry has no action date. A deadline invented
    /// from nothing is a promise nobody made.
    func testALeaseWithNoExpiryHasNoActionDate() {
        XCTAssertNil(lease(expiresInDays: nil).refreshBy())
        XCTAssertNil(lease(account: .adHoc).expiresAt)
    }

    // MARK: - The window

    /// Fourteen days, today first, including the empty ones: a gap between two
    /// busy days is information.
    func testTheWindowIsEveryDayIncludingTheEmptyOnes() {
        let window = calendar([])
        XCTAssertEqual(window.days.count, 14)
        XCTAssertEqual(window.days.map(\.index), Array(0..<14))
        XCTAssertEqual(window.days.first?.index, 0)
        XCTAssertTrue(window.days.first?.isToday == true)
        XCTAssertTrue(window.days.dropFirst().allSatisfy { !$0.isToday })
        XCTAssertTrue(window.isEmpty)
        XCTAssertEqual(window.actionCount, 0)
    }

    /// A seven-day lease with a two-day lead acts on day five.
    func testALeaseLandsOnTheDayItShouldBeSignedAgain() throws {
        let window = calendar([lease(expiresInDays: 7, lead: 2)])
        let day = try XCTUnwrap(window.nextActionDay)
        XCTAssertEqual(day.index, 5)
        XCTAssertEqual(day.count, 1)
        XCTAssertEqual(window.days.map(\.count).reduce(0, +), 1)
        XCTAssertEqual(window.actionCount, 1)
    }

    /// Once the action date arrives — or passes, because the person is late —
    /// the work lands on today rather than in a negative column.
    func testDueAndOverdueWorkLandsOnToday() {
        let window = calendar([
            lease(name: "Due", expiresInDays: 2, lead: 2),
            lease(name: "Late", expiresInDays: -3, lead: 2),
        ])
        XCTAssertEqual(window.days[0].count, 2)
        XCTAssertEqual(window.days[0].leases.map(\.displayName).sorted(), ["Due", "Late"])
        XCTAssertTrue(window.days.dropFirst().allSatisfy(\.isEmpty))
    }

    /// Work beyond the window is counted, never squeezed into the last cell.
    func testWorkBeyondTheWindowIsListedNotSmudged() {
        let window = calendar([
            lease(name: "Far", expiresInDays: 60, lead: 2),
            lease(name: "Near", expiresInDays: 7, lead: 2),
        ])
        XCTAssertEqual(window.beyondWindow.map(\.displayName), ["Far"])
        XCTAssertEqual(window.actionCount, 1)
        XCTAssertEqual(window.outsideCount, 1)
        XCTAssertEqual(window.days[13].count, 0)
    }

    /// A run with no expiry is listed separately: not healthy, not due.
    func testALeaseWithNoExpiryIsListedOutsideTheWindow() {
        let window = calendar([lease(name: "Ghost", expiresInDays: nil)])
        XCTAssertEqual(window.scheduledWithoutDate.map(\.displayName), ["Ghost"])
        XCTAssertTrue(window.isEmpty)
        XCTAssertEqual(window.outsideCount, 1)
    }

    /// The next action day is the first with work; the busiest is the fullest,
    /// ties broken by the earliest day.
    func testNextAndBusiestDays() throws {
        let window = calendar([
            lease(name: "A", expiresInDays: 13, lead: 2),
            lease(name: "B", expiresInDays: 11, lead: 2),
            lease(name: "C", expiresInDays: 11, lead: 2),
            lease(name: "D", expiresInDays: 6, lead: 2),
        ])
        let next = try XCTUnwrap(window.nextActionDay)
        XCTAssertEqual(next.index, 4, "the soonest action date, not the first filled bucket")
        let busiest = try XCTUnwrap(window.busiestDay)
        XCTAssertEqual(busiest.index, 9)
        XCTAssertEqual(busiest.count, 2)
        XCTAssertEqual(try XCTUnwrap(window.day(at: 4)).leases.map(\.displayName), ["D"])
        XCTAssertNil(window.day(at: 99))
        XCTAssertNil(window.day(at: -1))
    }

    /// Two leases can need action on the same day for different reasons — one
    /// short lead on a near expiry, one long lead on a far one. Inside that day
    /// the lease that lapses first is the first row, so the queue order a
    /// person reads on the strip is the order they should sign in.
    func testADaysRowsAreOrderedByExpiry() throws {
        let window = calendar([
            lease(name: "Later", expiresInDays: 9, lead: 4),
            lease(name: "Sooner", expiresInDays: 7, lead: 2),
        ])
        let day = try XCTUnwrap(window.day(at: 5))
        XCTAssertEqual(day.count, 2)
        XCTAssertEqual(day.leases.map(\.displayName), ["Sooner", "Later"])
    }

    /// An empty window is not an error, and a window of zero days says so
    /// rather than pretending to hold a week.
    func testAWindowOfNoDaysIsEmpty() {
        let window = calendar([lease(expiresInDays: 3)], dayCount: 0)
        XCTAssertEqual(window, .empty)
    }

    // MARK: - The copyable schedule

    /// The text a person copies names the app, the date they should act, and
    /// the expiry the date came from — and says what it does not know.
    func testTheScheduleTextNamesEveryDayWithWork() {
        let window = calendar([
            lease(name: "Alpha", expiresInDays: 7, lead: 2),
            lease(name: "Bravo", expiresInDays: 12, lead: 2),
            lease(name: "Charlie", expiresInDays: 90, lead: 2),
        ])
        let text = window.scheduleText(
            at: now,
            readOn: "28 Oct 2026",
            dayLabel: { date in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = self.utc
                formatter.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
                formatter.dateFormat = "d MMM"
                return formatter.string(from: date)
            }
        )

        XCTAssertTrue(text.hasPrefix("ZynSign — refresh schedule (read 28 Oct 2026)"))
        XCTAssertTrue(text.contains("Alpha"))
        XCTAssertTrue(text.contains("Bravo"))
        XCTAssertFalse(text.contains("Charlie"), "a lease past the window is counted, not scheduled")
        XCTAssertTrue(text.contains("Re-sign by 2 Nov"), "day five of the window, 28 October + 5")
        XCTAssertTrue(text.contains("2 re-signs in the next 14 days."))
        XCTAssertTrue(text.contains("1 later than 14 days."))
        XCTAssertTrue(text.contains("ZynSign does not know whether a build is installed."))
    }

    /// A quiet window says so instead of printing an empty list.
    func testTheScheduleTextSaysWhenNothingIsDue() {
        let text = calendar([]).scheduleText(at: now, readOn: "28 Oct 2026", dayLabel: { _ in "a date" })
        XCTAssertTrue(text.contains("Nothing is due in the next 14 days."))
        XCTAssertTrue(text.contains("0 re-signs in the next 14 days."))
    }

    /// Today reads as today, not as a date a person has to compare.
    func testTheScheduleTextCallsTodayToday() {
        let text = calendar([lease(expiresInDays: 1, lead: 2)]).scheduleText(
            at: now, readOn: "28 Oct 2026", dayLabel: { _ in "28 Oct" }
        )
        XCTAssertTrue(text.contains("Today, 28 Oct"))
    }
}
